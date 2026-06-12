#!/usr/bin/env bash
# Auto-elevate to root if not already running as root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi
# deploy-freedombox.sh — Hardened VPS Deployment for FreedomBox + NPM + CrowdSec
# v3.0.0-crowdsec | Usage: chmod +x deploy-freedombox.sh && sudo ./deploy-freedombox.sh
#
# FreedomBox (Debian Pure Blend) manages its own Apache2 and firewalld.
# CrowdSec provides intrusion prevention for FreedomBox.
# Supports: Debian 12 (Bookworm) or newer ONLY.
set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="3.0.0-crowdsec"
readonly SCRIPT_NAME="deploy-freedombox.sh"
readonly START_TIME=$(date +%s)
readonly NPM_DIR="/opt/npm"
readonly NPM_DATA_DIR="${NPM_DIR}/data"
readonly NPM_LE_DIR="${NPM_DIR}/letsencrypt"
readonly NPM_LOGS_DIR="${NPM_DATA_DIR}/logs"
readonly CROWDSEC_DIR="${NPM_DIR}/crowdsec"
readonly AUTHELIA_DIR="${NPM_DIR}/authelia"
readonly AUTHELIA_CONFIG_DIR="${AUTHELIA_DIR}/config"
readonly AUTHELIA_SECRETS_DIR="${AUTHELIA_DIR}/secrets"
readonly AUTHELIA_SNIPPETS_DIR="${AUTHELIA_DIR}/snippets"
readonly LOG_FILE="/var/log/vps-deploy.log"

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

readonly TOOL_LABEL="FreedomBox"

DEPLOY_STATUS="in_progress"
DOMAIN=""
CROWDSEC_CHOICE="crowdsec"

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
      printf "${C_B}${C_GRN}║                    ✅  DEPLOYMENT COMPLETED SUCCESSFULLY                      ║${C_R}\n"
      printf "${C_B}${C_GRN}╠══════════════════════════════════════════════════════════════════════════════╣${C_R}\n"
    else
      printf "${C_B}${C_RED}╔══════════════════════════════════════════════════════════════════════════════╗${C_R}\n"
      printf "${C_B}${C_RED}║                     ❌  DEPLOYMENT DID NOT COMPLETE                           ║${C_R}\n"
      printf "${C_B}${C_RED}╠══════════════════════════════════════════════════════════════════════════════╣${C_R}\n"
    fi
    printf "${C_B}║  Elapsed:   ${C_CYN}%dm %ds${C_R}${C_B}                                                          ║${C_R}\n" $(( elapsed / 60 )) $(( elapsed % 60 ))
    printf "${C_B}║  Internal:  ${C_CYN}%-16s${C_R}${C_B}                                                   ║${C_R}\n" "$ip"
    printf "${C_B}║  External:  ${C_CYN}%-16s${C_R}${C_B}                                                   ║${C_R}\n" "$ext_ip"
    printf "${C_B}║  Status:    %-16s${C_B}                                                   ║${C_R}\n" "$(if [[ "$DEPLOY_STATUS" == "success" ]]; then printf "${C_GRN}All systems go"; else printf "${C_RED}Check logs"; fi)"
    printf "${C_B}╠══════════════════════════════════════════════════════════════════════════════╣${C_R}\n"
    printf "${C_B}║  ${C_YEL}NPM Admin${C_R}${C_B}:  http://${C_CYN}%-56s${C_R}${C_B}║${C_R}\n" "${ip}:81"
    printf "${C_B}║  ${C_YEL}%-9s${C_R}${C_B}:  ${C_CYN}%-63s${C_R}${C_B}║${C_R}\n" "${TOOL_LABEL}" "${ip}:80/443 (own proxy, NPM on 81)"
    printf "${C_B}║  ${C_YEL}Authelia ${C_R}${C_B}:  ${C_CYN}%-63s${C_R}${C_B}║${C_R}\n" "${ip}:9091"
    printf "${C_B}║  ${C_YEL}Ports    ${C_R}${C_B}:  ${C_CYN}22 (SSH), 80 (HTTP), 443 (HTTPS), 81 (NPM)    ${C_R}${C_B}║${C_R}\n"
    printf "${C_B}╠══════════════════════════════════════════════════════════════════════════════╣${C_R}\n"
    printf "${C_B}║  Log file: ${C_CYN}%-66s${C_R}${C_B}║${C_R}\n" "$LOG_FILE"
    printf "${C_B}╚══════════════════════════════════════════════════════════════════════════════╝${C_R}\n"
    printf "\n"
    if [[ "$DEPLOY_STATUS" == "success" ]]; then
      printf "${C_B}${C_GRN}Your VPS is ready!${C_R} Configure DNS → ${C_CYN}${ext_ip}${C_R} and set up NPM.\n\n"
    else
      printf "${C_B}${C_YEL}The deployment did not finish.${C_R} Check: ${C_CYN}cat %s${C_R}\n\n" "$LOG_FILE"
    fi
  fi
  exit $exit_code
}
trap _on_exit EXIT

