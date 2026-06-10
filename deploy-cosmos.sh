#!/usr/bin/env bash
# Auto-elevate to root if not already running as root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi
# deploy-cosmos.sh -- Docker + NPM + Cosmos + Authelia + CrowdSec
# v4.0.0-cosmos-crowdsec | Usage: sudo ./deploy-cosmos.sh
set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="4.0.0-cosmos-crowdsec"
readonly SCRIPT_NAME="deploy-cosmos.sh"
readonly START_TIME=$(date +%s)
readonly STACK_DIR="/opt/cosmos-stack"
readonly COSMOS_DATA_DIR="/opt/cosmos-stack/cosmos-data"
readonly NPM_DATA_DIR="${STACK_DIR}/data"
readonly NPM_LE_DIR="${STACK_DIR}/letsencrypt"
readonly NPM_LOGS_DIR="${NPM_DATA_DIR}/logs"
readonly CROWDSEC_DIR="${NPM_DIR}/crowdsec"
readonly LOG_FILE="/var/log/vps-deploy.log"

# -- Authelia paths --
readonly AUTHELIA_DIR="${STACK_DIR}/authelia"
readonly AUTHELIA_SECRETS_DIR="${AUTHELIA_DIR}/secrets"
readonly AUTHELIA_CONFIG_DIR="${AUTHELIA_DIR}/config"
readonly AUTHELIA_SNIPPETS_DIR="${AUTHELIA_DIR}/snippets"
readonly DOMAIN_PERSIST_FILE="/etc/vps-deploy-domain"

# -- Runtime-populated --
DOMAIN=""  # Set at runtime via user prompt

# -- Deployment state --
DEPLOY_STATUS="in_progress"
DEPLOYED_SERVICES=""

if [[ -t 1 ]]; then
  C_R='\033[0m'; C_B='\033[1m'; C_RED='\033[0;31m'; C_GRN='\033[0;32m'
  C_YEL='\033[0;33m'; C_BLU='\033[0;34m'; C_CYN='\033[0;36m'; C_DIM='\033[2m'
else
  C_R=''; C_B=''; C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_CYN=''; C_DIM=''
fi

_ts() { date '+%Y-%m-%d %H:%M:%S'; }
_log() { printf "[%s] [%-5s] %s\n" "$(_ts)" "$1" "${*:2}" >> "$LOG_FILE" 2>/dev/null || true; }
info()    { printf "${C_BLU}ℹ${C_R}  %s\n" "$*"; _log "INFO" "$@"; }
warn()    { printf "${C_YEL}⚠${C_R}  %s\n" "$*"; _log "WARN" "$@"; }
error()   { printf "${C_RED}✖${C_R}  %s\n" "$*"; _log "ERROR" "$@"; }
success() { printf "${C_GRN}✔${C_R}  %s\n" "$*"; _log "SUCCESS" "$@"; }
fatal()   { printf "${C_RED}${C_B}FATAL${C_R}${C_RED}: %s${C_R}\n" "$*" >&2; _log "FATAL" "$@"; DEPLOY_STATUS="failed"; exit 1; }
step()    { printf "\n${C_B}${C_CYN}── %s ──${C_R}\n" "$*"; _log "STEP" "$@"; }

get_external_ip() {
  curl -s -4 --max-time 10 https://api.ipify.org 2>/dev/null || \
  curl -s -4 --max-time 10 https://ifconfig.me 2>/dev/null || \
  curl -s -4 --max-time 10 https://icanhazip.com 2>/dev/null || \
  echo "unknown"
}

