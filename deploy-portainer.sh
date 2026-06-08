#!/usr/bin/env bash
# Auto-elevate to root if not already running as root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi
# deploy-portainer.sh -- Docker + NPM + Portainer + Authelia + Fail2Ban (v3.0.0-portainer-authelia)
# Idempotent VPS deployment. Usage: sudo ./deploy-portainer.sh
set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="3.0.0-portainer-authelia"
readonly SCRIPT_NAME="deploy-portainer.sh"
readonly START_TIME=$(date +%s)
readonly STACK_DIR="/opt/portainer-stack"
readonly NPM_DATA_DIR="${STACK_DIR}/data"
readonly NPM_LE_DIR="${STACK_DIR}/letsencrypt"
readonly NPM_LOGS_DIR="${NPM_DATA_DIR}/logs"
readonly LOG_FILE="/var/log/vps-deploy.log"

# Authelia paths
readonly AUTHELIA_DIR="${STACK_DIR}/authelia"
readonly AUTHELIA_SECRETS_DIR="${AUTHELIA_DIR}/secrets"
readonly AUTHELIA_CONFIG_DIR="${AUTHELIA_DIR}/config"
readonly AUTHELIA_SNIPPETS_DIR="${AUTHELIA_DIR}/snippets"

# Domain set at runtime via user prompt
DOMAIN=""

# Deployment status tracking for guaranteed completion summary
DEPLOY_STATUS="in_progress"   # in_progress | success | failed
DEPLOYED_SERVICES=""          # Track what was successfully deployed

# Colors (TTY only)
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

# ═══════════════════════════════════════════════════════════════════════════════
# GUARANTEED COMPLETION SUMMARY — runs on exit regardless of success/failure
# ═══════════════════════════════════════════════════════════════════════════════
_on_exit() {
  local exit_code=$?
  local elapsed=$(( $(date +%s) - START_TIME ))
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<VPS_IP>")

  # Only print if we got past preflight (avoid ugly output on very early failure)
  if [[ -n "${DEPLOYED_SERVICES:-}" ]] || [[ "$DEPLOY_STATUS" != "in_progress" ]]; then
    printf "\n"
    if [[ "$DEPLOY_STATUS" == "success" ]]; then
      printf "${C_B}${C_GRN}╔══════════════════════════════════════════════════════════════════════════════╗${C_R}\n"
      printf "${C_B}${C_GRN}║                   ✅  DEPLOYMENT COMPLETED SUCCESSFULLY                      ║${C_R}\n"
      printf "${C_B}${C_GRN}╠══════════════════════════════════════════════════════════════════════════════╣${C_R}\n"
    else
      printf "${C_B}${C_RED}╔══════════════════════════════════════════════════════════════════════════════╗${C_R}\n"
      printf "${C_B}${C_RED}║                     ❌  DEPLOYMENT DID NOT COMPLETE                          ║${C_R}\n"
      printf "${C_B}${C_RED}╠══════════════════════════════════════════════════════════════════════════════╣${C_R}\n"
    fi
    printf "${C_B}║  Elapsed:   ${C_CYN}%dm %ds${C_R}${C_B}                                                          ║${C_R}\n" $(( elapsed / 60 )) $(( elapsed % 60 ))
    printf "${C_B}║  VPS IP:    ${C_CYN}%-16s${C_R}${C_B}                                                   ║${C_R}\n" "$ip"
    printf "${C_B}║  Domain:    ${C_CYN}%-16s${C_R}${C_B}                                                   ║${C_R}\n" "${DOMAIN:-<not set>}"
    printf "${C_B}║  Status:    %-16s${C_B}                                                   ║${C_R}\n" "$(if [[ "$DEPLOY_STATUS" == "success" ]]; then printf "${C_GRN}All systems go"; else printf "${C_RED}Check logs"; fi)"
    printf "${C_B}╠══════════════════════════════════════════════════════════════════════════════╣${C_R}\n"
    printf "${C_B}║  ${C_YEL}NPM Admin${C_R}${C_B}:  http://${C_CYN}%-56s${C_R}${C_B}║${C_R}\n" "${ip}:81"
    if [[ "$DEPLOY_STATUS" == "success" ]]; then
      printf "${C_B}║  ${C_YEL}Portainer${C_R}${C_B}:  http://${C_CYN}%-56s${C_R}${C_B}║${C_R}\n" "portainer.${DOMAIN:-yourdomain.com} (via NPM)"
      printf "${C_B}║  ${C_YEL}Authelia ${C_R}${C_B}:  https://${C_CYN}%-55s${C_R}${C_B}║${C_R}\n" "authelia.${DOMAIN:-yourdomain.com} (via NPM)"
    fi
    printf "${C_B}║  ${C_YEL}Ports    ${C_R}${C_B}:  ${C_CYN}80 (HTTP), 443 (HTTPS), 81 (NPM Admin)          ${C_R}${C_B}║${C_R}\n"
    printf "${C_B}╠══════════════════════════════════════════════════════════════════════════════╣${C_R}\n"
    printf "${C_B}║  Log file: ${C_CYN}%-66s${C_R}${C_B}║${C_R}\n" "$LOG_FILE"
    printf "${C_B}╚══════════════════════════════════════════════════════════════════════════════╝${C_R}\n"
    printf "\n"

    if [[ "$DEPLOY_STATUS" == "success" ]]; then
      printf "${C_B}${C_GRN}Your VPS is ready!${C_R} Set up your DNS records and configure NPM.\n\n"
    else
      printf "${C_B}${C_YEL}The deployment did not finish.${C_R} Common fixes:\n"
      printf "  1. Check the log:   ${C_CYN}cat %s${C_R}\n" "$LOG_FILE"
      printf "  2. Check Docker:    ${C_CYN}docker ps -a${C_R}\n"
      printf "  3. Re-run:          ${C_CYN}sudo %s${C_R}\n" "$SCRIPT_NAME"
      printf "\n"
    fi
  fi
  _log "INFO" "=== Script exited (code $exit_code, status: $DEPLOY_STATUS, elapsed: ${elapsed}s) ===" 2>/dev/null || true
  exit $exit_code
}
trap _on_exit EXIT

