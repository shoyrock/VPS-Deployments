#!/usr/bin/env bash
# verify-stack.sh -- health + SECURITY audit for the Dockhand + Authentik + NPM +
# CrowdSec stack deployed by deploy-dockhand-authentik.sh.
# Run on the VPS as root:   sudo bash verify-stack.sh
# Read-only except a self-cleaning CrowdSec ban round-trip test (192.0.2.1, RFC5737).
set -uo pipefail

C_R='\033[0m'; C_B='\033[1m'; C_G='\033[0;32m'; C_Y='\033[0;33m'; C_RED='\033[0;31m'; C_C='\033[0;36m'
[[ -t 1 ]] || { C_R=; C_B=; C_G=; C_Y=; C_RED=; C_C=; }
P=0; W=0; F=0
pass(){ printf "${C_G}[PASS]${C_R} %s\n" "$*"; P=$((P+1)); }
warn(){ printf "${C_Y}[WARN]${C_R} %s\n" "$*"; W=$((W+1)); }
fail(){ printf "${C_RED}[FAIL]${C_R} %s\n" "$*"; F=$((F+1)); }
hdr(){  printf "\n${C_B}${C_C}== %s ==${C_R}\n" "$*"; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "docker not found"; exit 1; }

# v4.9.0 moved the stack under /opt/apps; fall back to the pre-move path so this
# script still verifies older deployments.
STACK_DIR="/opt/apps/dockhand-stack"
[[ -d "$STACK_DIR" ]] || STACK_DIR="/opt/dockhand-stack"
AUTHENTIK_DIR="${STACK_DIR}/authentik"
DOMAIN="$(tr -d '\n' < /etc/vps-deploy-domain 2>/dev/null || true)"
printf "${C_B}Dockhand stack health + security audit${C_R}  domain=${DOMAIN:-<unknown>}\n"

# ---- A. Containers --------------------------------------------------------
hdr "Containers"
for c in npm dockhand authentik-server authentik-worker authentik-postgres authentik-redis crowdsec; do
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$c"; then pass "container $c running"
  else fail "container $c NOT running"; fi
done
# CrowdSec Web UI is optional/removable: only check when its compose file exists.
if [[ -f "${STACK_DIR}/docker-compose.crowdsec-webui.yml" ]]; then
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx crowdsec-web-ui && pass "container crowdsec-web-ui running" || warn "container crowdsec-web-ui NOT running (removed? see README to reinstall)"
fi

# ---- B. Service health ----------------------------------------------------
hdr "Service health"
curl -sf --max-time 5 http://127.0.0.1:81/api/ >/dev/null 2>&1 && pass "NPM API up (:81)" || fail "NPM API down (:81)"
curl -sf --max-time 5 http://127.0.0.1:9000/-/health/ready/ >/dev/null 2>&1 && pass "Authentik health OK (:9000)" || fail "Authentik health FAIL"
docker exec npm nginx -t >/dev/null 2>&1 && pass "NPM nginx config valid" || fail "NPM nginx config INVALID"
docker exec crowdsec cscli lapi status >/dev/null 2>&1 && pass "CrowdSec LAPI responding" || fail "CrowdSec LAPI down"
[[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == "1" ]] && pass "IP forwarding on" || warn "IP forwarding off (published ports may break)"

# ---- C. CrowdSec enforcement ---------------------------------------------
hdr "CrowdSec enforcement"
docker exec crowdsec cscli collections list 2>/dev/null | grep -q nginx-proxy-manager && pass "NPM collection installed" || warn "NPM collection missing (web bans won't fire)"
docker exec crowdsec cscli bouncers list 2>/dev/null | grep -q npm-bouncer && pass "firewall bouncer registered in LAPI" || warn "firewall bouncer not registered in LAPI"
if systemctl is-active --quiet crowdsec-firewall-bouncer; then
  pass "firewall bouncer service active"
  docker exec crowdsec cscli decisions add --ip 192.0.2.1 --duration 2m --reason verify-stack >/dev/null 2>&1
  # POLL up to ~36s. The bouncer pulls every 10s; when it is also syncing large
  # community blocklists (tens of thousands of decisions) the per-cycle work can
  # push a fresh decision past a single fixed wait -> false "not enforced".
  banned=no
  for _ in $(seq 1 12); do
    if { command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q '192\.0\.2\.1'; } \
       || iptables -S 2>/dev/null | grep -q '192\.0\.2\.1' \
       || ipset list 2>/dev/null | grep -q '192\.0\.2\.1'; then banned=yes; break; fi
    sleep 3
  done
  docker exec crowdsec cscli decisions delete --ip 192.0.2.1 >/dev/null 2>&1
  [[ $banned == yes ]] && pass "live ban enforced in firewall (round-trip OK)" || fail "live ban NOT enforced in firewall"