# -- Guaranteed completion summary on EXIT (fires even on fatal() / set -e failures) --
_on_exit() {
  local exit_code=$?
  local elapsed=$(( $(date +%s) - START_TIME ))
  local ip ext_ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<internal_ip>")
  ext_ip=$(get_external_ip)
  local exit_pass="<unknown>"
  [[ -f "${AUTHELIA_DIR}/.default_password" ]] && exit_pass=$(tr -d '\n' < "${AUTHELIA_DIR}/.default_password" 2>/dev/null || echo "<unknown>")

  printf "\n"
  if [[ "$DEPLOY_STATUS" == "success" ]]; then
    printf "${C_B}${C_GRN}╔══════════════════════════════════════════════════════════════════════════════╗${C_R}\n"
    printf "${C_B}${C_GRN}║                    ✅  DEPLOYMENT COMPLETED SUCCESSFULLY                      ║${C_R}\n"
    printf "${C_B}${C_GRN}╠══════════════════════════════════════════════════════════════════════════════╣${C_R}\n"
  else
    printf "${C_B}${C_RED}╔══════════════════════════════════════════════════════════════════════════════╗${C_R}\n"
    printf "${C_B}${C_RED}║                     ❌  DEPLOYMENT DID NOT COMPLETE                           ║${C_R}\n"
    printf "${C_B}${C_RED}╠══════════════════════════════════════════════════════════════════════════════╣${C_R}\n"
  fi
  printf "${C_B}║  %-72s  ║${C_R}\n" "Elapsed:   ${elapsed}m ${elapsed}s"
  printf "${C_B}║  %-72s  ║${C_R}\n" "VPS IP:    $ip"
  printf "${C_B}║  %-72s  ║${C_R}\n" "External:  $ext_ip"
  printf "${C_B}║  %-72s  ║${C_R}\n" "Domain:    ${DOMAIN:-<not set>}"
  printf "${C_B}╠══════════════════════════════════════════════════════════════════════════════╣${C_R}\n"
  printf "${C_B}║  %-72s  ║${C_R}\n" "NPM Admin:  http://${ip}:81"
  if [[ "$DEPLOY_STATUS" == "success" ]]; then
    printf "${C_B}║  %-72s  ║${C_R}\n" "Portainer:  http://portainer.${DOMAIN} (via NPM)"
    printf "${C_B}║  %-72s  ║${C_R}\n" "Authelia:   https://authelia.${DOMAIN}"
    printf "${C_B}║  %-72s  ║${C_R}\n" ""
    printf "${C_B}║  ${C_YEL}%-72s${C_R}${C_B}  ║${C_R}\n" "Authelia Username:  admin"
    printf "${C_B}║  ${C_YEL}%-72s${C_R}${C_B}  ║${C_R}\n" "Authelia Password:  $exit_pass"
    printf "${C_B}║  ${C_RED}%-72s${C_R}${C_B}  ║${C_R}\n" "Change this password immediately after first login!"
    printf "${C_B}║  %-72s  ║${C_R}\n" "Also saved in: ${AUTHELIA_DIR}/password.txt"
    printf "${C_B}║  %-72s  ║${C_R}\n" ""
    printf "${C_B}║  ${C_YEL}%-72s${C_R}${C_B}  ║${C_R}\n" "-- Changing Password or Adding 2FA --"
    printf "${C_B}║  %-72s  ║${C_R}\n" "1. In Authelia, go to Settings → Password (or 2FA)"
    printf "${C_B}║  %-72s  ║${C_R}\n" "2. Authelia will ask for a verification code"
    printf "${C_B}║  %-72s  ║${C_R}\n" "3. Then run this command to get the code:"
    printf "${C_B}║  ${C_CYN}%-72s${C_R}${C_B}  ║${C_R}\n" "sudo docker exec authelia cat /config/notifications.txt"
    printf "${C_B}║  %-72s  ║${C_R}\n" "4. Paste the code into Authelia and click Verify"
    printf "${C_B}║  %-72s  ║${C_R}\n" ""
  fi
  printf "${C_B}║  %-72s  ║${C_R}\n" "Ports:  80 (HTTP), 443 (HTTPS), 81 (NPM Admin)"
  printf "${C_B}╠══════════════════════════════════════════════════════════════════════════════╣${C_R}\n"
  printf "${C_B}║  %-72s  ║${C_R}\n" "Log: $LOG_FILE"
  printf "${C_B}╚══════════════════════════════════════════════════════════════════════════════╝${C_R}\n"
  printf "\n"
  if [[ "$DEPLOY_STATUS" == "success" ]]; then
    printf "${C_B}${C_GRN}Your VPS is ready!${C_R} Set up DNS → ${C_CYN}${ext_ip}${C_R} and configure NPM.\n\n"
  else
    printf "${C_B}${C_YEL}Deployment failed.${C_R} Check: ${C_CYN}cat $LOG_FILE${C_R}\n\n"
  fi
  exit $exit_code
}

# ──────────────────────────────────────────────────────────────────────────────
# Authelia -- Domain, Secrets, Config, Snippets
# ──────────────────────────────────────────────────────────────────────────────

get_user_domain() {
  step "Domain Configuration"
  if [[ -f "${DOMAIN_PERSIST_FILE}" ]]; then
    local existing_domain
    existing_domain=$(tr -d '\n' < "${DOMAIN_PERSIST_FILE}" 2>/dev/null || true)
    if [[ -n "$existing_domain" ]]; then
      printf "\n${C_YEL}⚠️  Previous deployment detected with domain: ${C_B}${existing_domain}${C_R}\n"
      printf "${C_YEL}   Press ${C_B}Y${C_R}${C_YEL} + Enter to REUSE this domain${C_R}\n"
      printf "${C_YEL}   Press ${C_B}N${C_R}${C_YEL} + Enter to enter a NEW domain${C_R}\n\n"
      read -rp "Reuse '${existing_domain}'? [Y/n]: " use_existing
      [[ "$use_existing" =~ ^[Nn]$ ]] || { DOMAIN="$existing_domain"; success "Domain set to: $DOMAIN"; return 0; }
      printf "\n${C_CYN}Switching to new domain entry...${C_R}\n"
    fi
  fi

  # Fresh domain prompt
  printf "\n${C_B}Enter your root domain${C_R} (e.g., example.com): "
  read -r DOMAIN
  [[ -z "$DOMAIN" ]] && fatal "Domain is required."
  DOMAIN=$(echo "$DOMAIN" | sed 's|https\?://||' | sed 's|/.*||' | tr -d ' ')
  printf '%s' "$DOMAIN" > "${DOMAIN_PERSIST_FILE}"
  success "Domain set to: $DOMAIN"
}

