#!/usr/bin/env bash
# Auto-elevate to root if not already running as root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi
# VPS Deployment — Authelia SSO + MFA behind Nginx Proxy Manager
# Provides TOTP 2FA login portal for ALL services behind NPM
# One-click, idempotent deployment
set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_VER="1.0.0"
readonly LOGFILE="/var/log/vps-deploy.log"
readonly DATA_DIR="/opt/authelia"
readonly SECRETS_DIR="/opt/authelia/config/secrets"

# Deployment status
DEPLOY_STATUS="in_progress"
START_TIME=$(date +%s)

get_external_ip() {
  curl -s -4 --max-time 10 https://api.ipify.org 2>/dev/null || \
  curl -s -4 --max-time 10 https://ifconfig.me 2>/dev/null || \
  curl -s -4 --max-time 10 https://icanhazip.com 2>/dev/null || \
  echo "unknown"
}

_on_exit() {
  local exit_code=$?
  local elapsed=$(( $(date +%s) - START_TIME ))
  local ip ext_ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<internal_ip>")
  ext_ip=$(get_external_ip)
  if [[ -n "${DEPLOYED_SERVICES:-}" ]] || [[ "$DEPLOY_STATUS" != "in_progress" ]]; then
    printf "\n"
    if [[ "$DEPLOY_STATUS" == "success" ]]; then
      printf "${C_B}${C_GRN}╔══════════════════════════════════════════════════════════════════════════════╗${C_R}\n"
      printf "${C_B}${C_GRN}║                    ✅  AUTHELIA DEPLOYMENT COMPLETE                            ║${C_R}\n"
      printf "${C_B}${C_GRN}╠══════════════════════════════════════════════════════════════════════════════╣${C_R}\n"
    else
      printf "${C_B}${C_RED}╔══════════════════════════════════════════════════════════════════════════════╗${C_R}\n"
      printf "${C_B}${C_RED}║                     ❌  DEPLOYMENT DID NOT COMPLETE                           ║${C_R}\n"
      printf "${C_B}${C_RED}╠══════════════════════════════════════════════════════════════════════════════╣${C_R}\n"
    fi
    printf "${C_B}║  Internal:  ${C_CYN}%-16s${C_R}${C_B}  Elapsed: ${C_CYN}%dm %02ds${C_R}                              ║${C_R}\n" "$ip" "$((elapsed/60))" "$((elapsed%60))"
    printf "${C_B}║  External:  ${C_CYN}%-16s${C_R}${C_B}                                                   ║${C_R}\n" "$ext_ip"
    printf "${C_B}╠══════════════════════════════════════════════════════════════════════════════╣${C_R}\n"
    printf "${C_B}║  ${C_YEL}Portal   ${C_R}${C_B}:  https://${C_CYN}%-55s${C_R}${C_B}║${C_R}\n" "authelia.${DOMAIN:-yourdomain.com}"
    printf "${C_B}║  ${C_YEL}Config   ${C_R}${C_B}:  ${C_CYN}%-63s${C_R}${C_B}║${C_R}\n" "$DATA_DIR/config/"
    printf "${C_B}╠══════════════════════════════════════════════════════════════════════════════╣${C_R}\n"
    printf "${C_B}║  Log file: ${C_CYN}%-66s${C_R}${C_B}║${C_R}\n" "$LOGFILE"
    printf "${C_B}╚══════════════════════════════════════════════════════════════════════════════╝${C_R}\n"
    printf "\n"
    if [[ "$DEPLOY_STATUS" == "success" ]]; then
      printf "${C_B}${C_GRN}Authelia is ready!${C_R} Configure DNS → ${C_CYN}${ext_ip}${C_R} and set up NPM.\n\n"
    else
      printf "${C_B}${C_YEL}The deployment did not finish.${C_R} Check: ${C_CYN}cat %s${C_R}\n\n" "$LOGFILE"
    fi
  fi
  exit $exit_code
}
trap _on_exit EXIT

# Root domain — set at runtime from user input
DOMAIN=""

# ─── Styling ──────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_R='\033[0m'; C_B='\033[1m'; C_RED='\033[0;31m'; C_GRN='\033[0;32m'
  C_YEL='\033[0;33m'; C_BLU='\033[0;34m'; C_CYN='\033[0;36m'; C_DIM='\033[2m'
else
  C_R=''; C_B=''; C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_CYN=''; C_DIM=''
fi