preflight_checks() {
  step "Pre-flight Checks"
  if [[ "${EUID:-0}" -ne 0 ]]; then fatal "Run as root (use sudo)."; fi
  success "Running as root"

  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    readonly OS_ID="${ID:-unknown}"
    readonly OS_NAME="${NAME:-Unknown}"
    readonly OS_VERSION_ID="${VERSION_ID:-0}"
    readonly OS_LIKE="${ID_LIKE:-}"
  else
    fatal "/etc/os-release not found."
  fi

  case "$OS_ID" in
    ubuntu|debian|linuxmint|pop|kali) readonly OS_FAMILY="debian" ;;
    centos|rhel|rocky|almalinux|fedora|ol|oraclelinux|amzn) readonly OS_FAMILY="rhel" ;;
    *)
      if [[ "$OS_LIKE" == *"debian"* ]]; then readonly OS_FAMILY="debian"
      elif [[ "$OS_LIKE" == *"rhel"* ]] || [[ "$OS_LIKE" == *"fedora"* ]] || [[ "$OS_LIKE" == *"centos"* ]]; then readonly OS_FAMILY="rhel"
      else fatal "Unsupported: ${OS_NAME} (${OS_ID}). Need Ubuntu 20.04+, Debian 11+, Rocky/Alma 8+, Fedora 35+, Amazon Linux 2023"; fi
      ;;
  esac
  success "OS: ${OS_NAME} ${OS_VERSION_ID} (${OS_FAMILY})"

  if [[ "$OS_FAMILY" == "debian" ]]; then
    local major_ver="${OS_VERSION_ID%%.*}"
    if [[ "$OS_ID" == "ubuntu" && "$major_ver" -lt 20 ]]; then fatal "Ubuntu ${OS_VERSION_ID} too old (min 20.04)."; fi
    if [[ "$OS_ID" == "debian" && "$major_ver" -lt 11 ]]; then fatal "Debian ${OS_VERSION_ID} too old (min 11)."; fi
  fi

  readonly ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) readonly DOCKER_ARCH="amd64" ;;
    aarch64|arm64) readonly DOCKER_ARCH="arm64" ;;
    *) fatal "Unsupported arch: ${ARCH}. Need x86_64 or arm64." ;;
  esac
  success "Arch: ${ARCH} (${DOCKER_ARCH})"

  info "Checking internet..."
  if ! curl -sf --max-time 10 https://download.docker.com/ >/dev/null 2>&1 && \
     ! curl -sf --max-time 10 https://github.com/ >/dev/null 2>&1; then
    fatal "No internet connectivity."
  fi
  success "Internet OK"

  local free_mb; free_mb=$(df -m / | awk 'NR==2 {print $4}')
  if [[ "$free_mb" -lt 2048 ]]; then warn "Low disk: ${free_mb}MB free (recommend >= 2048MB)."
  else success "Disk: $(( free_mb / 1024 ))GB free"; fi

  mkdir -p "$(dirname "$LOG_FILE")"
  _log "INFO" "=== ${SCRIPT_NAME} v${SCRIPT_VERSION} started ==="
  _log "INFO" "OS: ${OS_NAME} ${OS_VERSION_ID}, Family: ${OS_FAMILY}, Arch: ${ARCH}"
}

idempotent_cleanup() {
  step "Cleanup"
  if command -v docker &>/dev/null; then
    info "Removing ALL existing containers and volumes..."
    docker ps -aq 2>/dev/null | xargs -r docker stop &>/dev/null || true
    docker ps -aq 2>/dev/null | xargs -r docker rm -f &>/dev/null || true
    docker volume ls -q 2>/dev/null | xargs -r docker volume rm -f &>/dev/null || true
  fi
  if [[ "$OS_FAMILY" == "debian" ]]; then
    dpkg -l 2>/dev/null | grep -E "docker|containerd|runc" | awk '{print $2}' | xargs -r apt-get remove -y -qq &>/dev/null || true
    apt-get autoremove -y -qq &>/dev/null || true
  else
    yum remove -y -q docker-ce docker-ce-cli containerd.io 2>/dev/null || true
  fi
}