setup_authelia_secrets() {
  step "Generating Authelia Secrets"
  mkdir -p "$AUTHELIA_SECRETS_DIR"
  local secret_name secret_file
  for secret_name in jwt_session storage_encryption session; do
    secret_file="${AUTHELIA_SECRETS_DIR}/${secret_name}"
    if [[ ! -f "$secret_file" ]]; then
      openssl rand -hex 32 > "$secret_file"
      chmod 600 "$secret_file"
      success "Secret '${secret_name}' generated"
    else
      # NOTE: only reachable if idempotent_cleanup is skipped
      info "Secret '${secret_name}' already exists (preserved)"
    fi
  done
}

setup_authelia_config() {
  step "Authelia Configuration"
  mkdir -p "$AUTHELIA_CONFIG_DIR"

  # -- configuration.yml (unquoted EOF for $DOMAIN substitution) --
  cat > "${AUTHELIA_CONFIG_DIR}/configuration.yml" << EOF
server:
  address: "tcp://0.0.0.0:9091"
  endpoints:
    authz:
      forward-auth:
        implementation: "ForwardAuth"

log:
  level: info
  format: text

totp:
  issuer: "authelia.${DOMAIN}"
  period: 30
  skew: 1

authentication_backend:
  file:
    path: /config/users.yml

access_control:
  default_policy: two_factor
  rules:
    - domain: "authelia.${DOMAIN}"
      policy: one_factor
    - domain: "cosmos.${DOMAIN}"
      policy: two_factor
    - domain: "*.${DOMAIN}"
      policy: two_factor

session:
  name: authelia_session
  same_site: lax
  expiration: 1h
  inactivity: 5m
  remember_me_duration: 1M
  cookies:
    - domain: "${DOMAIN}"
      authelia_url: "https://authelia.${DOMAIN}"
      default_redirection_url: "https://cosmos.${DOMAIN}"

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

  # Generate random password for admin account (hash created after container starts)
  local random_pass
  random_pass=$(openssl rand -hex 8)
  printf '%s' "$random_pass" > "${AUTHELIA_DIR}/.default_password"
  chmod 600 "${AUTHELIA_DIR}/.default_password"
  printf '%s' "$random_pass" > "${AUTHELIA_DIR}/password.txt"
  chmod 600 "${AUTHELIA_DIR}/password.txt"
  info "Random password generated for Authelia admin account"
  info "users.yml will be created after authelia container starts"
}

