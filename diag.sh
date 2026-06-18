#!/usr/bin/env bash
# diag.sh -- NetBird reverse proxy certificate / ACME diagnostics
# Usage: sudo bash diag.sh
if [[ "${EUID:-0}" -ne 0 ]]; then exec sudo bash "$0" "$@"; fi

B='\033[1m'; G='\033[0;32m'; Y='\033[0;33m'; R='\033[0;31m'; N='\033[0m'
hr() { printf "${B}══════════════════════════════════════════════════════════════════════${N}\n"; }

DOMAIN=$(cat /etc/vps-deploy-domain 2>/dev/null || echo "<unknown>")
hr; printf "${B} NetBird Reverse Proxy Diagnostic${N}\n"
printf " Domain: ${B}%s${N}\n" "$DOMAIN"
printf " Date:   %s\n" "$(date)"
printf " VPS IP: %s\n" "$(hostname -I 2>/dev/null | awk '{print $1}')"
hr

printf "\n${B}== 1. Containers ==${N}\n"
for c in traefik netbird-server netbird-proxy authentik-server dockhand crowdsec; do
  s=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo "not found")
  [[ "$s" == "running" ]] && printf "  ${G}[OK]${N}  %-22s %s\n" "$c" "$s" \
                         || printf "  ${R}[!!]${N} %-22s %s\n" "$c" "$s"
done

printf "\n${B}== 2. Port 443 reachability (from the VPS itself) ==${N}\n"
if ss -tln 2>/dev/null | grep -q ':443 '; then
  printf "  ${G}[OK]${N} Port 443 is bound on the host\n"
else
  printf "  ${R}[!!]${N} Port 443 is NOT bound -- Traefik may not be running\n"