_ts() { date '+%Y-%m-%d %H:%M:%S'; }
_log() { printf "[%s] [%-5s] %s\n" "$(_ts)" "$1" "${*:2}" >> "$LOGFILE" 2>/dev/null || true; }
ok()   { printf "${C_GRN}✔${C_R} %s\n" "$*"; _log "OK" "$*"; }
warn() { printf "${C_YEL}!${C_R} %s\n" "$*"; _log "WARN" "$*"; }
info() { printf "${C_BLU}→${C_R} %s\n" "$*"; _log "INFO" "$*"; }
step() { printf "\n${C_B}▶ %s${C_R}\n" "$*"; _log "STEP" "$*"; }
fatal(){ printf "${C_RED}✖ %s${C_R}\n" "$*" >&2; _log "FATAL" "$*"; DEPLOY_STATUS="failed"; exit 1; }

# ═══════════════════════════════════════════════════════════════════════════════
# PRE-FLIGHT CHECKS
# ═══════════════════════════════════════════════════════════════════════════════
preflight_checks() {
  info "Pre-flight checks ..."
  [[ "$(id -u)" -eq 0 ]] || fatal "Run as root (use sudo)."
  command -v docker &>/dev/null || fatal "Docker is required. Install it first."
  docker compose version &>/dev/null || docker-compose version &>/dev/null || \
    fatal "Docker Compose plugin required."
  ok "Pre-flight passed"
}

# ═══════════════════════════════════════════════════════════════════════════════
# GET USER DOMAIN
# ═══════════════════════════════════════════════════════════════════════════════
get_user_domain() {
  step "Domain Configuration"

  # Check if we already have a domain configured
  if [[ -f "$DATA_DIR/config/configuration.yml" ]]; then
    local existing_domain
    existing_domain=$(grep "authelia_url:" "$DATA_DIR/config/configuration.yml" 2>/dev/null | sed 's/.*https:\/\/authelia\.//' | tr -d ' ' || true)
    if [[ -n "$existing_domain" ]]; then
      info "Existing domain found: $existing_domain"
      read -rp "Use existing domain? [Y/n]: " use_existing
      [[ "$use_existing" =~ ^[Nn]$ ]] || { DOMAIN="$existing_domain"; return 0; }
    fi
  fi

  # Prompt for domain
  printf "\n${C_B}Enter your root domain${C_R} (e.g., example.com, yourdomain.com): "
  read -r DOMAIN

  # Validate
  if [[ -z "$DOMAIN" ]]; then
    fatal "Domain is required. Example: example.com"
  fi

  # Strip any protocol or whitespace
  DOMAIN=$(echo "$DOMAIN" | sed 's|https\?://||' | sed 's|/.*||' | tr -d ' ')

  ok "Domain set to: $DOMAIN"
}