system_update() {
  step "System Update"
  info "Updating packages — this may take a few minutes..."
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  if [[ "$OS_FAMILY" == "debian" ]]; then
    apt-get update -qq && apt-get upgrade -y -qq && apt-get autoremove -y -qq && apt-get autoclean -qq
  else
    if command -v dnf &>/dev/null; then dnf update -y -q && dnf autoremove -y -q 2>/dev/null || true
    else yum update -y -q; fi
  fi
  success "System updated"
}

install_dependencies() {
  step "Dependencies"
  info "Installing required packages..."
  if [[ "$OS_FAMILY" == "debian" ]]; then
    apt-get install -y -qq ca-certificates curl gnupg lsb-release \
      software-properties-common apt-transport-https jq cron logrotate
  else
    local pkg="yum"; command -v dnf &>/dev/null && pkg="dnf"
    $pkg install -y -q ca-certificates curl gnupg2 yum-utils \
      device-mapper-persistent-data lvm2 jq cronie logrotate
  fi
  success "Dependencies installed"
}

install_docker() {
  step "Docker CE"
  if command -v docker &>/dev/null && docker version &>/dev/null; then
    success "Docker already installed: $(docker --version)"; return 0
  fi
  info "Installing Docker CE — this may take a few minutes..."
  if [[ "$OS_FAMILY" == "debian" ]]; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" -o /etc/apt/keyrings/docker.asc 2>/dev/null || \
      curl -fsSL "https://download.docker.com/linux/debian/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    local repo_url
    if [[ "$OS_ID" == "debian" || "$OS_ID" == "ubuntu" ]]; then
      repo_url="https://download.docker.com/linux/${OS_ID}"
    else
      repo_url="https://download.docker.com/linux/ubuntu"
    fi
    echo "deb [arch=${DOCKER_ARCH} signed-by=/etc/apt/keyrings/docker.asc] ${repo_url} $(lsb_release -cs) stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
  else
    local pkg="yum"; command -v dnf &>/dev/null && pkg="dnf"
    if [[ "$OS_ID" == "amzn" || "$OS_ID" == "fedora" ]]; then
      $pkg config-manager --add-repo "https://download.docker.com/linux/fedora/docker-ce.repo" 2>/dev/null || \
        yum-config-manager --add-repo "https://download.docker.com/linux/fedora/docker-ce.repo"
    else
      $pkg config-manager --add-repo "https://download.docker.com/linux/centos/docker-ce.repo" 2>/dev/null || \
        yum-config-manager --add-repo "https://download.docker.com/linux/centos/docker-ce.repo"
    fi
    $pkg install -y -q docker-ce docker-ce-cli containerd.io docker-compose-plugin
  fi
  systemctl start docker && systemctl enable docker
  systemctl is-active --quiet docker || fatal "Docker daemon failed. Check: journalctl -u docker -n 50"
  info "Verifying Docker..."
  for i in {1..3}; do docker run --rm hello-world &>/dev/null && break; sleep 5; done
  docker compose version &>/dev/null || fatal "Docker Compose plugin missing."
  success "Docker $(docker version --format '{{.Server.Version}}') + Compose $(docker compose version --short)"
}

setup_docker_network() {
  step "Docker Network: proxy"
  # NEVER remove existing proxy network -- other containers may depend on it
  if ! docker network ls --format '{{.Name}}' | grep -qx "proxy"; then
    docker network create proxy 2>/dev/null || true
  fi
  docker network ls --format '{{.Name}}' | grep -qx "proxy" || fatal "Failed to create 'proxy' network"
  success "Network 'proxy' ready"
}

get_user_domain() {
  step "Domain Configuration"
  # Check existing config
  if [[ -f "${AUTHELIA_CONFIG_DIR}/configuration.yml" ]]; then
    local existing_domain
    existing_domain=$(grep "authelia_url:" "${AUTHELIA_CONFIG_DIR}/configuration.yml" 2>/dev/null | sed 's/.*https:\/\/authelia\.//' | tr -d ' ' || true)
    if [[ -n "$existing_domain" ]]; then
      info "Existing domain found: $existing_domain"
      read -rp "Use existing domain? [Y/n]: " use_existing
      [[ "$use_existing" =~ ^[Nn]$ ]] || { DOMAIN="$existing_domain"; return 0; }
    fi
  fi
  printf "\n${C_B}Enter your root domain${C_R} (e.g., example.com): "
  read -r DOMAIN
  [[ -z "$DOMAIN" ]] && fatal "Domain is required."
  DOMAIN=$(echo "$DOMAIN" | sed 's|https\?://||' | sed 's|/.*||' | tr -d ' ')
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
      info "Secret '${secret_name}' already exists (preserved)"
    fi
  done
}