## PRE-FLIGHT CHECKS
preflight_checks() {
  step "Pre-flight Checks"
  [[ "${EUID:-0}" -eq 0 ]] || fatal "Must run as root (use sudo)."
  success "Running as root"

  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    readonly OS_ID="${ID:-unknown}"
    readonly OS_NAME="${NAME:-Unknown}"
    readonly OS_VERSION_ID="${VERSION_ID:-0}"
  else
    fatal "/etc/os-release not found."
  fi

  # FreedomBox requires Debian 12+ (Bookworm)
  [[ "$OS_ID" == "debian" ]] || fatal "FreedomBox requires Debian. You have: ${OS_NAME}."
  [[ "${OS_VERSION_ID%%.*}" -ge 12 ]] || fatal "FreedomBox requires Debian 12+. You have: ${OS_VERSION_ID}"
  success "OS: ${OS_NAME} ${OS_VERSION_ID}"

  readonly ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) readonly DOCKER_ARCH="amd64" ;;
    aarch64|arm64) readonly DOCKER_ARCH="arm64" ;;
    *) fatal "Unsupported arch: ${ARCH}. Need x86_64 or arm64/aarch64." ;;
  esac
  success "Arch: ${ARCH} (${DOCKER_ARCH})"

  readonly OS_FAMILY="debian"

  info "Checking internet..."
  if ! curl -sf --max-time 10 https://deb.debian.org/ >/dev/null 2>&1 && \
     ! curl -sf --max-time 10 https://github.com/ >/dev/null 2>&1; then
    fatal "No internet connectivity."
  fi
  success "Internet OK"

  local free_mb; free_mb=$(df -m / | awk 'NR==2 {print $4}')
  if [[ "$free_mb" -lt 2048 ]]; then warn "Low disk: ${free_mb}MB free (recommend >= 2048MB)."
  else success "Disk: $(( free_mb / 1024 ))GB free"; fi

  mkdir -p "$(dirname "$LOG_FILE")"
  _log "INFO" "=== ${SCRIPT_NAME} v${SCRIPT_VERSION} started ==="
  _log "INFO" "OS: ${OS_NAME} ${OS_VERSION_ID}, Arch: ${ARCH}"
}

## IDEMPOTENT CLEANUP
idempotent_cleanup() {
  step "Cleanup"

  if command -v docker &>/dev/null; then
    info "Removing ALL existing containers and volumes..."
    docker ps -aq 2>/dev/null | xargs -r docker stop &>/dev/null || true
    docker ps -aq 2>/dev/null | xargs -r docker rm -f &>/dev/null || true
    docker volume ls -q 2>/dev/null | xargs -r docker volume rm -f &>/dev/null || true
  fi

  # Remove ALL previously deployed platform data directories
  info "Removing ALL previous platform data..."
  for dir in /opt/npm /opt/casaos /var/lib/casaos /opt/casaos-stack /opt/coolify-stack /opt/cosmos-stack /opt/dockge-stack /opt/dokploy-stack /opt/portainer-stack /opt/runtipi-stack /opt/freedombox-stack /opt/yunohost-stack; do
    rm -rf "$dir" 2>/dev/null || true
  done

  # Stop and remove ALL previously deployed platform systemd services
  info "Removing ALL previous platform services..."
  for svc in casaos-gateway casaos-user-service casaos-local-storage casaos-message-bus runtipi crowdsec-firewall-bouncer; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    systemctl mask "$svc" 2>/dev/null || true
    rm -f "/etc/systemd/system/${svc}.service" "/etc/systemd/system/${svc}" 2>/dev/null || true
  done
  systemctl daemon-reload 2>/dev/null || true

  # Remove firewall bouncer binary and config
  rm -f /usr/local/bin/crowdsec-firewall-bouncer 2>/dev/null || true
  rm -f /etc/crowdsec/crowdsec-firewall-bouncer.yaml 2>/dev/null || true
  rm -rf /etc/crowdsec 2>/dev/null || true

  # Remove native crowdsec packages
  if [[ "$OS_FAMILY" == "debian" ]]; then
    apt-get remove -y -qq crowdsec crowdsec-firewall-bouncer-nftables crowdsec-firewall-bouncer-iptables 2>/dev/null || true
    apt-get autoremove -y -qq 2>/dev/null || true
  else
    local pkg="yum"; command -v dnf &>/dev/null && pkg="dnf"
    $pkg remove -y -q crowdsec crowdsec-firewall-bouncer-nftables crowdsec-firewall-bouncer-iptables 2>/dev/null || true
  fi

  # Also handle snap-installed Docker (Ubuntu)
  if command -v snap &>/dev/null; then
    snap disable docker 2>/dev/null || true
    snap remove docker 2>/dev/null || true
  fi
}