fi
# Test if Let's Encrypt can reach us (TLS-ALPN-01 needs 443 from the internet)
if command -v curl &>/dev/null; then
  ext_ip=$(curl -s -4 --max-time 10 https://api.ipify.org 2>/dev/null || echo "unknown")
  printf "  External IP: %s\n" "$ext_ip"
  printf "  DNS resolves *.%s to: %s\n" "$DOMAIN" \
    "$(dig +short "*.${DOMAIN}" A 2>/dev/null | head -1 || echo '<dig not found>')"
  printf "  DNS resolves %s to: %s\n" "$DOMAIN" \
    "$(dig +short "${DOMAIN}" A 2>/dev/null | head -1 || echo '<dig not found>')"
fi

printf "\n${B}== 3. Traefik ACME logs (cert for netbird.%s) ==${N}\n" "$DOMAIN"
docker logs traefik --tail 50 2>&1 | grep -iE 'acme|cert|error|let.?s.?encrypt|challenge|rate|timeout|fail' | tail -20 || echo "  (no ACME-related lines)"

printf "\n${B}== 4. NetBird proxy logs (ACME for dockhand/authentik) ==${N}\n"
docker logs netbird-proxy --tail 80 2>&1 | grep -iE 'acme|cert|error|rate|challenge|fail|timeout|issue|pending|tunnel|sync|register|connect' | tail -30 || echo "  (no relevant lines)"

printf "\n${B}== 5. NetBird proxy -- full last 30 lines ==${N}\n"
docker logs netbird-proxy --tail 30 2>&1 | sed 's/^/  /' || echo "  (container not found)"

printf "\n${B}== 6. Reverse proxy services (via management API) ==${N}\n"
NB_PAT=$(cat /opt/netbird-stack/netbird/.api_token 2>/dev/null || echo "")
nb_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' netbird-server 2>/dev/null || echo "")
if [[ -n "$NB_PAT" && -n "$nb_ip" ]]; then
  printf "  Clusters:\n"
  curl -s --max-time 5 -H "Authorization: Token ${NB_PAT}" \
    "http://${nb_ip}:80/api/reverse-proxies/clusters" 2>/dev/null \
    | jq -C '.[] | {address, type, online, private, connected_proxies}' 2>/dev/null | sed 's/^/    /' || echo "    (API call failed)"
  printf "  Services:\n"
  curl -s --max-time 5 -H "Authorization: Token ${NB_PAT}" \
    "http://${nb_ip}:80/api/reverse-proxies/services" 2>/dev/null \
    | jq -C '.[] | {name, domain, mode, status: .meta.status, enabled}' 2>/dev/null | sed 's/^/    /' || echo "    (API call failed or no services)"
else
  printf "  ${Y}(no PAT or netbird-server IP found -- skipping API checks)${N}\n"
fi

printf "\n${B}== 7. Firewall (host-level) ==${N}\n"
if command -v ufw &>/dev/null; then
  ufw status 2>/dev/null | grep -E '443|80|3478|Status' | sed 's/^/  /'
else
  printf "  (ufw not found)\n"
fi

printf "\n${B}== 8. Let's Encrypt rate limit check ==${N}\n"
# Count how many times we've requested certs today (rough proxy: ACME log lines)
acme_count=$(docker logs traefik 2>&1 | grep -ci 'acme.*register\|acme.*cert.*request\|obtaining certificate' 2>/dev/null || echo 0)
nb_acme_count=$(docker logs netbird-proxy 2>&1 | grep -ci 'acme\|certificate\|challenge' 2>/dev/null || echo 0)
printf "  Traefik ACME-related log lines: %s\n" "$acme_count"
printf "  NetBird proxy ACME-related log lines: %s\n" "$nb_acme_count"
if [[ "$acme_count" -gt 20 || "$nb_acme_count" -gt 20 ]]; then
  printf "  ${Y}[!] High ACME activity -- you may be approaching Let's Encrypt rate limits${N}\n"
  printf "  Limits: 50 certs/registered domain/week, 5 failed validations/hostname/hour, 5 duplicate certs/week\n"
fi

# Check for explicit rate limit messages
if docker logs traefik 2>&1 | grep -qi 'rate.*limit\|too many\|429'; then
  printf "  ${R}[!!] TRAEFIK: Rate limit detected in logs!${N}\n"
  docker logs traefik 2>&1 | grep -i 'rate.*limit\|too many\|429' | tail -5 | sed 's/^/    /'
fi
if docker logs netbird-proxy 2>&1 | grep -qi 'rate.*limit\|too many\|429'; then
  printf "  ${R}[!!] NETBIRD PROXY: Rate limit detected in logs!${N}\n"
  docker logs netbird-proxy 2>&1 | grep -i 'rate.*limit\|too many\|429' | tail -5 | sed 's/^/    /'
fi

printf "\n${B}== 9. TLS-ALPN-01 local test (can Traefik answer on 443?) ==${N}\n"
if command -v openssl &>/dev/null; then
  issuer=$(echo | timeout 5 openssl s_client -connect 127.0.0.1:443 -servername "netbird.${DOMAIN}" 2>/dev/null \
           | openssl x509 -noout -issuer 2>/dev/null || echo "FAILED")
  if echo "$issuer" | grep -qi "let's encrypt"; then
    printf "  ${G}[OK]${N} netbird.%s has a valid Let's Encrypt cert\n" "$DOMAIN"
  elif echo "$issuer" | grep -qi "trajek\|traefik\|default"; then
    printf "  ${Y}[!]${N} netbird.%s is using Traefik's default cert (LE not issued yet)\n" "$DOMAIN"
  else
    printf "  ${R}[!!]${N} No cert / connection failed: %s\n" "$issuer"
  fi
else
  printf "  (openssl not found)\n"
fi

printf "\n${B}== 10. Deploy log (last 20 lines) ==${N}\n"
tail -20 /var/log/vps-deploy.log 2>/dev/null | sed 's/^/  /' || echo "  (no log file)"

hr
printf "${B}Diagnostic complete.${N} Share this output to diagnose the cert issue.\n"
hr