setup_authelia_config() {
  step "Authelia Configuration"
  mkdir -p "$AUTHELIA_CONFIG_DIR"
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<VPS_IP>")

  # Generate configuration.yml -- unquoted EOF so $DOMAIN is substituted
  if [[ ! -f "${AUTHELIA_CONFIG_DIR}/configuration.yml" ]]; then
    cat > "${AUTHELIA_CONFIG_DIR}/configuration.yml" << EOF
---
# Authelia Configuration -- auto-generated
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
    - domain: 'authelia.${DOMAIN}'
      policy: one_factor
    - domain: 'portainer.${DOMAIN}'
      policy: two_factor
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
      default_redirection_url: 'https://portainer.${DOMAIN}'
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
    success "configuration.yml created"
  else
    info "configuration.yml already exists (preserved)"
  fi

  # Store the random password for later use in setup_authelia_users
  random_pass=$(openssl rand -hex 8)
  echo "$random_pass" > "${AUTHELIA_DIR}/.default_password"
  chmod 600 "${AUTHELIA_DIR}/.default_password"
  info "Random password generated for Authelia admin account"
  info "users.yml will be created after authelia container starts"
}

create_nginx_snippets() {
  step "NGINX Snippets for NPM + Authelia"
  mkdir -p "$AUTHELIA_SNIPPETS_DIR"

  # snippet 1: authelia-authrequest.conf
  cat > "${AUTHELIA_SNIPPETS_DIR}/authelia-authrequest.conf" << 'SNIPPET1'
## Authelia - Auth Request
set $upstream_authelia http://authelia:9091;
location /authelia {
    internal;
    proxy_pass $upstream_authelia/api/authz/forward-auth;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_set_header X-Original-URL $scheme://$http_host$request_uri;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $http_host;
    proxy_set_header X-Forwarded-Uri $request_uri;
    proxy_cache_bypass $cookie_session;
    proxy_no_cache $cookie_session;
    proxy_http_version 1.1;
}
SNIPPET1

  # snippet 2: authelia-location.conf
  cat > "${AUTHELIA_SNIPPETS_DIR}/authelia-location.conf" << 'SNIPPET2'
## Authelia - Location header for redirection
location /authelia {
    proxy_pass http://authelia:9091;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $http_host;
}
SNIPPET2

  # snippet 3: proxy.conf
  cat > "${AUTHELIA_SNIPPETS_DIR}/proxy.conf" << 'SNIPPET3'
## Common Proxy Headers
client_body_buffer_size 128k;
proxy_next_upstream error timeout invalid_header http_500 http_502 http_503;
proxy_redirect http:// $scheme://;
proxy_http_version 1.1;
proxy_cache_bypass $cookie_session;
proxy_no_cache $cookie_session;
proxy_buffers 64 256k;
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host $http_host;
proxy_set_header X-Forwarded-Uri $request_uri;
proxy_set_header X-Forwarded-Ssl on;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $connection_upgrade;
proxy_read_timeout 86400;
proxy_send_timeout 86400;
proxy_connect_timeout 86400;
send_timeout 86400;
SNIPPET3

  success "NGINX snippets created in ${AUTHELIA_SNIPPETS_DIR}"
  info "Mount these snippets in NPM via docker volume or copy into NPM data"
}

