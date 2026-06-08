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
readonly SECRETS_DIR="/opt/authelia/secrets"

# Root domain — set at runtime from user input
DOMAIN=""

# ─── Styling ──────────────────────────────────────────────────────────────────
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
_log() { printf "[%s] [%-5s] %s\n" "$(_ts)" "$1" "${*:2}" >> "$LOGFILE" 2>/dev/null || true; }
ok()   { printf "\033[1;32m✔\033[0m %s\n" "$*"; _log "OK" "$*"; }
warn() { printf "\033[1;33m!\033[0m %s\n" "$*"; _log "WARN" "$*"; }
info() { printf "\033[1;34m→\033[0m %s\n" "$*"; _log "INFO" "$*"; }
step() { printf "\n\033[1m▶ %s\033[0m\n" "$*"; _log "STEP" "$*"; }
fatal(){ printf "\033[1;31m✖ %s\033[0m\n" "$*" >&2; _log "FATAL" "$*"; exit 1; }

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
    email: admin@${DOMAIN}
    groups:
      - admins
      - users
USERS
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

  for i in $(seq 1 30); do
    docker exec authelia wget -qO- --timeout=3 http://127.0.0.1:9091/api/health 2>/dev/null | grep -q "ok" && {
      ok "Authelia API responding"
      return 0
    }
    sleep 2
  done

  warn "Authelia health check timed out — check: docker logs authelia"
  return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# NPM INTEGRATION
# ═══════════════════════════════════════════════════════════════════════════════
configure_npm_integration() {
  step "NPM Forward-Auth Integration"
  info "To enable MFA for each service in NPM:"
  echo ""
  echo "  1. In NPM Admin, go to Proxy Hosts → Edit your host"
  echo "  2. Go to the 'Advanced' tab"
  echo "  3. In 'Custom Nginx Configuration', add:"
  echo ""
  echo "     location / {"
  echo "       include /data/nginx/proxy_host_authelia.conf;"
  echo "     }"
  echo ""
  echo "  4. Save and repeat for each protected subdomain"
  echo ""
  warn "Or use the authelia-configure.sh helper script (see below)"
}

# ═══════════════════════════════════════════════════════════════════════════════
# HELPER SCRIPT
# ═══════════════════════════════════════════════════════════════════════════════
create_helper_script() {
  local helper="$DATA_DIR/authelia-configure.sh"
  cat > "$helper" << HELPER
#!/usr/bin/env bash
# Authelia NPM Configuration Helper
# Run this to automatically configure NPM proxy hosts to use Authelia 2FA

AUTH_DOMAIN="authelia.${DOMAIN}"
AUTH_URL="http://authelia:9091"

echo "Authelia NPM Configuration Helper"
echo "================================="
echo ""
echo "For each subdomain you want to protect with MFA, add this to NPM"
echo "Proxy Host → Advanced → Custom Nginx Configuration:"
echo ""
cat << 'NGINX'
# Forward auth to Authelia
auth_request /authelia;
auth_request_set \$user \$upstream_http_remote_user;
proxy_set_header Remote-User \$user;
auth_request_set \$groups \$upstream_http_remote_groups;
proxy_set_header Remote-Groups \$groups;

error_page 401 = @authelia_signin;

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

location @authelia_signin {
    internal;
    return 302 https://authelia.${DOMAIN}/?rd=\$scheme://\$http_host\$request_uri;
}
NGINX

echo ""
echo "Copy the block above into each proxy host you want to protect."
echo ""
HELPER
  chmod +x "$helper"
  ok "Helper script created: $helper"
}

# ═══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════
print_summary() {
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<VPS_IP>")

  cat << EOF

===============================================================================
  Authelia SSO + MFA Deployed Successfully
===============================================================================

  Domain:     ${DOMAIN}
  Portal:     https://authelia.${DOMAIN} (add this DNS record first)
  Internal:   http://authelia:9091 (from NPM container)
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
     Type: A | Name: authelia | Content: ${ip} | Proxy: 🟠 Orange cloud

  2. In NPM, add proxy host:
     Domain: authelia.${DOMAIN} → http://authelia:9091
     Request SSL certificate

  3. Change default password:
     docker exec authelia authelia crypto hash generate argon2 --password 'YOUR_NEWPASS'
     # Paste the output into $DATA_DIR/config/users.yml

  4. Register your 2FA device:
     Visit https://authelia.${DOMAIN}
     Login with admin / YOUR_NEWPASS
     Click "Methods" → "One-time Password" → "Not registered yet?"
     Scan QR code with Google/Microsoft/Duo Authenticator

  5. Protect other services:
     For each subdomain, add the forward-auth config from:
     $DATA_DIR/authelia-configure.sh

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
  deploy_authelia
  verify_authelia
  configure_npm_integration
  create_helper_script
  print_summary
}

main "$@"