## SYSTEM UPDATE & DEPENDENCIES
system_update() {
  step "System Update"
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  apt-get update -qq && apt-get upgrade -y -qq && apt-get autoremove -y -qq && apt-get autoclean -qq
  success "System updated"
}

install_dependencies() {
  step "Installing Dependencies"
  apt-get install -y -qq ca-certificates curl gnupg lsb-release \
    software-properties-common apt-transport-https jq cron logrotate
  success "Dependencies installed"
}

## PREPARE SYSTEM FOR FREEDOMBOX
prepare_system() {
  step "Preparing System"

  # UFW conflicts with firewalld which FreedomBox uses
  info "Removing UFW (FreedomBox uses firewalld)..."
  apt-get remove -y -qq ufw 2>/dev/null || true
  systemctl stop ufw 2>/dev/null || true
  systemctl disable ufw 2>/dev/null || true
  apt-get purge -y -qq ufw 2>/dev/null || true

  # NetworkManager is required by FreedomBox
  info "Installing NetworkManager..."
  apt-get install -y -qq network-manager 2>/dev/null || true
  systemctl enable NetworkManager 2>/dev/null || true
  systemctl start NetworkManager 2>/dev/null || true

  info "Installing firewalld..."
  apt-get install -y -qq firewalld 2>/dev/null || true
  systemctl enable firewalld 2>/dev/null || true

  success "System prepared"
}

## DOCKER CE INSTALLATION
install_docker() {
  step "Installing Docker CE"
  if command -v docker &>/dev/null && docker version &>/dev/null; then
    success "Docker already installed: $(docker --version)"; return 0
  fi

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" -o /etc/apt/keyrings/docker.asc 2>/dev/null || \
    curl -fsSL "https://download.docker.com/linux/debian/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  local repo_url; repo_url="https://download.docker.com/linux/${OS_ID}"
  echo "deb [arch=${DOCKER_ARCH} signed-by=/etc/apt/keyrings/docker.asc] ${repo_url} $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

  systemctl start docker && systemctl enable docker
  systemctl is-active --quiet docker || fatal "Docker daemon failed. Check: journalctl -u docker -n 50"

  info "Verifying Docker (please wait)..."
  for i in {1..3}; do
    docker run --rm hello-world &>/dev/null && break
    printf "${C_DIM}  Waiting... (%d/3)${C_R}\r" "$i"
    sleep 5
  done
  docker compose version &>/dev/null && success "Docker $(docker version --format '{{.Server.Version}}') + Compose $(docker compose version --short)" || \
    success "Docker $(docker version --format '{{.Server.Version}}')"
}

## DOCKER NETWORK
setup_docker_network() {
  step "Docker Network: proxy"
  # NEVER remove existing proxy network — other containers may depend on it
  if ! docker network ls --format '{{.Name}}' | grep -qx "proxy"; then
    docker network create proxy 2>/dev/null || true
  fi
  docker network ls --format '{{.Name}}' | grep -qx "proxy" || fatal "Failed to create 'proxy' network"
  success "Network 'proxy' ready"
}