setup_authelia_users() {
  step "Creating Authelia User Account"

  # Only create if users.yml doesn't already exist
  if [[ -f "${AUTHELIA_CONFIG_DIR}/users.yml" ]]; then
    info "users.yml already exists (preserved)"
    return 0
  fi

  # Read the random password generated during setup_authelia_config
  local random_pass=""
  if [[ -f "${AUTHELIA_DIR}/.default_password" ]]; then
    random_pass=$(cat "${AUTHELIA_DIR}/.default_password")
  fi
  if [[ -z "$random_pass" ]]; then
    warn "No random password found, generating fallback"
    random_pass=$(openssl rand -hex 8)
    echo "$random_pass" > "${AUTHELIA_DIR}/.default_password"
    chmod 600 "${AUTHELIA_DIR}/.default_password"
  fi

  info "Generating password hash using the Authelia container..."
  local hash_output
  hash_output=$(docker exec authelia authelia crypto hash generate argon2 --password "$random_pass" 2>&1) || true
  local pass_hash
  pass_hash=$(echo "$hash_output" | grep -o 'Digest: .*' | sed 's/Digest: //' | tr -d ' \t\n\r') || true

  if [[ -z "$pass_hash" ]] || [[ ! "$pass_hash" == \$argon2id\$* ]]; then
    warn "Retrying hash generation..."
    pass_hash=$(docker exec authelia sh -c "authelia crypto hash generate argon2 --password '$random_pass' 2>&1" | grep -o 'Digest: .*' | sed 's/Digest: //' | tr -d ' \t\n\r') || true
  fi

  if [[ -z "$pass_hash" ]] || [[ ! "$pass_hash" == \$argon2id\$* ]]; then
    fatal "Could not generate a valid password hash. Check: docker logs authelia"
  fi

  cat > "${AUTHELIA_CONFIG_DIR}/users.yml" << USEREOF
---
users:
  admin:
    disabled: false
    displayname: "Administrator"
    password: "${pass_hash}"
    email: admin@${DOMAIN}
    groups:
      - admins
      - users
USEREOF

  success "Authelia user 'admin' created with random password"
  info "Password stored in: ${AUTHELIA_DIR}/.default_password"
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
  step "Deploying Portainer + Authelia Stack"
  mkdir -p "$NPM_DATA_DIR" "$NPM_LE_DIR" "$NPM_LOGS_DIR" && cd "$STACK_DIR"

  # Use absolute paths for Authelia volumes in compose
  local authelia_config_path="${AUTHELIA_CONFIG_DIR}"
  local authelia_secrets_path="${AUTHELIA_SECRETS_DIR}"

  cat > docker-compose.yml << COMPOSE
services:
  npm:
    image: 'jc21/nginx-proxy-manager:latest'
    restart: always
    container_name: npm
    hostname: npm
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

  portainer:
    image: 'portainer/portainer-ce:latest'
    restart: always
    container_name: portainer
    hostname: portainer
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    networks:
      - proxy
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://127.0.0.1:9000/api/status"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

  authelia:
    image: authelia/authelia:latest
    container_name: authelia
    hostname: authelia
    restart: always
    volumes:
      - ${authelia_config_path}:/config
      - ${authelia_secrets_path}:/config/secrets:ro
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

volumes:
  portainer_data:

networks:
  proxy:
    external: true
COMPOSE

  info "Pulling Docker images (NPM, Portainer, Authelia) — this may take a few minutes..."
  docker compose pull
  docker rm -f npm 2>/dev/null || true
  docker rm -f portainer 2>/dev/null || true
  docker rm -f authelia 2>/dev/null || true

  info "Starting containers — please wait..."
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
    printf "${C_DIM}  Waiting for NPM ports... (%d/30)${C_R}\r" "$i"
    [[ $i -eq 30 ]] && {
      echo ""; echo "  Port 80 bound:  $has_80"; echo "  Port 443 bound: $has_443"; echo "  Port 81 bound:  $has_81"; echo ""
      ss -tlnp 2>/dev/null | grep -E ':80 |:443 |:81 ' || true; echo ""
      fatal "NPM failed to bind required ports. Check: docker logs npm"
    }
    sleep 2
  done
  printf "\n"

  info "Waiting for NPM container to start..."
  for i in $(seq 1 30); do
    docker ps --format '{{.Names}}' | grep -qx "npm" && { success "NPM container running"; break; }
    printf "${C_DIM}  Waiting for NPM container... (%d/30)${C_R}\r" "$i"
    [[ $i -eq 30 ]] && warn "NPM container not found after 60s"
    sleep 2
  done
  printf "\n"

  info "Waiting for NPM admin UI (:81)..."
  for i in $(seq 1 60); do
    curl -sf --max-time 5 http://127.0.0.1:81/ &>/dev/null && { success "NPM admin UI ready"; break; }
    printf "${C_DIM}  Waiting for NPM admin UI... (%d/60)${C_R}\r" "$i"
    [[ $i -eq 60 ]] && warn "NPM UI timed out (2m)"
    sleep 2
  done
  printf "\n"

  info "Waiting for NPM log files..."
  for i in $(seq 1 30); do
    if ls "${NPM_LOGS_DIR}/"*_access.log "${NPM_LOGS_DIR}/"*_error.log &>/dev/null; then
      success "NPM logs present"
      break
    fi
    printf "${C_DIM}  Waiting for NPM log files... (%d/30)${C_R}\r" "$i"
    if [[ $i -eq 30 ]]; then
      warn "NPM logs not found. Creating placeholders."
      touch "${NPM_LOGS_DIR}/fallback_http_access.log" \
            "${NPM_LOGS_DIR}/fallback_http_error.log" \
            "${NPM_LOGS_DIR}/default-host_access.log" \
            "${NPM_LOGS_DIR}/default-host_error.log"
    fi
    sleep 2
  done
  printf "\n"

  info "Waiting for Portainer to be ready..."
  for i in $(seq 1 40); do
    docker exec portainer wget -qO- --timeout=5 http://127.0.0.1:9000/api/status &>/dev/null && { success "Portainer ready"; break; }
    printf "${C_DIM}  Waiting for Portainer... (%d/40)${C_R}\r" "$i"
    docker ps --format '{{.Names}}' | grep -qx "portainer" || { [[ $i -eq 40 ]] && warn "Portainer container not found"; }
    [[ $i -eq 40 ]] && warn "Portainer timed out. Check: docker logs portainer"
    sleep 3
  done
  printf "\n"

  info "Waiting for Authelia to be ready..."
  for i in $(seq 1 40); do
    docker exec authelia wget -qO- --timeout=5 http://127.0.0.1:9091/api/health &>/dev/null && { success "Authelia ready"; break; }
    printf "${C_DIM}  Waiting for Authelia... (%d/40)${C_R}\r" "$i"
    docker ps --format '{{.Names}}' | grep -qx "authelia" || { [[ $i -eq 40 ]] && warn "Authelia container not found"; }
    [[ $i -eq 40 ]] && warn "Authelia timed out. Check: docker logs authelia"
    sleep 3
  done
  printf "\n"

  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<VPS_IP>")
  success "NPM: http://${ip}:81"
  success "Portainer deployed (access via NPM proxy)"
  success "Authelia deployed (access via NPM proxy)"
}

