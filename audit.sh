#!/usr/bin/env bash
# audit.sh -- read-only deploy + security audit for the NetBird/Traefik stack.
# Run on the VPS:  sudo bash audit.sh
# PASS = good | WARN = review (often expected before harden.sh) | FAIL = fix it.
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then exec sudo bash "$0" "$@"; fi
set +e
G=$'\e[1;32m'; Y=$'\e[1;33m'; R=$'\e[1;31m'; B=$'\e[1m'; N=$'\e[0m'
pass(){ printf "  ${G}[PASS]${N} %s\n" "$*"; }
warn(){ printf "  ${Y}[WARN]${N} %s\n" "$*"; }
fail(){ printf "  ${R}[FAIL]${N} %s\n" "$*"; }
hdr(){  printf "\n${B}== %s ==${N}\n" "$*"; }

D=$(cat /etc/vps-deploy-domain 2>/dev/null)
printf "${B}Stack audit -- domain: %s -- %s${N}\n" "${D:-<none>}" "$(date)"

hdr "Containers up"
EXP="traefik authentik-server authentik-worker authentik-postgres authentik-redis netbird-server netbird-dashboard dockhand crowdsec"
for c in $EXP; do
  s=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)
  [ "$s" = running ] && pass "$c ($s)" || fail "$c is '$s' (not running)"
done

hdr "Public ports (world-reachable should be ONLY 22, 80, 443, 3478/udp)"
ss -tulnH 2>/dev/null | awk '{print $1, $5}' | grep -E '0\.0\.0\.0|\[::\]|(^|[^0-9])\*:' | sort -u | while read -r proto addr; do
  port=${addr##*:}
  case "$port" in
    22|80|443) pass "$proto $addr (expected)";;
    3478)      pass "$proto $addr (NetBird STUN)";;
    *)         fail "$proto $addr  <-- UNEXPECTED public port";;
  esac
done

hdr "Sensitive services must NOT be public (localhost/internal only)"
for pair in "5432 postgres" "6379 redis" "8080 crowdsec-LAPI" "9000 authentik"; do
  p=${pair% *}; name=${pair#* }
  if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "(0\.0\.0\.0|\[::\]|\*):$p\$"; then
    fail "$name ($p) is PUBLICLY bound"
  else
    pass "$name ($p) not public"
  fi
done

hdr "Host firewall"
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  pass "UFW active"
  ufw status verbose 2>/dev/null | grep -iE 'Default:|22|80/|443/|3478' | sed 's/^/      /'
elif systemctl is-active --quiet firewalld 2>/dev/null; then
  pass "firewalld active"
else
  warn "no host firewall active"
fi
if iptables -S 2>/dev/null | grep -qiE -- '-j (REJECT|DROP)'; then
  warn "iptables has REJECT/DROP rules. If external 80/443 fails (Oracle default!), allow them:"
  warn "    iptables -I INPUT -p tcp --dport 80 -j ACCEPT; iptables -I INPUT -p tcp --dport 443 -j ACCEPT; netfilter-persistent save"
fi

hdr "CrowdSec (intrusion prevention)"
docker exec crowdsec cscli collections list 2>/dev/null | grep -q 'crowdsecurity/traefik' && pass "traefik collection (web attack detection)" || fail "traefik collection MISSING"
docker exec crowdsec cscli collections list 2>/dev/null | grep -q 'crowdsecurity/sshd'    && pass "sshd collection (SSH brute-force)"      || warn "sshd collection missing"
docker exec crowdsec cscli bouncers list 2>/dev/null | grep -q 'firewall-bouncer' && pass "firewall bouncer registered" || warn "firewall bouncer not registered"
systemctl is-active --quiet crowdsec-firewall-bouncer && pass "firewall-bouncer service active" || fail "firewall-bouncer service NOT active"
nft list tables 2>/dev/null | grep -qi crowdsec && pass "crowdsec nftables present (bans enforced in kernel)" || warn "no crowdsec nft tables"
printf "  ${B}live ban test${N} (adds + removes a reserved test IP)...\n"
docker exec crowdsec cscli decisions add --ip 192.0.2.123 --duration 1m --reason audit >/dev/null 2>&1
sleep 12
if nft list ruleset 2>/dev/null | grep -q '192\.0\.2\.123' || iptables -S 2>/dev/null | grep -q '192\.0\.2\.123'; then
  pass "ban enforced end-to-end (LAPI -> bouncer -> firewall)"
else
  warn "test ban not in firewall yet (bouncer pulls ~10s; re-check or see bouncer logs)"
fi
docker exec crowdsec cscli decisions delete --ip 192.0.2.123 >/dev/null 2>&1

hdr "TLS / public cert"
iss=$(echo | timeout 5 openssl s_client -connect 127.0.0.1:443 -servername "netbird.${D}" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null)
if echo "$iss" | grep -qi "let's encrypt"; then pass "valid Let's Encrypt cert"
else warn "NOT a public cert ($iss) -- DNS or inbound-443 blocked, ACME can't validate"; fi

hdr "Container hardening"
for c in $EXP; do
  [ "$(docker inspect -f '{{.HostConfig.Privileged}}' "$c" 2>/dev/null)" = true ] && fail "$c runs PRIVILEGED"
done
for c in $(docker ps --format '{{.Names}}'); do
  if docker inspect "$c" 2>/dev/null | grep -q '/var/run/docker.sock'; then
    case "$c" in
      dockhand)         pass "dockhand docker.sock (by design; host / is :ro)";;
      traefik)          pass "traefik docker.sock (Traefik label discovery, :ro)";;
      authentik-worker) pass "authentik-worker docker.sock (manages embedded outpost)";;
      *)                warn "$c mounts docker.sock (root-equivalent) -- unexpected";;
    esac
  fi
done

hdr "SSH hardening (expected only after harden.sh)"
sshd -T 2>/dev/null | grep -qiE 'permitrootlogin (no|prohibit-password|without-password)' && pass "root login restricted" || warn "root SSH login not restricted -- run harden.sh"
sshd -T 2>/dev/null | grep -qi 'passwordauthentication no' && pass "SSH password auth disabled" || warn "SSH password auth ENABLED -- run harden.sh"

hdr "Auto security updates"
systemctl is-active --quiet unattended-upgrades 2>/dev/null && pass "unattended-upgrades active" || warn "auto-updates inactive -- run harden.sh"

hdr "Credential files (want mode 600)"
for f in "/opt/netbird-stack/authentik/.akadmin_password" "/opt/netbird-stack/authentik/authentik.env"; do
  [ -f "$f" ] && { m=$(stat -c '%a' "$f" 2>/dev/null); [ "$m" = 600 ] && pass "$f ($m)" || warn "$f is $m (want 600)"; }
done

printf "\n${B}Done.${N} FAIL = fix now. WARN before running harden.sh is normal (SSH/updates/firewall hardening is harden.sh's job).\n"