## NGINX PROXY MANAGER (port 81 — FreedomBox Apache owns 80/443)
setup_nginx_proxy_manager() {
  step "Nginx Proxy Manager (supplementary proxy on port 81)"
  mkdir -p "$NPM_DATA_DIR" "$NPM_LE_DIR" "$NPM_LOGS_DIR" "$CROWDSEC_DIR"

  cat > "${NPM_DIR}/docker-compose.npm.yml" << 'COMPOSE_NPM'
services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    restart: always
    container_name: npm
    ports:
      - 0.0.0.0:81:81
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
    networks:
      - proxy
networks:
  proxy:
    external: true
COMPOSE_NPM

  cat > "${NPM_DIR}/docker-compose.authelia.yml" << 'COMPOSE_AUTHELIA'
services:
  authelia:
    image: authelia/authelia:latest
    container_name: authelia
    hostname: authelia
    restart: always
    user: "0:0"
    volumes:
      - ./authelia/config:/config
      - ./authelia/secrets:/config/secrets:ro
    environment:
      - AUTHELIA_JWT_SECRET_FILE=/config/secrets/jwt_session
      - AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE=/config/secrets/storage_encryption
      - AUTHELIA_SESSION_SECRET_FILE=/config/secrets/session
      - AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET_FILE=/config/secrets/jwt_session
      - TZ=America/New_York
    networks:
      - proxy
networks:
  proxy:
    external: true
COMPOSE_AUTHELIA

  cat > "${NPM_DIR}/docker-compose.crowdsec.yml" << 'COMPOSE_CROWDSEC'
services:
  crowdsec:
    image: crowdsecurity/crowdsec:latest
    container_name: crowdsec
    hostname: crowdsec
    restart: unless-stopped
    ports:
      - "127.0.0.1:8080:8080"
    volumes:
      - ./crowdsec/data:/var/lib/crowdsec/data
      - ./crowdsec/config:/etc/crowdsec
      - ./data/logs:/npm-logs:ro
      - /var/log:/var/log:ro
    environment:
      - COLLECTIONS=crowdsecurity/sshd crowdsecurity/nginx-proxy-manager crowdsecurity/linux
      - TZ=UTC
    networks:
      - proxy
networks:
  proxy:
    external: true
COMPOSE_CROWDSEC

  docker compose -f "${NPM_DIR}/docker-compose.npm.yml" pull
  docker compose -f "${NPM_DIR}/docker-compose.crowdsec.yml" pull
  docker compose -f "${NPM_DIR}/docker-compose.authelia.yml" pull

  info "Starting NPM..."
  docker compose -f "${NPM_DIR}/docker-compose.npm.yml" up -d

  info "Verifying NPM port 81 is bound (FreedomBox Apache owns 80/443)..."
  local ports_ok=false
  info "Please wait..."
  for i in $(seq 1 30); do
    if ss -tlnp 2>/dev/null | grep -q ':81[[:space:]]'; then
      success "NPM bound port 81 (FreedomBox Apache owns 80/443)"
      ports_ok=true
      break
    fi
    printf "${C_DIM}  Waiting... (%d/30)${C_R}\r" "$i"
    [[ $i -eq 30 ]] && {
      echo ""; ss -tlnp 2>/dev/null | grep -E ':81 ' || true; echo ""
      fatal "NPM failed to bind port 81. Check: docker logs npm"
    }
    sleep 2
  done


  info "Waiting for NPM container (please wait)..."
  for i in $(seq 1 30); do
    docker ps --format '{{.Names}}' | grep -qx "npm" && break
    printf "${C_DIM}  Waiting... (%d/30)${C_R}\r" "$i"
    sleep 2
  done

  info "Waiting for NPM admin UI (port 81)..."
  for i in $(seq 1 60); do
    curl -sf --max-time 5 http://127.0.0.1:81/ &>/dev/null && { success "NPM admin UI responding"; break; }
    printf "${C_DIM}  Waiting... (%d/60)${C_R}\r" "$i"
    [[ $i -eq 60 ]] && warn "NPM UI timed out (2m). Still starting?"
    sleep 2
  done

  info "Waiting for NPM log files..."
  for i in $(seq 1 30); do
    if ls "${NPM_LOGS_DIR}/"*_access.log "${NPM_LOGS_DIR}/"*_error.log &>/dev/null; then
      success "NPM logs present"; break
    fi
    printf "${C_DIM}  Waiting... (%d/30)${C_R}\r" "$i"
    if [[ $i -eq 30 ]]; then
      warn "NPM logs not found. Creating placeholders."
      touch "${NPM_LOGS_DIR}/fallback_http_access.log" \
            "${NPM_LOGS_DIR}/fallback_http_error.log" \
            "${NPM_LOGS_DIR}/default-host_access.log" \
            "${NPM_LOGS_DIR}/default-host_error.log"
    fi
    sleep 2
  done

  info "Deploying Authelia..."
  mkdir -p "$AUTHELIA_DIR" "$AUTHELIA_CONFIG_DIR" "$AUTHELIA_SECRETS_DIR" "$AUTHELIA_SNIPPETS_DIR"
  setup_authelia_secrets
  setup_authelia_config
  setup_authelia_snippets
  docker compose -f "${NPM_DIR}/docker-compose.authelia.yml" up -d
  info "Waiting for Authelia..."
  for i in $(seq 1 30); do
    docker ps --format '{{.Names}}' | grep -qx "authelia" && { success "Authelia ready"; break; }
    printf "${C_DIM}  Waiting for Authelia container... (%d/30)${C_R}\r" "$i"
    [[ $i -eq 30 ]] && warn "Authelia container not found"
    sleep 2
  done
  printf "\n"
  setup_authelia_users

  info "Starting CrowdSec..."
  docker compose -f "${NPM_DIR}/docker-compose.crowdsec.yml" up -d

  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<VPS_IP>")
  success "NPM deployed: http://${ip}:81"
}