setup_fail2ban() {
  step "Fail2Ban"
  info "Installing and configuring Fail2Ban..."
  if [[ "$OS_FAMILY" == "debian" ]]; then
    apt-get install -y -qq fail2ban
    local banaction="ufw"
  else
    local pkg="yum"; command -v dnf &>/dev/null && pkg="dnf"
    $pkg install -y -q fail2ban
    local banaction="firewallcmd-rich-rules"
  fi

  # NPM uses a custom access log format (IP inside [Client IP]).
  # Built-in fail2ban nginx filters won't match -- custom filter required.
  local fdir="/etc/fail2ban/filter.d"
  mkdir -p "$fdir"

  cat > "${fdir}/npm-access.conf" << 'FILTER'
# Fail2Ban filter for NPM access logs.
# NPM uses a custom format; standard nginx filters will NOT match.
[Definition]
failregex = ^.*\s+(?:401|403|404)\s+.*\[Client\s+<HOST>\]\s+\[Length\s+\d+\]\s+.*$
ignoreregex = ^.*\s+(?:404)\s+.*".*\.(?:png|jpe?g|gif|ico|svg|css|js|ttf|woff2?|eot|map)(?:\?[^"]*)?"\s+.*$
FILTER

  if [[ ! -f "${fdir}/nginx-http-auth.conf" ]]; then
    cat > "${fdir}/nginx-http-auth.conf" << 'FILTER'