# ═══════════════════════════════════════════════════════════════════════════════
# NETWORK
# ═══════════════════════════════════════════════════════════════════════════════
setup_docker_network() {
  step "Docker network"
  if ! docker network ls --format '{{.Name}}' | grep -q '^proxy$'; then
    info "Creating external bridge network 'proxy' ..."
    docker network create proxy || fatal "Failed to create proxy network"
    ok "Network 'proxy' created"
  else
    ok "Network 'proxy' already exists"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# SECRETS
# ═══════════════════════════════════════════════════════════════════════════════
generate_secrets() {
  step "Generating secrets ..."
  mkdir -p "$SECRETS_DIR"

  local s
  for s in jwt_session storage_encryption session; do
    local f="$SECRETS_DIR/$s"
    if [[ ! -f "$f" ]]; then
      tr -cd '[:alnum:]' </dev/urandom | fold -w 64 | head -n 1 > "$f"
      chmod 600 "$f"
      ok "Secret '$s' generated"
    else
      ok "Secret '$s' already exists"
    fi
  done
}

# ═══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════
generate_config() {
  step "Authelia configuration ..."
  mkdir -p "$DATA_DIR/config"

  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<VPS_IP>")

  # ── Authelia configuration.yml ────────────────────────────────────────────
  if [[ ! -f "$DATA_DIR/config/configuration.yml" ]]; then
    cat > "$DATA_DIR/config/configuration.yml" << EOF
---
# Authelia Lite Configuration
# Provides SSO + TOTP 2FA for all services behind NPM

server:
  address: tcp://0.0.0.0:9091
  endpoints:
    authz:
      forward-auth:
        implementation: 'ForwardAuth'

log:
  level: info
  format: text

totp:
  issuer: authelia.${DOMAIN}
  period: 30
  skew: 1

authentication_backend:
  file:
    path: /config/users.yml
    search:
      email: false
    password:
      algorithm: argon2id
      iterations: 1
      key_length: 32
      salt_length: 16
      memory: 65536
      parallelism: 4

access_control:
  default_policy: two_factor
  rules:
    # Authelia portal itself — one_factor (password only) for portal access
    - domain: 'authelia.${DOMAIN}'
      policy: one_factor
    # Admin panels require 2FA
    - domain:
        - 'portainer.${DOMAIN}'
        - 'dockge.${DOMAIN}'
        - 'coolify.${DOMAIN}'
        - 'dokploy.${DOMAIN}'
        - 'casaos.${DOMAIN}'
        - 'runtipi.${DOMAIN}'
        - 'cosmos.${DOMAIN}'
      policy: two_factor
    # Catch-all for other subdomains under your domain
    - domain: '*.${DOMAIN}'
      policy: two_factor

session:
  name: authelia_session
  same_site: lax
  expiration: 1h
  inactivity: 5m
  remember_me_duration: 1M
  cookies:
    - domain: '${DOMAIN}'
      authelia_url: 'https://authelia.${DOMAIN}'
      default_redirection_url: 'https://npm.${DOMAIN}'

regulation:
  max_retries: 3
  find_time: 2m
  ban_time: 1h

storage:
  local:
    path: /config/db.sqlite3

notifier:
  filesystem:
    filename: /config/notifications.txt
EOF
    ok "configuration.yml created"
  else
    ok "configuration.yml already exists (preserved)"
  fi

  # ── Users database ────────────────────────────────────────────────────────
  if [[ ! -f "$DATA_DIR/config/users.yml" ]]; then
    cat > "$DATA_DIR/config/users.yml" << 'USERS'
---
# Authelia Users Database
# To add a user: run 'authelia crypto hash generate argon2' and paste the hash
# To hash a password: docker exec authelia authelia crypto hash generate argon2 --password 'YOUR_PASSWORD'

users:
  admin:
    disabled: false
    displayname: "Administrator"
    password: "$argon2id$v=19$m=65536,t=3,p=4$bXJzdWZmc3R1ZmZz$dHYzV3l1YVNhRjZwbHBLWGJzRjh4NUZNaTgxMXZVQUFEZ0lYVDlLVzgwU1dWMnpQS1VDdGV"
    email: admin@CHANGEME_DOMAIN
    groups:
      - admins
      - users
USERS
    sed -i "s/CHANGEME_DOMAIN/${DOMAIN}/" "$DATA_DIR/config/users.yml"
    warn "Default user 'admin' created with password 'changeme' — CHANGE THIS IMMEDIATELY"
    ok "users.yml created"
  else
    ok "users.yml already exists (preserved)"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# CONTAINER
# ═══════════════════════════════════════════════════════════════════════════════
deploy_authelia() {
  step "Deploying Authelia ..."

  # Remove old container if exists
  docker rm -f authelia 2>/dev/null || true

  info "Pulling latest Authelia image (this may take a moment) ..."
  docker pull authelia/authelia:latest >/dev/null 2>&1 || warn "Pull may have issues, continuing with local image"

  docker run -d \
    --name authelia \
    --hostname authelia \
    --restart always \
    --network proxy \
    -p 127.0.0.1:9091:9091 \
    -v "$DATA_DIR/config:/config" \
    -e AUTHELIA_JWT_SECRET_FILE=/config/secrets/jwt_session \
    -e AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE=/config/secrets/storage_encryption \
    -e AUTHELIA_SESSION_SECRET_FILE=/config/secrets/session \
    -e AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET_FILE=/config/secrets/jwt_session \
    -e TZ=America/New_York \
    authelia/authelia:latest

  ok "Authelia container deployed"
}

# ═══════════════════════════════════════════════════════════════════════════════
# VERIFY
# ═══════════════════════════════════════════════════════════════════════════════
verify_authelia() {
  step "Verifying Authelia ..."

  info "Waiting for Authelia API to become healthy ..."
  for i in $(seq 1 30); do
    docker exec authelia wget -qO- --timeout=3 http://127.0.0.1:9091/api/health 2>/dev/null | grep -q "ok" && {
      ok "Authelia API responding"
      return 0
    }
    printf "${C_DIM}  Waiting... (%d/30)${C_R}\r" "$i"
    sleep 2
  done

  warn "Authelia health check timed out — check: docker logs authelia"
  return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# SNIPPETS — align with official Authelia NGINX Proxy Manager integration
# ═══════════════════════════════════════════════════════════════════════════════
create_snippets() {
  step "Creating NGINX snippets for NPM integration ..."
  local snippets_dir="$DATA_DIR/snippets"
  mkdir -p "$snippets_dir"

  cat > "$snippets_dir/proxy.conf" << 'SNIPPET'
## Authelia proxy.conf — headers for proxied applications
## Based on: https://www.authelia.com/integration/proxies/nginx/
client_body_buffer_size 128k;
proxy_next_upstream error timeout invalid_header http_500 http_502 http_503;
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host $http_host;
proxy_set_header X-Forwarded-Uri $request_uri;
proxy_set_header X-Forwarded-Ssl on;
proxy_redirect http:// $scheme://;
proxy_http_version 1.1;
proxy_set_header Connection "";
proxy_cache_bypass $cookie_session;
proxy_no_cache $cookie_session;
proxy_buffers 4 32k;
proxy_send_timeout 600s;
proxy_read_timeout 600s;
SNIPPET

  cat > "$snippets_dir/authelia-location.conf" << SNIPPET
## Authelia auth verification endpoint
## Mount this directory into NPM as /snippets/ and include in Advanced tab
location /authelia {
    internal;
    proxy_pass http://authelia:9091/api/verify;
    proxy_set_header X-Original-URL \$scheme://\$http_host\$request_uri;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-Method \$request_method;
    proxy_pass_request_body off;
    proxy_pass_request_headers on;
    proxy_set_header Content-Length "";
    proxy_set_header Connection "";
}
SNIPPET

  cat > "$snippets_dir/authelia-authrequest.conf" << SNIPPET
## Authelia auth_request directive
## Add inside the location / {} block in NPM Advanced tab
auth_request /authelia;
auth_request_set \$user \$upstream_http_remote_user;
proxy_set_header Remote-User \$user;
auth_request_set \$groups \$upstream_http_remote_groups;
proxy_set_header Remote-Groups \$groups;
auth_request_set \$name \$upstream_http_remote_name;
proxy_set_header Remote-Name \$name;
auth_request_set \$email \$upstream_http_remote_email;
proxy_set_header Remote-Email \$email;
error_page 401 = @authelia_signin;
SNIPPET

  ok "NGINX snippets created in $snippets_dir"
}

# ═══════════════════════════════════════════════════════════════════════════════
# NPM INTEGRATION
# ═══════════════════════════════════════════════════════════════════════════════
configure_npm_integration() {
  step "NPM Forward-Auth Integration"
  info "Authelia is ready. Two proxy hosts needed:"
  echo ""
  echo "  1. AUTHELIA PORTAL (NOT protected — must be accessible to log in)"
  echo "     Domain: authelia.${DOMAIN} → http://authelia:9091"
  echo "     Advanced tab:"
  echo "       location / {"
  echo "         include /snippets/proxy.conf;"
  echo "         proxy_pass \$forward_scheme://\$server:\$port;"
  echo "       }"
  echo ""
  echo "  2. PROTECTED DASHBOARDS (each gets 2FA)"
  echo "     For EACH dashboard, edit its proxy host Advanced tab:"
  echo "       include /snippets/authelia-location.conf;"
  echo "       location / {"
  echo "         include /snippets/proxy.conf;"
  echo "         include /snippets/authelia-authrequest.conf;"
  echo "         proxy_pass \$forward_scheme://\$server:\$port;"
  echo "       }"
  echo ""
  echo "  Full config with comments: $DATA_DIR/authelia-configure.sh"
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# HELPER SCRIPT
# ═══════════════════════════════════════════════════════════════════════════════
create_helper_script() {
  local helper="$DATA_DIR/authelia-configure.sh"
  cat > "$helper" << HELPER
#!/usr/bin/env bash
# Authelia NPM Configuration Helper
# Based on: https://www.authelia.com/integration/proxies/nginx-proxy-manager/
#
# Two ways to set up:
#   A) Inline (quick) — copy-paste from this script into NPM Advanced tab
#   B) Snippets (clean) — mount snippet files into NPM container
#
# SNIPPETS LOCATION: $DATA_DIR/snippets/
#   - proxy.conf
#   - authelia-location.conf
#   - authelia-authrequest.conf

AUTH_DOMAIN="authelia.${DOMAIN}"

echo "==================================================================="
echo "Authelia NPM Configuration"
echo "==================================================================="
echo ""
echo "METHOD A: INLINE (copy-paste into NPM Advanced tab)"
echo "-----------------------------------------------------"
echo "For each proxy host you want to protect, paste this into"
echo "NPM → Proxy Hosts → Edit → Advanced tab:"
echo ""
cat << 'NGINX'
# Authelia forward-auth protection
# Paste the ENTIRE block below into the Advanced tab

include /snippets/authelia-location.conf;

location / {
    include /snippets/proxy.conf;
    include /snippets/authelia-authrequest.conf;
    proxy_pass \$forward_scheme://\$server:\$port;
}

# For apps that need websockets (e.g., Portainer, Dockge):
# include /snippets/websocket.conf;
NGINX

echo ""
echo "METHOD B: MOUNT SNIPPETS (cleaner, recommended)"
echo "------------------------------------------------"
echo "1. Mount snippets into NPM container:"
echo "   $DATA_DIR/snippets/ → /snippets/ in NPM"
echo ""
echo "2. Then in each proxy host Advanced tab, just paste:"
echo ""
echo "   include /snippets/authelia-location.conf;"
echo "   location / {"
echo "       include /snippets/proxy.conf;"
echo "       include /snippets/authelia-authrequest.conf;"
echo "       proxy_pass \\\$forward_scheme://\\\$server:\\\$port;"
echo "   }"
echo ""
echo "DOMAIN SET: ${DOMAIN}"
echo "AUTHELIA URL: https://authelia.${DOMAIN}"
echo ""
HELPER
  chmod +x "$helper"
  ok "Helper script created: $helper"
}

# ═══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════
print_summary() {
  local ip ext_ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<VPS_IP>")
  ext_ip=$(get_external_ip)

  cat << EOF

===============================================================================
  Authelia SSO + MFA Deployed Successfully
===============================================================================

  Domain:     ${DOMAIN}
  Portal:     https://authelia.${DOMAIN} (add this DNS record first)
  Internal:   ${ip}
  External:   ${ext_ip}
  Config:     $DATA_DIR/config/
  Secrets:    $SECRETS_DIR/
  Users:      $DATA_DIR/config/users.yml

  Default login:
    Username: admin
    Password: changeme  ← CHANGE THIS IMMEDIATELY

===============================================================================
  NEXT STEPS
===============================================================================

  1. Add DNS record:
     Type: A | Name: authelia | Content: ${ext_ip} | Proxy: 🟠 Orange cloud

  2. In NPM, add proxy host for the AUTHELIA PORTAL:
     Domain: authelia.${DOMAIN} → http://authelia:9091
     Request SSL certificate
     ⚠ Advanced tab: do NOT include authelia-authrequest.conf here
        (the portal must be accessible without 2FA to allow login)

  3. Change default password:
     docker exec authelia authelia crypto hash generate argon2 --password 'YOUR_NEWPASS'
     # Paste the output into $DATA_DIR/config/users.yml

  4. Register your 2FA device:
     Visit https://authelia.${DOMAIN}
     Login with admin / YOUR_NEWPASS
     Click "Methods" → "One-time Password" → "Not registered yet?"
     Scan QR code with Google/Microsoft/Duo Authenticator

  5. Protect other dashboards with 2FA:
     For each proxy host, add to Advanced tab:
       include /snippets/authelia-location.conf;
       location / {
           include /snippets/proxy.conf;
           include /snippets/authelia-authrequest.conf;
           proxy_pass \$forward_scheme://\$server:\$port;
       }
     Full reference: $DATA_DIR/authelia-configure.sh

===============================================================================
  ADDING NEW USERS
===============================================================================

  docker exec authelia authelia crypto hash generate argon2 --password 'USERPASS'
  # Edit $DATA_DIR/config/users.yml and add the new user with the hash
  docker restart authelia

EOF
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

main() {
  preflight_checks
  get_user_domain
  setup_docker_network
  generate_secrets
  generate_config
  create_snippets
  deploy_authelia
  verify_authelia
  configure_npm_integration
  create_helper_script
  print_summary

  # Mark deployment as successful
  DEPLOY_STATUS="success"
}

main "$@"