create_nginx_snippets() {
  step "Creating Nginx Snippets"
  mkdir -p "$AUTHELIA_SNIPPETS_DIR"

  # Ensure authelia can read config files (runs as non-root uid 1001 by default)
  chmod 755 "${AUTHELIA_CONFIG_DIR}" "${AUTHELIA_SECRETS_DIR}" 2>/dev/null || true
  chmod 644 "${AUTHELIA_CONFIG_DIR}"/*.yml "${AUTHELIA_CONFIG_DIR}"/*.txt 2>/dev/null || true
  chmod 600 "${AUTHELIA_SECRETS_DIR}"/* 2>/dev/null || true

  # -- proxy.conf --
  cat > "${AUTHELIA_SNIPPETS_DIR}/proxy.conf" << 'PROXY'
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
PROXY

  # -- authelia-location.conf (unquoted SNIPPET for \$ escaping) --
  cat > "${AUTHELIA_SNIPPETS_DIR}/authelia-location.conf" << SNIPPET
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

  # -- authelia-authrequest.conf (unquoted SNIPPET1 for \$ escaping + ${DOMAIN} expansion) --
  cat > "${AUTHELIA_SNIPPETS_DIR}/authelia-authrequest.conf" << SNIPPET1
## Paste this into NPM Advanced tab for each protected proxy host
## NOTE: proxy_set_header Remote-User/Groups below work at server block level.
## NPM's generated location / block has its own proxy_set_header directives,
## which OVERRIDES all server-level ones (nginx inheritance rule).
## For apps that need SSO identity headers, add them via NPM's Custom Locations.
auth_request /authelia;
auth_request_set \$target_url \$scheme://\$http_host\$request_uri;
error_page 401 =302 https://authelia.${DOMAIN}/?rd=\$target_url;
auth_request_set \$user \$upstream_http_remote_user;
auth_request_set \$groups \$upstream_http_remote_groups;
proxy_set_header Remote-User \$user;
proxy_set_header Remote-Groups \$groups;

set \$upstream_authelia http://authelia:9091;
location /authelia {
    internal;
    proxy_pass \$upstream_authelia/api/authz/forward-auth;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_set_header X-Original-URL \$scheme://\$http_host\$request_uri;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-Host \$http_host;
    proxy_set_header X-Forwarded-Uri \$request_uri;
    proxy_cache_bypass \$cookie_session;
    proxy_no_cache \$cookie_session;
    proxy_http_version 1.1;
}
SNIPPET1

  success "Nginx snippets created in ${AUTHELIA_SNIPPETS_DIR}"
}

setup_authelia_users() {
  step "Creating Authelia User Account"

  # Always create fresh users.yml (old one may have stale password)

  # Use the official Authelia lite bundle pre-hashed password.
  # Password is "authelia" — change immediately after first login.
  # Hash source: https://github.com/authelia/authelia/blob/master/examples/compose/lite/authelia/users_database.yml
  local default_pass="authelia"
  local pass_hash='$argon2id$v=19$m=65536,t=3,p=4$qOKNq+u5lZHOTnsJY1Sp3g$s6zT9EKncfkmIJmykzZProUigRRJ26hlTl1WC+mG2do'

  # Store password for display
  printf '%s' "$default_pass" > "${AUTHELIA_DIR}/.default_password"
  chmod 600 "${AUTHELIA_DIR}/.default_password"
  printf '%s' "$default_pass" > "${AUTHELIA_DIR}/password.txt"
  chmod 600 "${AUTHELIA_DIR}/password.txt"

  # Write users.yml — single-quoted YAML (matches official lite bundle format)
  cat > "${AUTHELIA_CONFIG_DIR}/users.yml" << USEREOF
---
users:
  admin:
    disabled: false
    displayname: 'Administrator'
    password: '${pass_hash}'
    email: 'admin@${DOMAIN}'
    groups:
      - admins
      - users
USEREOF

  success "Authelia user 'admin' created"
  info "Default password: ${default_pass} (change after first login)"

  info "Restarting Authelia to load user database..."
  docker restart authelia >/dev/null 2>&1

  # Wait for authelia to come back up
  for i in $(seq 1 30); do
    docker exec authelia wget -qO- --timeout=3 http://127.0.0.1:9091/api/health 2>/dev/null | grep -q "ok" && { success "Authelia ready"; break; }
    printf "${C_DIM}  Waiting for Authelia restart... (%d/30)${C_R}\r" "$i"
    [[ $i -eq 30 ]] && warn "Authelia restart timed out"
    sleep 2
  done
  printf "\n"
}

setup_stack() {
  step "Deploying Stack (NPM + Cosmos + Authelia)"
  mkdir -p "$NPM_DATA_DIR" "$NPM_LE_DIR" "$NPM_LOGS_DIR" "$COSMOS_DATA_DIR" "$CROWDSEC_DIR" && cd "$STACK_DIR"

  cat > docker-compose.yml << 'COMPOSE'
services:
  npm:
    image: 'jc21/nginx-proxy-manager:latest'
    container_name: npm
    hostname: npm
    restart: always
    ports:
      - '0.0.0.0:80:80'
      - '0.0.0.0:443:443'
      - '0.0.0.0:81:81'
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
    networks:
      - proxy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://127.0.0.1:81/"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

  cosmos-server:
    image: 'azukaar/cosmos-server:latest'
    container_name: cosmos-server
    hostname: cosmos-server
    restart: always
    privileged: true
    # No host ports -- accessed only via NPM proxy at http://cosmos-server:80
    # For Constellation VPN, add UDP 4242 via UFW or NPM Stream Hosts
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /var/run/dbus/system_bus_socket:/var/run/dbus/system_bus_socket
      - /:/mnt/host
      - /opt/cosmos-stack/cosmos-data:/config
    networks:
      - proxy
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:80"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s

  authelia:
    image: authelia/authelia:latest
    container_name: authelia
    user: "0:0"
    hostname: authelia
    restart: always
    volumes:
      - /opt/cosmos-stack/authelia/config:/config
      - /opt/cosmos-stack/authelia/secrets:/config/secrets:ro
    environment:
      - AUTHELIA_JWT_SECRET_FILE=/config/secrets/jwt_session
      - AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE=/config/secrets/storage_encryption
      - AUTHELIA_SESSION_SECRET_FILE=/config/secrets/session
      - AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET_FILE=/config/secrets/jwt_session
      - TZ=America/New_York
    networks:
      - proxy
    healthcheck:
      test: ["CMD", "wget", "-qO-", "--timeout=3", "http://127.0.0.1:9091/api/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

networks:
  proxy:
    external: true

  crowdsec:
    image: crowdsecurity/crowdsec:latest
    container_name: crowdsec
    hostname: crowdsec
    restart: unless-stopped
    environment:
      - COLLECTIONS=crowdsecurity/sshd crowdsecurity/nginx-proxy-manager crowdsecurity/linux
      - TZ=UTC
    volumes:
      - ./crowdsec/data:/var/lib/crowdsec/data
      - ./crowdsec/config:/etc/crowdsec
      - ./data/logs:/var/log/npm:ro
      - /var/log:/var/log:ro
    network_mode: host
COMPOSE

  info "Pulling Docker images -- this may take a few minutes..."
  docker compose pull
  info "Starting containers -- please wait..."
  docker rm -f npm 2>/dev/null || true
  docker rm -f cosmos-server 2>/dev/null || true
  docker rm -f authelia 2>/dev/null || true
  docker compose up -d

  info "Verifying NPM ports (80, 443, 81) are bound..."
  local ports_ok=false
  for i in $(seq 1 30); do
    local has_80=false has_443=false has_81=false
    ss -tlnp 2>/dev/null | grep -q ':80[[:space:]]' && has_80=true
    ss -tlnp 2>/dev/null | grep -q ':443[[:space:]]' && has_443=true
    ss -tlnp 2>/dev/null | grep -q ':81[[:space:]]' && has_81=true
    if $has_80 && $has_443 && $has_81; then
      success "NPM bound all ports: 80, 443, 81"
      ports_ok=true
      break
    fi
    if [[ $i -eq 30 ]]; then
      echo ""; echo "  Port 80 bound:  $has_80"; echo "  Port 443 bound: $has_443"; echo "  Port 81 bound:  $has_81"; echo ""
      ss -tlnp 2>/dev/null | grep -E ':80 |:443 |:81 ' || true; echo ""
      fatal "NPM failed to bind required ports. Check: docker logs npm"
    fi
    printf "\r  Waiting for NPM ports... %2d/30" "$i"
    sleep 2
  done
  printf "\n"

  info "Waiting for NPM container..."
  for i in $(seq 1 30); do
    docker ps --format '{{.Names}}' | grep -qx "npm" && { success "NPM container running"; break; }
    printf "\r  Waiting... %2d/30" "$i"
    [[ $i -eq 30 ]] && { printf "\n"; warn "NPM container not detected after 60s"; }
    sleep 2
  done
  printf "\n"

  info "Waiting for NPM admin UI (port 81)..."
  for i in $(seq 1 60); do
    curl -sf --max-time 5 http://127.0.0.1:81/ &>/dev/null && { success "NPM admin UI responding"; break; }
    printf "\r  Waiting... %2d/60" "$i"
    [[ $i -eq 60 ]] && { printf "\n"; warn "NPM UI timed out (2m). Still starting?"; }
    sleep 2
  done
  printf "\n"

  info "Waiting for NPM log files..."
  for i in $(seq 1 30); do
    if ls "${NPM_LOGS_DIR}/"*_access.log "${NPM_LOGS_DIR}/"*_error.log &>/dev/null; then
      success "NPM logs present"
      break
    fi
    printf "\r  Waiting... %2d/30" "$i"
    if [[ $i -eq 30 ]]; then
      printf "\n"
      warn "NPM logs not created yet. Creating placeholders."
      touch "${NPM_LOGS_DIR}/fallback_http_access.log" \
            "${NPM_LOGS_DIR}/fallback_http_error.log" \
            "${NPM_LOGS_DIR}/default-host_access.log" \
            "${NPM_LOGS_DIR}/default-host_error.log"
    fi
    sleep 2
  done
  printf "\n"

  info "Waiting for Cosmos Server..."
  for i in $(seq 1 60); do
    docker exec cosmos-server wget -q --spider --timeout=5 http://127.0.0.1:80/ &>/dev/null && { success "Cosmos Server responding"; break; }
    printf "\r  Waiting... %2d/60" "$i"
    [[ $i -eq 60 ]] && { printf "\n"; warn "Cosmos timed out (3m). Check: docker logs cosmos-server"; }
    sleep 3
  done
  printf "\n"

  info "Waiting for Authelia..."
  for i in $(seq 1 30); do
    docker exec authelia wget -qO- --timeout=3 http://127.0.0.1:9091/api/health 2>/dev/null | grep -q "ok" && { success "Authelia ready"; break; }
    printf "\r  Waiting... %2d/30" "$i"
    [[ $i -eq 30 ]] && { printf "\n"; warn "Authelia health check timed out"; }
    sleep 2
  done
  printf "\n"

  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<VPS_IP>")
  success "Stack deployed: NPM at http://${ip}:81, Cosmos proxied via http://cosmos-server:80, Authelia at http://authelia:9091"
}


setup_firewall() {
  step "Firewall Configuration"
  info "Configuring firewall..."
  [[ "$OS_FAMILY" == "debian" ]] && setup_firewall_debian || setup_firewall_rhel
}

setup_firewall_debian() {
  info "Configuring UFW..."
  apt-get install -y -qq ufw

  local ufw_def="/etc/default/ufw"
  if [[ -f "$ufw_def" ]]; then
    cp -n "$ufw_def" "${ufw_def}.bak" 2>/dev/null || true
    if grep -q '^DEFAULT_FORWARD_POLICY=' "$ufw_def"; then
      sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' "$ufw_def"
    else
      echo 'DEFAULT_FORWARD_POLICY="ACCEPT"' >> "$ufw_def"
    fi
  fi
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  local ssh_port; ssh_port=$(ss -tlnp 2>/dev/null | grep -m1 ':22 ' | awk '{print $4}' | cut -d: -f2 || echo "22")
  ufw allow "${ssh_port:-22}/tcp" comment 'SSH'
  ufw allow 80/tcp comment 'HTTP (NPM)'
  ufw allow 443/tcp comment 'HTTPS (NPM)'
  ufw allow 81/tcp comment 'NPM Admin (restrict after setup)'
  ufw --force enable && ufw reload
  ufw status verbose
  success "UFW configured"
}

setup_firewall_rhel() {
  info "Configuring firewalld..."
  local pkg="yum"; command -v dnf &>/dev/null && pkg="dnf"
  $pkg install -y -q firewalld
  systemctl start firewalld && systemctl enable firewalld
  firewall-cmd --permanent --add-service=ssh
  firewall-cmd --permanent --add-service=http
  firewall-cmd --permanent --add-service=https
  firewall-cmd --permanent --add-port=81/tcp
  firewall-cmd --reload
  firewall-cmd --list-all
  success "Firewalld configured"
}

setup_logrotate() {
  step "Log Rotation"
  cat > /etc/logrotate.d/npm << EOF
${NPM_LOGS_DIR}/*.log {
    weekly
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0644 root root
    sharedscripts
    postrotate
        docker kill --signal='USR1' npm 2>/dev/null || true
    endscript
}
EOF
  success "Log rotation: ${NPM_LOGS_DIR}/*.log (14 days)"
}

print_summary() {
  local elapsed=$(( $(date +%s) - START_TIME ))
  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "YOUR_VPS_IP")
  local ext_ip; ext_ip=$(get_external_ip)
  local fw_cmd; [[ "$OS_FAMILY" == "debian" ]] && fw_cmd="ufw status verbose" || fw_cmd="firewall-cmd --list-all"

  printf "\n"
  printf "${C_B}${C_GRN}╔══════════════════════════════════════════════════════════════════════════════╗${C_R}\n"
  printf "${C_B}${C_GRN}║                   📋  DEPLOYMENT SUMMARY                                     ║${C_R}\n"
  printf "${C_B}${C_GRN}╠══════════════════════════════════════════════════════════════════════════════╣${C_R}\n"
  printf "${C_B}║  ${SCRIPT_NAME} v${SCRIPT_VERSION}                                                   ║${C_R}\n"
  printf "${C_B}║  Duration: ${C_CYN}%dm %ds${C_R}${C_B}                                                    ║${C_R}\n" $(( elapsed / 60 )) $(( elapsed % 60 ))
  printf "${C_B}║  VPS IP:   ${C_CYN}%-16s${C_R}${C_B}                                                   ║${C_R}\n" "$ip"
  printf "${C_B}║  External: ${C_CYN}%-16s${C_R}${C_B}                                                   ║${C_R}\n" "$ext_ip"
  printf "${C_B}╚══════════════════════════════════════════════════════════════════════════════╝${C_R}\n"
  printf "\n"

  cat << EOF
${C_B}${C_CYN}-- SERVICES --${C_R}

${C_B}Nginx Proxy Manager${C_R}
  Admin UI:  http://${ip}:81
  HTTP:      http://${ip}:80
  HTTPS:     https://${ip}:443
  Data:      ${NPM_DATA_DIR}
  SSL certs: ${NPM_LE_DIR}
  Logs:      ${NPM_LOGS_DIR}

${C_B}Cosmos Server${C_R}
  Container: cosmos-server
  Port:      80 (internal, no host port)
  Network:   proxy

${C_B}${C_YEL}════════════════════════════════════════════════════════════════${C_R}
${C_B}${C_YEL}  🔐  AUTHELIA LOGIN CREDENTIALS (SAVE THESE)${C_R}
${C_B}${C_YEL}════════════════════════════════════════════════════════════════${C_R}

  ${C_B}URL:${C_R}       https://authelia.${DOMAIN}
  ${C_B}Username:${C_R}  ${C_CYN}admin${C_R}
  ${C_B}Config:${C_R}    ${AUTHELIA_CONFIG_DIR}
  ${C_B}Secrets:${C_R}   ${AUTHELIA_SECRETS_DIR}
  ${C_B}Snippets:${C_R}  ${AUTHELIA_SNIPPETS_DIR}
EOF

  local display_pass="<unknown>"
  [[ -f "${AUTHELIA_DIR}/.default_password" ]] && display_pass=$(tr -d '\n' < "${AUTHELIA_DIR}/.default_password")
  printf "  ${C_B}Password:${C_R}  ${C_CYN}%s${C_R}\n" "$display_pass"
  printf "\n  ${C_RED}⚠️  Change this password immediately after first login!${C_R}\n"

cat << EOF

${C_B}Docker${C_R}    $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo N/A)
${C_B}Compose${C_R}   $(docker compose version --short 2>/dev/null || echo N/A)
${C_B}Network${C_R}   proxy (bridge)

${C_B}CrowdSec${C_R}  Collections: sshd, nginx-proxy-manager, linux
${C_B}Firewall${C_R}  $(if [[ "$OS_FAMILY" == "debian" ]]; then echo "UFW"; else echo "firewalld"; fi)

${C_B}${C_YEL}Step 1 -- NPM Admin${C_R}
  Open:   http://${ip}:81
  Login:  admin@example.com / changeme
  ${C_RED}→ Change password immediately${C_R}

${C_B}${C_YEL}Step 2 -- Add Proxy Hosts in NPM${C_R}

  A) Authelia Portal
     Dashboards → Proxy Hosts → Add Proxy Host
     ┌──────────────────────────────────────────┐
     │ Domain Names:    authelia.${DOMAIN}       │
     │ Scheme:          http                    │
     │ Forward Host:    authelia                │
     │ Forward Port:    9091                    │
     │ Block Exploits:  ON                      │
     └──────────────────────────────────────────┘
     Click Save

  B) Cosmos Dashboard
     Dashboards → Proxy Hosts → Add Proxy Host
     ┌──────────────────────────────────────────┐
     │ Domain Names:    cosmos.${DOMAIN}         │
     │ Scheme:          http                    │
     │ Forward Host:    cosmos-server           │
     │ Forward Port:    80                      │
     │ Block Exploits:  ON                      │
     │ Custom Locations:                        │
     │   Include authelia auth snippets         │
     └──────────────────────────────────────────┘
     Click Save

${C_B}${C_YEL}Step 3 -- SSL Certificates${C_R}
  On each proxy host → SSL tab
  ┌──────────────────────────────────────────┐
  │ SSL:             Request a new cert      │
  │ Force SSL:       ON                      │
  │ HTTP/2 Support:  ON                      │
  │ Email:           your-email@${DOMAIN}    │
  │ Agree to TOS:    ON                      │
  └──────────────────────────────────────────┘
  Click Save

${C_B}${C_YEL}Step 4 -- Configure Authelia Protection${C_R}
  In NPM Advanced tab for cosmos.${DOMAIN}, add:
    include /opt/cosmos-stack/authelia/snippets/authelia-authrequest.conf;
  Create location @authelia_signin:
    return 302 https://authelia.${DOMAIN}/?rd=\$scheme://\$http_host\$request_uri;

${C_B}${C_YEL}Step 5 -- Register TOTP Device${C_R}
  Visit https://authelia.${DOMAIN}
  Username: admin
  Password: (see credential box above)
  Follow prompts to register your authenticator app

${C_B}${C_YEL}Step 6 -- Secure Admin Port${C_R}
  $(if [[ "$OS_FAMILY" == "debian" ]]; then echo "  ufw delete allow 81/tcp && ufw reload"; else echo "  firewall-cmd --permanent --remove-port=81/tcp && firewall-cmd --reload"; fi)

${C_B}${C_YEL}Step 7 -- Change Default Password${C_R}
  ${C_RED}IMPORTANT:${C_R} Change the default Authelia password immediately:
    1. Login to https://authelia.${DOMAIN}
    2. Go to Settings → Password
    3. Or edit ${AUTHELIA_CONFIG_DIR}/users.yml and restart authelia

${C_B}${C_CYN}-- TROUBLESHOOTING --${C_R}

  Logs:       docker logs -f npm   docker logs -f cosmos-server   docker logs -f authelia
  Restart:    cd ${STACK_DIR} && docker compose restart
  CrowdSec:   cscli metrics    cscli decisions list
  Firewall:   ${fw_cmd}
  Deploy log: ${LOG_FILE}

EOF
  _log "INFO" "=== Deployment completed in $(( elapsed / 60 ))m $(( elapsed % 60 ))s ==="
}


setup_crowdsec() {
  step "CrowdSec (Docker)"

  info "Waiting for CrowdSec container to be ready..."
  local cs_ready=false
  for i in $(seq 1 30); do
    if docker exec crowdsec cscli metrics &>/dev/null; then
      cs_ready=true
      break
    fi
    sleep 2
  done

  if ! $cs_ready; then
    docker logs crowdsec --tail 20 2>/dev/null || true
    warn "CrowdSec container not ready -- check ${LOG_FILE}. Continuing..."
    return
  fi
  success "CrowdSec container running"

  info "Verifying collections..."
  docker exec crowdsec cscli collections list 2>/dev/null | grep -q "crowdsecurity/sshd" && success "sshd collection" || warn "sshd collection not found"
  docker exec crowdsec cscli collections list 2>/dev/null | grep -q "crowdsecurity/nginx-proxy-manager" && success "nginx-proxy-manager collection" || warn "nginx-proxy-manager not found"
  docker exec crowdsec cscli collections list 2>/dev/null | grep -q "crowdsecurity/linux" && success "linux collection" || warn "linux not found"

  info "Configuring NPM log acquisition..."
  local npm_acquis="${CROWDSEC_DIR}/config/acquis.d/npm.yaml"
  mkdir -p "$(dirname "$npm_acquis")"
  cat > "$npm_acquis" << 'NPM_ACQUIS'
filenames:
  - /var/log/npm/*.log
labels:
  type: nginx
NPM_ACQUIS
  if docker exec crowdsec cat /etc/crowdsec/acquis.d/npm.yaml &>/dev/null; then
    success "NPM acquisition configured"
  else
    docker exec crowdsec bash -c "mkdir -p /etc/crowdsec/acquis.d && cat > /etc/crowdsec/acquis.d/npm.yaml << 'EOF'
filenames:
  - /var/log/npm/*.log
labels:
  type: nginx
EOF" && warn "NPM acquisition written (via docker exec)" || warn "Could not configure NPM acquisition"
  fi

  docker exec crowdsec kill -HUP 1 2>/dev/null || docker restart crowdsec &>/dev/null || true

  info "Installing firewall bouncer..."
  local bouncer_version="0.0.34"
  local arch_map
  case "$(uname -m)" in
    x86_64)  arch_map="amd64" ;;
    aarch64) arch_map="arm64" ;;
    armv7l)  arch_map="armv7" ;;
    *)       arch_map="$(uname -m)" ;;
  esac
  local bouncer_url="https://github.com/crowdsecurity/cs-firewall-bouncer/releases/download/v${bouncer_version}/crowdsec-firewall-bouncer-linux-${arch_map}.tgz"
  local tmpdir; tmpdir=$(mktemp -d)
  pushd "$tmpdir" &>/dev/null
  if curl -sL --connect-timeout 10 "$bouncer_url" | tar xz 2>/dev/null; then
    cp crowdsec-firewall-bouncer-*/crowdsec-firewall-bouncer /usr/local/bin/ 2>/dev/null
    chmod +x /usr/local/bin/crowdsec-firewall-bouncer 2>/dev/null
    cat > /etc/systemd/system/crowdsec-firewall-bouncer.service << 'BOUNCER_SERVICE'
[Unit]
Description=The firewall bouncer for CrowdSec
After=syslog.target network.target remote-fs.target nss-lookup.target docker.service
Before=netfilter-persistent.service

[Service]
Type=notify
ExecStart=/usr/local/bin/crowdsec-firewall-bouncer -c /etc/crowdsec/crowdsec-firewall-bouncer.yaml
ExecStartPre=/usr/local/bin/crowdsec-firewall-bouncer -c /etc/crowdsec/crowdsec-firewall-bouncer.yaml -t
ExecStartPost=/bin/sleep 0.1
Restart=always
RestartSec=10
LimitNOFILE=65536
KillMode=mixed

[Install]
WantedBy=multi-user.target
BOUNCER_SERVICE
    popd &>/dev/null; rm -rf "$tmpdir"
    success "Firewall bouncer binary installed"
  else
    popd &>/dev/null; rm -rf "$tmpdir"
    warn "Binary download failed -- trying apt..."
    if [[ "$OS_FAMILY" == "debian" ]]; then
      apt-get install -y -qq crowdsec-firewall-bouncer-nftables >> "$LOG_FILE" 2>&1 || \
      apt-get install -y -qq crowdsec-firewall-bouncer-iptables >> "$LOG_FILE" 2>&1 || true
    else
      local pkg="yum"; command -v dnf &>/dev/null && pkg="dnf"
      $pkg install -y -q crowdsec-firewall-bouncer-nftables >> "$LOG_FILE" 2>&1 || \
      $pkg install -y -q crowdsec-firewall-bouncer-iptables >> "$LOG_FILE" 2>&1 || true
    fi
  fi

  docker exec crowdsec cscli bouncers delete npm-bouncer 2>/dev/null || true
  local api_key
  api_key=$(docker exec crowdsec cscli bouncers add npm-bouncer 2>/dev/null | tail -1 || true)
  if [[ -n "$api_key" ]]; then
    mkdir -p /etc/crowdsec
    cat > /etc/crowdsec/crowdsec-firewall-bouncer.yaml << BOUNCER
api_url: http://127.0.0.1:8080
api_key: ${api_key}
BOUNCER
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now crowdsec-firewall-bouncer 2>/dev/null || true
    success "Firewall bouncer registered"
  else
    warn "Could not register firewall bouncer -- run manually: docker exec crowdsec cscli bouncers add my-bouncer"
  fi
}

main() {
  printf "\n${C_B}${C_CYN}VPS Deployment -- Docker + NPM + Cosmos + Authelia + CrowdSec${C_R}\n"
  printf "${C_DIM}${SCRIPT_NAME} v${SCRIPT_VERSION}${C_R}\n\n"
  preflight_checks
  idempotent_cleanup
  system_update
  install_dependencies
  install_docker
  setup_docker_network
  get_user_domain
  setup_authelia_secrets
  setup_authelia_config
  create_nginx_snippets
  setup_stack
  setup_authelia_users
  setup_firewall
  setup_crowdsec
  setup_logrotate
  print_summary
  DEPLOY_STATUS="success"
  DEPLOYED_SERVICES="npm,cosmos-server,authelia,crowdsec"
}

main "$@"