[Definition]
failregex = ^ \[error\] \d+#\d+: \*\d+ user "[^"]*":? (password mismatch|was not found in "[^"]*"|login attempt failed), client: <HOST>, server: \S*, request: "\S+ \S+ HTTP/\d+\.\d+", host: "\S+"\s*$
ignoreregex =
datepattern = {^LN-BEG}%%ExY(?#\s)-(?#\s)%%m(?#\s)-(?#\s)%%d(?#\s)%%H(?#\s):(?#\s)%%M(?#\s):(?#\s)%%S(?:\.%f)?(?:\s+%%z)?
              ^[^\[]*\[({DATE})\s+[-+]\d{4}\]
FILTER
  fi

  if [[ ! -f "${fdir}/nginx-botsearch.conf" ]]; then
    cat > "${fdir}/nginx-botsearch.conf" << 'FILTER'
[Definition]
failregex = ^<HOST>.*"(\.\.\\|\%\%|\%[0-9a-fA-F][0-9a-fA-F]|\.(git|svn|htaccess|env|ssh|idea|vscode)).*".*(404|403|500)
            ^.*(404|403|500).*[Cc]lient\s+<HOST>.*".*(admin|wp-login|phpmyadmin|xmlrpc|config\.xml|\.env|wp-config).*"
ignoreregex =
FILTER
  fi

  mkdir -p "$NPM_LOGS_DIR"
  touch "${NPM_LOGS_DIR}/fallback_http_access.log" \
        "${NPM_LOGS_DIR}/fallback_http_error.log" \
        "${NPM_LOGS_DIR}/default-host_access.log" \
        "${NPM_LOGS_DIR}/default-host_error.log" 2>/dev/null || true

  cat > /etc/fail2ban/jail.local << EOF
# Auto-generated by ${SCRIPT_NAME} v${SCRIPT_VERSION} on $(date -Iseconds)
#
# NOTE: NPM uses a custom access log format. Built-in fail2ban nginx-* filters
# are BROKEN for NPM access logs. Use the custom 'npm-access' filter instead.
# Log files: ${NPM_LOGS_DIR}/

[DEFAULT]
bantime   = 3600
findtime  = 600
maxretry  = 5
banaction = ${banaction}
allowipv6 = auto

[sshd]
enabled  = true
port     = ssh
filter   = sshd
backend  = systemd
maxretry = 3

# NPM admin auth brute force (error logs = standard format)
[npm-auth]
enabled  = true
port     = http,https,81
filter   = nginx-http-auth
backend  = auto
logpath  = ${NPM_LOGS_DIR}/*_error.log
maxretry = 3
findtime = 60

# NPM forceful browsing / bot detection (custom filter for access logs)
[npm-forceful-browsing]
enabled  = true
port     = http,https
filter   = npm-access
backend  = auto
logpath  = ${NPM_LOGS_DIR}/*_access.log
maxretry = 15
findtime = 60
bantime  = 3600

# NPM bot search (error log)
[npm-botsearch]
enabled  = true
port     = http,https
filter   = nginx-botsearch
backend  = auto
logpath  = ${NPM_LOGS_DIR}/*_error.log
maxretry = 2
findtime = 600
bantime  = 86400
EOF

  mkdir -p /var/log/fail2ban
  systemctl restart fail2ban && systemctl enable fail2ban
  sleep 2
  local jails; jails=$(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*://' | tr -d ' ' || true)
  [[ -n "$jails" ]] && success "Jails: ${jails}" || warn "Check jails: fail2ban-client status"
  success "Fail2Ban configured"
}

setup_firewall() {
  step "Firewall"
  if [[ "$OS_FAMILY" == "debian" ]]; then setup_firewall_debian
  else setup_firewall_rhel; fi
}

setup_firewall_debian() {
  info "Configuring UFW firewall..."
  apt-get install -y -qq ufw

  # CRITICAL: Docker manipulates iptables directly. UFW's DEFAULT_FORWARD_POLICY=DROP
  # blocks all container traffic. Must set ACCEPT before enabling UFW.
  local ufw_def="/etc/default/ufw"
  if [[ -f "$ufw_def" ]]; then
    cp -n "$ufw_def" "${ufw_def}.bak" 2>/dev/null || true
    if grep -q '^DEFAULT_FORWARD_POLICY=' "$ufw_def"; then
      sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' "$ufw_def"
    else
      echo 'DEFAULT_FORWARD_POLICY="ACCEPT"' >> "$ufw_def"
    fi
  else
    echo 'DEFAULT_FORWARD_POLICY="ACCEPT"' > "$ufw_def"
  fi
  success "UFW DEFAULT_FORWARD_POLICY=ACCEPT"

  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing

  local ssh_port; ssh_port=$(ss -tlnp 2>/dev/null | grep -m1 ':22 ' | awk '{print $4}' | cut -d: -f2 || echo "22")
  ufw allow "${ssh_port:-22}/tcp" comment 'SSH'
  ufw allow 80/tcp comment 'HTTP'
  ufw allow 443/tcp comment 'HTTPS'
  ufw allow 81/tcp comment 'NPM Admin'

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

  if ! firewall-cmd --get-zones 2>/dev/null | grep -q '\bdocker\b'; then
    firewall-cmd --permanent --new-zone=docker 2>/dev/null || true
  fi
  firewall-cmd --permanent --zone=docker --add-interface=docker0 2>/dev/null || true
  firewall-cmd --permanent --zone=docker --set-target=ACCEPT 2>/dev/null || true
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
  local fw_cmd; [[ "$OS_FAMILY" == "debian" ]] && fw_cmd="ufw status verbose" || fw_cmd="firewall-cmd --list-all"

  # Read default password if it exists
  local default_pass_msg="authelia"
  if [[ -f "${AUTHELIA_DIR}/.default_password" ]]; then
    default_pass_msg=$(cat "${AUTHELIA_DIR}/.default_password")
  fi

  cat << EOF

${C_B}${C_GRN}╔══════════════════════════════════════════════════════════════════════╗${C_R}
${C_B}${C_GRN}║                    🚀 YOUR VPS IS READY!                             ║${C_R}
${C_B}${C_GRN}╠══════════════════════════════════════════════════════════════════════╣${C_R}
${C_B}${C_GRN}║  Deployment Complete  ${C_R}${C_B}(${SCRIPT_NAME} v${SCRIPT_VERSION})  ${C_CYN}$(( elapsed / 60 ))m $(( elapsed % 60 ))s${C_R}${C_B}   ║${C_R}
${C_B}${C_GRN}╚══════════════════════════════════════════════════════════════════════╝${C_R}

${C_B}Nginx Proxy Manager${C_R}
  Admin:   http://${ip}:81
  HTTP:    http://${ip}:80
  HTTPS:   https://${ip}:443
  Data:    ${NPM_DATA_DIR}
  SSL:     ${NPM_LE_DIR}
  Logs:    ${NPM_LOGS_DIR}

${C_B}Portainer CE${C_R}
  Container: portainer
  Port:      9000 (internal, no host port)
  Network:   proxy

${C_B}${C_YEL}════════════════════════════════════════════════════════════════${C_R}
${C_B}${C_YEL}  🔐  AUTHELIA LOGIN CREDENTIALS (SAVE THESE)${C_R}
${C_B}${C_YEL}════════════════════════════════════════════════════════════════${C_R}

  ${C_B}URL:${C_R}       https://authelia.${DOMAIN}
  ${C_B}Username:${C_R}  ${C_CYN}admin${C_R}
  ${C_B}Password:${C_R}  ${C_CYN}${default_pass_msg}${C_R}

  ${C_RED}⚠️  Change this password immediately after first login!${C_R}

${C_B}${C_YEL}════════════════════════════════════════════════════════════════${C_R}
${C_B}${C_YEL}  Authelia Configuration${C_R}
${C_B}${C_YEL}════════════════════════════════════════════════════════════════${C_R}

  Config:    ${AUTHELIA_CONFIG_DIR}
  Users:     ${AUTHELIA_CONFIG_DIR}/users.yml
  Secrets:   ${AUTHELIA_SECRETS_DIR}
  Snippets:  ${AUTHELIA_SNIPPETS_DIR}

${C_B}Docker${C_R}    $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo N/A)
${C_B}Compose${C_R}   $(docker compose version --short 2>/dev/null || echo N/A)
${C_B}Network${C_R}   proxy (bridge)

${C_B}Fail2Ban${C_R}  Jails: sshd, npm-auth, npm-forceful-browsing, npm-botsearch
${C_B}Firewall${C_R}  $(if [[ "$OS_FAMILY" == "debian" ]]; then echo "UFW"; else echo "firewalld"; fi)

${C_B}${C_YEL}Step 1 -- NPM Admin${C_R}
  Open:   http://${ip}:81
  Login:  admin@example.com / changeme
  ${C_RED}→ Change password immediately${C_R}

${C_B}${C_YEL}Step 2 -- Add DNS Records${C_R}
  A  authelia.${DOMAIN}   → ${ip}
  A  portainer.${DOMAIN}  → ${ip}
  A  *.${DOMAIN}          → ${ip}  (wildcard for other services)

${C_B}${C_YEL}Step 3 -- Add Proxy Hosts in NPM${C_R}
  Dashboards → Proxy Hosts → Add Proxy Host

  ${C_B}Authelia Portal:${C_R}
  ┌──────────────────────────────────────┐
  │ Domain Names:    authelia.${DOMAIN}   │
  │ Scheme:          http                │
  │ Forward Host:    authelia            │
  │ Forward Port:    9091                │
  │ Block Exploits:  ON                  │
  └──────────────────────────────────────┘
  Save → SSL tab → Request cert → Force SSL ON

  ${C_B}Portainer Dashboard:${C_R}
  ┌──────────────────────────────────────┐
  │ Domain Names:    portainer.${DOMAIN}  │
  │ Scheme:          http                │
  │ Forward Host:    portainer           │
  │ Forward Port:    9000                │
  │ Block Exploits:  ON                  │
  └──────────────────────────────────────┘
  Save → SSL tab → Request cert → Force SSL ON
  → Advanced tab: paste contents of authelia-authrequest.conf snippet

${C_B}${C_YEL}Step 4 -- Authelia Setup${C_R}
  Open:   https://authelia.${DOMAIN}
  Login:  admin / authelia
  ${C_RED}→ Change password via "Settings" → "Password" immediately${C_R}
  → Register TOTP device (scan QR code with authenticator app)

${C_B}${C_YEL}Step 5 -- Enable 2FA on Proxy Hosts${C_R}
  In NPM, edit each protected proxy host:
  Advanced tab → paste contents of authelia-authrequest.conf
  This forces Authelia 2FA before granting access.

${C_B}${C_YEL}Step 6 -- Secure Admin Port${C_R}
  $(if [[ "$OS_FAMILY" == "debian" ]]; then echo "  ufw delete allow 81/tcp && ufw reload"; else echo "  firewall-cmd --permanent --remove-port=81/tcp && firewall-cmd --reload"; fi)

${C_B}NGINX Snippets (for NPM Advanced tab):${C_R}
  ${AUTHELIA_SNIPPETS_DIR}/authelia-authrequest.conf
  ${AUTHELIA_SNIPPETS_DIR}/authelia-location.conf
  ${AUTHELIA_SNIPPETS_DIR}/proxy.conf

${C_B}Troubleshooting:${C_R}
  Logs:    docker logs -f npm    docker logs -f portainer    docker logs -f authelia
  Restart: cd ${STACK_DIR} && docker compose restart
  F2B:     fail2ban-client status    fail2ban-regex -v ${NPM_LOGS_DIR}/proxy-host-1_access.log /etc/fail2ban/filter.d/npm-access.conf
  FW:      ${fw_cmd}
  Log:     ${LOG_FILE}
EOF
  _log "INFO" "=== Deployment completed in $(( elapsed / 60 ))m $(( elapsed % 60 ))s ==="
}

main() {
  printf "\n${C_B}${C_CYN}VPS Deployment -- Docker + NPM + Portainer + Authelia + Fail2Ban${C_R}\n"
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
  setup_fail2ban
  setup_firewall
  setup_logrotate
  DEPLOY_STATUS="success"
  DEPLOYED_SERVICES="npm,portainer,authelia,fail2ban,firewall"
  print_summary
}

main "$@"