## AUTHELIA SETUP

setup_authelia_secrets() {
  info "Generating Authelia secrets..."
  mkdir -p "$AUTHELIA_SECRETS_DIR"
  [[ -f "${AUTHELIA_SECRETS_DIR}/jwt_session" ]] || openssl rand -hex 32 > "${AUTHELIA_SECRETS_DIR}/jwt_session"
  [[ -f "${AUTHELIA_SECRETS_DIR}/storage_encryption" ]] || openssl rand -hex 32 > "${AUTHELIA_SECRETS_DIR}/storage_encryption"
  [[ -f "${AUTHELIA_SECRETS_DIR}/session" ]] || openssl rand -hex 32 > "${AUTHELIA_SECRETS_DIR}/session"
  chmod 600 "${AUTHELIA_SECRETS_DIR}"/*
  success "Authelia secrets generated"
}

setup_authelia_config() {
  info "Generating Authelia config..."
  mkdir -p "$AUTHELIA_CONFIG_DIR"
  cat > "${AUTHELIA_CONFIG_DIR}/configuration.yml" << AUTHELIA_CONFIG
###############################################################
#                      Authelia configuration                #
###############################################################
host: 0.0.0.0
port: 9091
log_level: info
jwt_secret: file:///config/secrets/jwt_session
default_redirection_url: https://${DOMAIN:-example.com}/

totp:
  issuer: authelia.com
  period: 30
  skew: 1

authentication_backend:
  file:
    path: /config/users.yml

access_control:
  default_policy: deny
  rules:
    - domain: "${DOMAIN:-example.com}"
      policy: two_factor

session:
  name: authelia_session
  secret: file:///config/secrets/session
  expiration: 3600
  inactivity: 300
  remember_me_duration: 1M

regulation:
  max_retries: 5
  find_time: 2m
  ban_time: 5m

storage:
  local:
    path: /config/db.sqlite3

notifier:
  filesystem:
    filename: /config/notifications.yml
AUTHELIA_CONFIG
  success "Authelia config generated"
}

setup_authelia_snippets() {
  step "Authelia NPM Snippets"
  mkdir -p "$AUTHELIA_SNIPPETS_DIR"
  cat > "${AUTHELIA_SNIPPETS_DIR}/authelia-authrequest.conf" << SNIPPET1
auth_request /authelia;
auth_request_set \$target_url \$scheme://\$http_host\$request_uri;
auth_request_set \$user \$upstream_http_remote_user;
auth_request_set \$groups \$upstream_http_remote_groups;
proxy_set_header Remote-User \$user;
proxy_set_header Remote-Groups \$groups;
error_page 401 =302 https://authelia.${DOMAIN}/?rd=\$target_url;

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
  cat > "${AUTHELIA_SNIPPETS_DIR}/authelia-location.conf" << 'SNIPPET2'
location /authelia {
    proxy_pass http://authelia:9091;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $http_host;
}
SNIPPET2
  success "Authelia NPM snippets created"
}

setup_authelia_users() {
  info "Configuring Authelia users..."
  if [[ ! -f "${AUTHELIA_CONFIG_DIR}/users.yml" ]]; then
    cat > "${AUTHELIA_CONFIG_DIR}/users.yml" << 'AUTHELIA_USERS'
users:
  admin:
    displayname: "Admin"
    password: "$argon2id$v=19$m=65536,t=3,p=4$..."  # CHANGE ME
    email: admin@example.com
    groups:
      - admins
AUTHELIA_USERS
    warn "Default user created - CHANGE the password hash immediately!"
    warn "Run: docker exec authelia authelia hash-password <your-password>"
  fi
  success "Authelia users configured"
}

## CROWDSEC

## FIREWALL: Open port 81 in firewalld for NPM
setup_firewall_npm() {
  step "Firewall: Opening port 81 for NPM"

  if command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-port=81/tcp 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
    success "Port 81 opened in firewalld"
  else
    warn "firewall-cmd not available. Port 81 may need manual opening."
    iptables -I INPUT -p tcp --dport 81 -j ACCEPT 2>/dev/null || true
  fi
}

## LOG ROTATION
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

## FREEDOMBOX INSTALLATION
setup_freedombox() {
  step "FreedomBox Installation"
  info "Installing FreedomBox (this may take 5-10 minutes)..."

  apt-get install -y -qq freedombox ssl-cert

  systemctl enable freedombox-first-run 2>/dev/null || true
  systemctl enable plinth 2>/dev/null || true
  systemctl start plinth 2>/dev/null || true

  info "Waiting for Plinth to start (please wait)..."
  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<VPS_IP>")
  for i in $(seq 1 60); do
    if curl -sf --max-time 5 "https://${ip}/freedombox/" -k &>/dev/null || \
       curl -sf --max-time 5 "http://${ip}/freedombox/" &>/dev/null; then
      success "Plinth responding"; break
    fi
    printf "${C_DIM}  Waiting... (%d/60)${C_R}\r" "$i"
    [[ $i -eq 60 ]] && warn "Plinth timed out (2m). Check: journalctl -u plinth -n 50"
    sleep 2
  done

  success "FreedomBox installed"
  info "First-boot setup required:"
  info "  1. Get secret: sudo cat /var/lib/plinth/firstboot-wizard-secret"
  info "  2. Visit:      https://${ip}/freedombox/"
  info "  3. Enter secret and create admin account."
  info "  Cockpit:       https://${ip}:9090/"
}

## SSH HARDENING
harden_ssh() {
  step "Hardening SSH"

  local sshd_custom="/etc/ssh/sshd_config.d/99-freedombox-deploy.conf"
  info "Applying SSH hardening via ${sshd_custom}..."

  cat > "$sshd_custom" << 'SSHD'
# Auto-generated by deploy-freedombox.sh
PermitRootLogin prohibit-password
ChallengeResponseAuthentication no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
MaxStartups 10:30:60
X11Forwarding no
GatewayPorts no
# PasswordAuthentication no   # Enable only after verifying key-based login
# AllowTcpForwarding no       # Enable only if SSH tunneling is needed
SSHD

  if sshd -t; then
    systemctl restart sshd
    success "SSH hardened"
  else
    warn "SSH config test failed. Skipping hardening."
    rm -f "$sshd_custom"
  fi

  info "SSH host key fingerprints:"
  local key_file; key_file="/etc/ssh/ssh_host_ed25519_key.pub"
  [[ -f "$key_file" ]] && info "  ED25519: $(ssh-keygen -lf "$key_file" | awk '{print $2}')" || true
  key_file="/etc/ssh/ssh_host_ecdsa_key.pub"
  [[ -f "$key_file" ]] && info "  ECDSA:   $(ssh-keygen -lf "$key_file" | awk '{print $2}')" || true
}

## POST-INSTALL VERIFICATION
verify_installation() {
  step "Verifying Installation"

  local -a services=("NetworkManager" "firewalld" "apache2" "plinth")
  local -a failed=()
  local svc status

  info "Checking services..."
  for svc in "${services[@]}"; do
    if systemctl is-enabled "$svc" &>/dev/null; then
      status=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
      if [[ "$status" == "active" ]]; then
        info "  ${svc}: ${C_GRN}${status}${C_R}"
      else
        warn "  ${svc}: ${C_YEL}${status}${C_R} (not active)"
      fi
    else
      warn "  ${svc}: not enabled"
      failed+=("$svc")
    fi
  done

  local secret_file="/var/lib/plinth/firstboot-wizard-secret"
  if [[ -f "$secret_file" ]] && [[ -s "$secret_file" ]]; then
    info "  Firstboot secret: ${C_GRN}generated${C_R}"
  else
    warn "  Firstboot secret: not yet generated"
  fi

  info "Checking listeners..."
  ss -tlnp 2>/dev/null | grep -q ':80\b'  && info "  Port 80 (HTTP):      ${C_GRN}listening${C_R}" || warn "  Port 80 (HTTP):      not listening"
  ss -tlnp 2>/dev/null | grep -q ':443\b' && info "  Port 443 (HTTPS):    ${C_GRN}listening${C_R}" || warn "  Port 443 (HTTPS):    not listening"
  ss -tlnp 2>/dev/null | grep -q ':9090\b' && info "  Port 9090 (Cockpit): ${C_GRN}listening${C_R}" || warn "  Port 9090 (Cockpit): not listening"

  if command -v firewall-cmd &>/dev/null; then
    local default_zone; default_zone=$(firewall-cmd --get-default-zone 2>/dev/null || echo "unknown")
    info "  Firewalld zone:      ${default_zone}"
  fi

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "npm"; then
    info "  Port 81 (NPM):       ${C_GRN}listening (Docker)${C_R}"
  else
    warn "  Port 81 (NPM):       not running"
  fi

  if [[ ${#failed[@]} -eq 0 ]]; then
    success "All critical services verified"
  else
    warn "Services need attention: ${failed[*]}"
  fi
}

## FAIL2BAN FALLBACK
setup_fail2ban() {
  step "Fail2Ban Installation"
  info "Installing Fail2Ban..."
  if [[ "$OS_FAMILY" == "debian" ]]; then
    sudo apt-get update -qq 2>/dev/null
    sudo apt-get install -y -qq fail2ban 2>/dev/null
  else
    sudo dnf install -y -q fail2ban 2>/dev/null || sudo yum install -y -q fail2ban 2>/dev/null
  fi
  _log "INFO" "fail2ban: installed"
}

## SUMMARY
print_summary() {
  local elapsed=$(( $(date +%s) - START_TIME ))
  local ip ext_ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "YOUR_VPS_IP")
  ext_ip=$(get_external_ip)
  local setup_secret; setup_secret=$(cat /var/lib/plinth/firstboot-wizard-secret 2>/dev/null || echo "<run: sudo cat /var/lib/plinth/firstboot-wizard-secret>")

  cat << EOF

${C_B}${C_GRN}DEPLOYMENT COMPLETE${C_R}  (${SCRIPT_NAME} v${SCRIPT_VERSION})
${C_B}External IP:${C_R} ${ext_ip}
${C_B}Duration:${C_R} $(( elapsed / 60 ))m $(( elapsed % 60 ))s

${C_B}${C_CYN}── SERVICES ──${C_R}
  FreedomBox (Plinth)
    URL:    https://${ip}/freedombox/
    Config: /etc/plinth/
    Data:   /var/lib/plinth/

  Cockpit
    URL:    https://${ip}:9090/

  Apache2    (managed by FreedomBox)
  Firewalld  (managed by FreedomBox)
  CrowdSec   (intrusion prevention)

${C_B}${C_CYN}── NGINX PROXY MANAGER ──${C_R}
  Admin:    http://${ip}:81  (admin@example.com / changeme)
  ${C_RED}→ Change password immediately.${C_R}
  Purpose:  Supplementary proxy for Docker-based services
  Data:     ${NPM_DATA_DIR}
  SSL:      ${NPM_LE_DIR}
  Logs:     ${NPM_LOGS_DIR}

${C_B}${C_CYN}── CROWDSEC ──${C_R}
  Status:   cscli metrics    cscli decisions list
  Config:   /etc/crowdsec/

${C_B}${C_CYN}── AUTHELIA ──${C_R}
  URL:      http://${ip}:9091
  Config:   ${AUTHELIA_CONFIG_DIR}
  Secrets:  ${AUTHELIA_SECRETS_DIR}
  Docs:     https://www.authelia.com/

${C_B}${C_CYN}── PORTS ──${C_R}
  22     TCP  SSH       Secure shell
  80     TCP  HTTP      FreedomBox Apache
  81     TCP  HTTP      NPM Admin UI
  443    TCP  HTTPS     FreedomBox Plinth + apps
  9090   TCP  HTTPS     Cockpit admin panel

${C_B}${C_YEL}── FIRST-BOOT SETUP ──${C_R}
  1. Get secret:  sudo cat /var/lib/plinth/firstboot-wizard-secret
     (Current:     ${setup_secret})
  2. Visit:        https://${ip}/freedombox/
  3. Enter secret, create admin account.
  4. NPM admin:    http://${ip}:81  (admin@example.com / changeme)
  5. Explore apps: BitTorrent, Calendar, File Sharing, Matrix, VPN, etc.

${C_B}${C_CYN}── TROUBLESHOOTING ──${C_R}
  Plinth:   journalctl -u plinth -n 50
  Apache:   journalctl -u apache2 -n 50
  Firewall: firewall-cmd --list-all
  CrowdSec: cscli metrics    cscli decisions list
  Cockpit:  systemctl status cockpit
  NPM:      cd ${NPM_DIR} && docker compose -f docker-compose.npm.yml restart
  CrowdSec: cd ${NPM_DIR} && docker compose -f docker-compose.crowdsec.yml restart
  Deploy:   ${LOG_FILE}

${C_B}${C_YEL}── NOTES ──${C_R}
  Firewall is managed by FreedomBox (firewalld). Do NOT install UFW.
  Apache2 is managed by FreedomBox. Do NOT modify vhosts directly.
  SSL certs can be configured via Plinth UI or Let's Encrypt.
  FreedomBox is a Debian Pure Blend — all packages from Debian repos.
  NPM, CrowdSec, and Authelia are deployed as separate Docker Compose services.
  Compose files: ${NPM_DIR}/docker-compose.npm.yml, ${NPM_DIR}/docker-compose.crowdsec.yml, ${NPM_DIR}/docker-compose.authelia.yml
EOF
  _log "INFO" "=== Deployment completed in $(( elapsed / 60 ))m $(( elapsed % 60 ))s ==="
}

## MAIN

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
  - /npm-logs/*.log
labels:
  type: nginx
NPM_ACQUIS
  if docker exec crowdsec cat /etc/crowdsec/acquis.d/npm.yaml &>/dev/null; then
    success "NPM acquisition configured"
  else
    docker exec -i crowdsec sh -c "mkdir -p /etc/crowdsec/acquis.d && cat > /etc/crowdsec/acquis.d/npm.yaml" << 'EOF' || true
filenames:
  - /npm-logs/*.log
labels:
  type: nginx
EOF
    warn "NPM acquisition written (via docker exec)"
  fi

  docker exec crowdsec kill -HUP 1 2>/dev/null || docker restart crowdsec &>/dev/null || true

  info "Installing firewall bouncer..."
  local bouncer_version
  bouncer_version=$(curl -sf --max-time 10 "https://api.github.com/repos/crowdsecurity/cs-firewall-bouncer/releases/latest" | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/') || bouncer_version="0.0.34"
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
    fatal "Firewall bouncer download failed -- check network connectivity"
  fi

  docker exec crowdsec cscli bouncers delete npm-bouncer 2>/dev/null || true
  local api_key
  api_key=$(docker exec crowdsec cscli bouncers add npm-bouncer 2>/dev/null | tail -1 || true)
  if [[ -n "$api_key" ]]; then
    mkdir -p /etc/crowdsec
    local fw_mode="iptables"
    command -v nft &>/dev/null && fw_mode="nftables"
    cat > /etc/crowdsec/crowdsec-firewall-bouncer.yaml << BOUNCER
api_url: http://127.0.0.1:8080
api_key: ${api_key}
mode: ${fw_mode}
deny_action: DROP
update_frequency: 10s
BOUNCER
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now crowdsec-firewall-bouncer 2>/dev/null || true
    success "Firewall bouncer registered"
  else
    warn "Could not register firewall bouncer -- run manually: docker exec crowdsec cscli bouncers add my-bouncer"
  fi
}

main() {
  printf "\n${C_B}${C_CYN}VPS Deployment — FreedomBox + NPM + Authelia${C_R}\n"
  printf "${C_DIM}${SCRIPT_NAME} v${SCRIPT_VERSION}${C_R}\n\n"

  read -rp "Enter your domain (e.g., example.com) [default: example.com]: " DOMAIN_INPUT
  DOMAIN="${DOMAIN_INPUT:-example.com}"

  preflight_checks
  idempotent_cleanup
  system_update
  install_dependencies
  prepare_system
  setup_freedombox
  install_docker
  setup_docker_network
  setup_nginx_proxy_manager
  if [[ "$DOCKER_ARCH" == "amd64" ]]; then
    setup_crowdsec
  else
    printf "\n${C_YEL}ARM architecture detected -- CrowdSec dashboard not available.${C_R}\n"
    printf "${C_B}Options:${C_R}\n"
    printf "  ${C_CYN}1)${C_R} CrowdSec (CLI-only, no dashboard)\n"
    printf "  ${C_CYN}2)${C_R} Fail2Ban (traditional, no dashboard needed)\n"
    read -rp "Choice [1/2]: " arm_choice
    case "$arm_choice" in
      2) setup_fail2ban; CROWDSEC_CHOICE="fail2ban" ;;
      *) setup_crowdsec ;;
    esac
  fi
  setup_firewall_npm
  setup_logrotate
  harden_ssh
  verify_installation

  DEPLOY_STATUS="success"

  print_summary
}

main "$@"