else
  fail "firewall bouncer service NOT active (host-level bans not enforced)"
fi
if systemctl list-unit-files 2>/dev/null | grep -q crowdsec-cloudflare-worker-bouncer; then
  if systemctl is-active --quiet crowdsec-cloudflare-worker-bouncer; then pass "CF worker bouncer active (edge enforcement)"
  else warn "CF worker bouncer installed but not active (enable Workers Analytics Engine in Cloudflare? check: journalctl -u crowdsec-cloudflare-worker-bouncer -n 40)"; fi
fi

# ---- C2. CrowdSec DETECTION (logs -> scenarios) ---------------------------
hdr "CrowdSec detection"
docker exec crowdsec sh -c 'cat /etc/crowdsec/acquis.d/syslog.yaml 2>/dev/null' | grep -q 'type: syslog' \
  && pass "SSH/system log acquisition configured" \
  || fail "SSH/system acquisition MISSING -- SSH/host attacks are INVISIBLE to CrowdSec"
docker exec crowdsec cscli collections list 2>/dev/null | grep -q crowdsecurity/sshd \
  && pass "sshd collection installed" || warn "sshd collection missing"
if [ -f /var/log/auth.log ]; then
  pass "/var/log/auth.log present (rsyslog writing SSH logs)"
  # live ssh-bf detection: inject a failed-login burst (TEST-NET-2, RFC5737) and
  # confirm CrowdSec parses it into a decision; then clean up.
  tip="198.51.100.66"; hn="$(hostname -s 2>/dev/null || echo host)"
  for k in $(seq 1 12); do printf '%s %s sshd[%d]: Failed password for invalid user verifyuser from %s port %d ssh2\n' \
    "$(date '+%b %e %H:%M:%S')" "$hn" "$((1000+k))" "$tip" "$((20000+k))" >> /var/log/auth.log; done
  seen=no
  for w in $(seq 1 12); do
    docker exec crowdsec cscli decisions list -o raw 2>/dev/null | grep -q "$tip" && { seen=yes; break; }
    docker exec crowdsec cscli alerts list -o raw 2>/dev/null | grep -q "$tip" && { seen=yes; break; }
    sleep 3
  done
  docker exec crowdsec cscli decisions delete --ip "$tip" >/dev/null 2>&1
  [ "$seen" = yes ] && pass "live ssh-bf DETECTION works (auth.log parsed -> decision)" \
    || fail "synthetic ssh-bf NOT detected (docker exec crowdsec cscli metrics)"
else
  fail "/var/log/auth.log MISSING -- SSH detection inactive (is rsyslog running?)"
fi

# ---- D. Security posture --------------------------------------------------
hdr "Security posture"
# NPM default creds MUST be rejected
if curl -s --max-time 5 -X POST http://127.0.0.1:81/api/tokens -H 'Content-Type: application/json' \
     -d '{"identity":"admin@example.com","secret":"changeme"}' 2>/dev/null | grep -q '"token"'; then
  fail "NPM DEFAULT password STILL ACTIVE (admin@example.com / changeme) -- change it NOW at :81"
else
  pass "NPM default creds rejected"
fi
# host firewall active
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then pass "UFW active"
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q running; then pass "firewalld active"
else fail "no active host firewall"; fi
# LAPI + Authentik must NOT be world-listening
binds="$(ss -tlnH 2>/dev/null | awk '{print $4}')"
echo "$binds" | grep -qE '0\.0\.0\.0:8080$|\[::\]:8080$|\*:8080$' && fail "CrowdSec LAPI :8080 EXPOSED on all interfaces" || pass "CrowdSec LAPI :8080 not world-listening"
echo "$binds" | grep -qE '0\.0\.0\.0:9000$|\[::\]:9000$|\*:9000$' && fail "Authentik :9000 EXPOSED on all interfaces" || pass "Authentik :9000 not world-listening"
echo "$binds" | grep -qE '0\.0\.0\.0:81$|\[::\]:81$|\*:81$'       && warn "NPM admin UI :81 listening on all interfaces -- restrict to LAN/VPN" || pass "NPM admin :81 not world-open"
# Dockhand host filesystem mount must be read-only
mnt="$(docker inspect -f '{{range .Mounts}}{{.Destination}}={{.RW}}{{"\n"}}{{end}}' dockhand 2>/dev/null | grep '^/host=')"
if [[ -n "$mnt" ]]; then
  echo "$mnt" | grep -q '=false$' && pass "Dockhand host fs mounted READ-ONLY (/host:ro)" || fail "Dockhand host fs mounted READ-WRITE -- a Dockhand compromise = root on host"
else warn "Dockhand /host mount not found (ok if intentionally removed)"; fi
docker inspect -f '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' dockhand 2>/dev/null | grep -q '/var/run/docker.sock' \
  && warn "Dockhand has docker.sock (root-equivalent, by design) -- the auth gate is your ONLY protection" || true
# Authentik forward-auth gate on the dockhand proxy host
gate="$(docker exec npm sh -c "grep -lsi 'authentik' /data/nginx/proxy_host/*.conf 2>/dev/null | xargs -r grep -lsi 'dockhand' 2>/dev/null" 2>/dev/null || true)"
if [[ -n "$gate" ]]; then pass "Authentik forward-auth gate present on dockhand proxy host"
else fail "dockhand proxy host has NO Authentik gate -- root-access UI is unprotected at the edge"; fi
# best-effort external redirect probe
if [[ -n "$DOMAIN" ]]; then
  red="$(curl -sk -o /dev/null -w '%{http_code}|%{redirect_url}' --max-time 8 \
        --resolve "dockhand.${DOMAIN}:443:127.0.0.1" "https://dockhand.${DOMAIN}/" 2>/dev/null || true)"
  echo "$red" | grep -qi 'goauthentik\|/outpost' \
    && pass "dockhand.${DOMAIN} redirects to Authentik (gate live)" \
    || warn "dockhand.${DOMAIN} did not redirect to Authentik (gate off, or session cached): [$red]"
fi
# credential file perms
for f in "${STACK_DIR}/.npm_admin_password" "${AUTHENTIK_DIR}/.akadmin_password" \
         /etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml; do
  [[ -f "$f" ]] || continue
  m="$(stat -c '%a' "$f" 2>/dev/null || echo '?')"
  [[ "$m" == "600" ]] && pass "perms 600 on $(basename "$f")" || warn "perms $m on $f (want 600)"
done

# ---- E. Manual checks (cannot be auto-verified) --------------------------
hdr "Manual checks"
printf "  - Dockhand built-in auth: Dockhand > Settings > Authentication -> confirm the ENABLE\n"
printf "    toggle is ON. Creating a user alone does NOT turn auth on.\n"
printf "  - Keep Dockhand on LOCAL auth (not OIDC/header-trust) so it stays a SECOND, independent\n"
printf "    layer behind Authentik -- otherwise the two gates collapse into one sign-on.\n"
printf "  - 2FA: akadmin has a TOTP device in Authentik; Dockhand local user has a strong password.\n"
printf "  - TLS: https://dockhand.%s shows a valid Let's Encrypt certificate.\n" "${DOMAIN:-<domain>}"

# ---- Summary --------------------------------------------------------------
hdr "Summary"
printf "${C_G}PASS:%d${C_R}   ${C_Y}WARN:%d${C_R}   ${C_RED}FAIL:%d${C_R}\n" "$P" "$W" "$F"
if   [[ $F -gt 0 ]]; then printf "${C_RED}${C_B}NOT fully secured -- resolve the FAIL items above.${C_R}\n"; exit 1
elif [[ $W -gt 0 ]]; then printf "${C_Y}${C_B}Functional, with posture WARNings to review.${C_R}\n"; exit 0
else printf "${C_G}${C_B}All checks passed.${C_R}\n"; exit 0; fi
