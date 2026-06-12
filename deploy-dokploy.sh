#!/usr/bin/env bash
# Auto-elevate to root if not already running as root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi
# deploy-dokploy.sh — Hardened VPS Deployment (Docker + NPM + Dokploy + Portainer + CrowdSec)
# v3.0.0-crowdsec | Usage: chmod +x deploy-dokploy.sh && sudo ./deploy-dokploy.sh
#
# One-shot, idempotent deployment. Installs Docker CE, Nginx Proxy Manager (main proxy
# on 80/443/81), Dokploy (UI via NPM proxy), Portainer CE, CrowdSec, and host firewall.
# NPM owns 80/443; Dokploy's Traefik is stopped after install.
#
# Supports: Ubuntu 20.04+, Debian 11+, Rocky/Alma 8/9, Fedora 35+,
#           CentOS 7/8, Oracle Linux, Amazon Linux 2023
set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="3.0.0-crowdsec"
readonly SCRIPT_NAME="deploy-dokploy.sh"
readonly START_TIME=$(date +%s)
readonly NPM_DIR="/opt/npm"
readonly PORTAINER_DIR="/opt/portainer"
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

# Deployment state
DEPLOY_STATUS="in_progress"
DOMAIN="yourdomain.com"
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
    if [[ "$DEPLOY_STATUS" == "success" ]]; then
      printf "${C_B}║  ${C_YEL}Dokploy  ${C_R}${C_B}:  http://${C_CYN}%-56s${C_R}${C_B}║${C_R}\n" "dokploy.${DOMAIN:-yourdomain.com} (via NPM)"
      printf "${C_B}║  ${C_YEL}Authelia ${C_R}${C_B}:  http://${C_CYN}%-56s${C_R}${C_B}║${C_R}\n" "auth.${DOMAIN:-yourdomain.com} (via NPM)"
      printf "${C_B}║  ${C_YEL}Reset PW ${C_R}${C_B}:  ${C_CYN}%-56s${C_R}${C_B}║${C_R}\n" "sudo docker exec authelia cat /config/notifications.txt"
    fi
    printf "${C_B}║  ${C_YEL}Ports    ${C_R}${C_B}:  ${C_CYN}80 (HTTP), 443 (HTTPS), 81 (NPM Admin)          ${C_R}${C_B}║${C_R}\n"
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

# Logging utilities
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
_log() { printf "[%s] [%-5s] %s\n" "$(_ts)" "$1" "${*:2}" >> "$LOG_FILE" 2>/dev/null || true; }
info()    { printf "${C_BLU}i${C_R}  %s\n" "$*"; _log "INFO" "$@"; }
warn()    { printf "${C_YEL}!${C_R}  %s\n" "$*"; _log "WARN" "$@"; }
error()   { printf "${C_RED}x${C_R}  %s\n" "$*"; _log "ERROR" "$@"; }
success() { printf "${C_GRN}+${C_R}  %s\n" "$*"; _log "SUCCESS" "$@"; }
fatal()   { DEPLOY_STATUS="failed"; printf "${C_RED}${C_B}FATAL${C_R}${C_RED}: %s${C_R}\n" "$*" >&2; _log "FATAL" "$@"; exit 1; }
step()    { printf "\n${C_B}${C_CYN}-- %s --${C_R}\n" "$*"; _log "STEP" "$@"; }

preflight_checks() {
  step "Pre-flight Checks"
  if [[ "${EUID:-0}" -ne 0 ]]; then fatal "Must run as root (use sudo)."; fi
  success "Running as root"

  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    readonly OS_ID="${ID:-unknown}"
    readonly OS_NAME="${NAME:-Unknown}"
    readonly OS_VERSION_ID="${VERSION_ID:-0}"
    readonly OS_LIKE="${ID_LIKE:-}"
  else
    fatal "/etc/os-release not found. Cannot determine OS."
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
  success "OS: ${OS_NAME} ${OS_VERSION_ID} (family: ${OS_FAMILY})"

  if [[ "$OS_FAMILY" == "debian" ]]; then
    local major_ver="${OS_VERSION_ID%%.*}"
    if [[ "$OS_ID" == "ubuntu" && "$major_ver" -lt 20 ]]; then fatal "Ubuntu ${OS_VERSION_ID} too old. Min: 20.04."; fi
    if [[ "$OS_ID" == "debian" && "$major_ver" -lt 11 ]]; then fatal "Debian ${OS_VERSION_ID} too old. Min: 11."; fi
  fi

  readonly ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) readonly DOCKER_ARCH="amd64" ;;
    aarch64|arm64) readonly DOCKER_ARCH="arm64" ;;
    *) fatal "Unsupported arch: ${ARCH}. Need x86_64 or arm64/aarch64." ;;
  esac
  success "Arch: ${ARCH} (Docker: ${DOCKER_ARCH})"

  info "Checking internet..."
  if ! curl -sf --max-time 10 https://download.docker.com/ >/dev/null 2>&1 && \
     ! curl -sf --max-time 10 https://github.com/ >/dev/null 2>&1; then
    fatal "No internet connectivity."
  fi
  success "Internet OK"

  local free_mb; free_mb=$(df -m / | awk 'NR==2 {print $4}')
  if [[ "$free_mb" -lt 2048 ]]; then warn "Low disk: ${free_mb}MB free (recommend >= 2GB)."
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
  # Remove ALL previously deployed platform data directories
  info "Removing ALL previous platform data..."
  for dir in /opt/npm /opt/casaos /var/lib/casaos /opt/casaos-stack /opt/coolify-stack /opt/cosmos-stack /opt/dockge-stack /opt/dokploy-stack /opt/portainer-stack /opt/runtipi-stack /opt/freedombox-stack /opt/yunohost-stack /etc/dokploy; do
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



system_update() {
  step "System Update"
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
  step "Installing Dependencies"
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
  step "Installing Docker CE"
  if command -v docker &>/dev/null && docker version &>/dev/null; then
    success "Docker already installed: $(docker --version)"; return 0
  fi
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
  info "Verifying Docker (please wait)..."
  for i in {1..3}; do
    printf "${C_DIM}  Verifying Docker... (%d/3)${C_R}\r" "$i"
    docker run --rm hello-world &>/dev/null && break
    sleep 5
  done
  docker compose version &>/dev/null && success "Docker $(docker version --format '{{.Server.Version}}') + Compose $(docker compose version --short)" || \
    success "Docker $(docker version --format '{{.Server.Version}}')"
}

setup_docker_network() {
  step "Docker Network: proxy"
  # NEVER remove existing proxy network — other containers may depend on it
  if ! docker network ls --format '{{.Name}}' | grep -qx "proxy"; then
    docker network create proxy 2>/dev/null || true
  fi
  docker network ls --format '{{.Name}}' | grep -qx "proxy" || fatal "Failed to create 'proxy' network"
  success "Network 'proxy' ready"
}

setup_docker_swarm() {
  step "Docker Swarm"
  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  if docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q "active"; then
    success "Swarm already active"
  else
    docker swarm init --advertise-addr "${ip}" || fatal "Swarm init failed"
    success "Swarm initialized"
  fi
}

setup_nginx_proxy_manager() {
  step "Nginx Proxy Manager"
  mkdir -p "$NPM_DATA_DIR" "$NPM_LE_DIR" "$NPM_LOGS_DIR" "$CROWDSEC_DIR"

  cat > "${NPM_DIR}/docker-compose.npm.yml" << 'COMPOSE_NPM'
services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    restart: always
    container_name: npm
    ports:
      - 0.0.0.0:80:80
      - 0.0.0.0:443:443
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

  docker compose -f "${NPM_DIR}/docker-compose.npm.yml" pull
  docker compose -f "${NPM_DIR}/docker-compose.authelia.yml" pull

  info "Starting NPM..."
  docker compose -f "${NPM_DIR}/docker-compose.npm.yml" up -d

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
    printf "${C_DIM}  Waiting for ports... (%d/30)${C_R}\r" "$i"
    [[ $i -eq 30 ]] && {
      echo ""; echo "  Port 80 bound:  $has_80"; echo "  Port 443 bound: $has_443"; echo "  Port 81 bound:  $has_81"; echo ""
      ss -tlnp 2>/dev/null | grep -E ':80 |:443 |:81 ' || true; echo ""
      fatal "NPM failed to bind required ports. Check: docker logs npm"
    }
    sleep 2
  done
  info "Waiting for NPM container (please wait)..."
  for i in $(seq 1 30); do
    printf "${C_DIM}  Waiting for NPM container... (%d/30)${C_R}\r" "$i"
    docker ps --format '{{.Names}}' | grep -qx "npm" && break
    sleep 2
  done

  info "Waiting for NPM admin UI (port 81)..."
  for i in $(seq 1 60); do
    printf "${C_DIM}  Waiting for NPM UI... (%d/60)${C_R}\r" "$i"
    curl -sf --max-time 5 http://127.0.0.1:81/ &>/dev/null && { success "NPM UI responding"; break; }
    [[ $i -eq 60 ]] && warn "NPM UI timed out. Still starting?"
    sleep 2
  done

  info "Waiting for NPM log files..."
  for i in $(seq 1 30); do
    printf "${C_DIM}  Waiting for NPM logs... (%d/30)${C_R}\r" "$i"
    if ls "${NPM_LOGS_DIR}/"*_access.log "${NPM_LOGS_DIR}/"*_error.log &>/dev/null; then
      success "NPM logs present"
      break
    fi
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

  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<VPS_IP>")
  success "NPM deployed: http://${ip}:81"
}

setup_authelia_secrets() {
  step "Authelia Secrets"
  info "Generating Authelia secrets..."
  echo -n "$(openssl rand -hex 32)" > "${AUTHELIA_SECRETS_DIR}/jwt_session"
  echo -n "$(openssl rand -hex 32)" > "${AUTHELIA_SECRETS_DIR}/storage_encryption"
  echo -n "$(openssl rand -hex 32)" > "${AUTHELIA_SECRETS_DIR}/session"
  chmod 600 "${AUTHELIA_SECRETS_DIR}/"*
  success "Authelia secrets generated"
}

setup_authelia_config() {
  step "Authelia Config"
  cat > "${AUTHELIA_CONFIG_DIR}/configuration.yml" << AUTHELIA_CONFIG
###############################################################
#                   Authelia configuration                    #
###############################################################
theme: dark
server:
  address: 'tcp://:9091/'
log:
  level: info
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
    - domain: "dokploy.${DOMAIN}"
      policy: two_factor
session:
  name: authelia_session
  expiration: 3600
  inactivity: 300
  cookies:
    - domain: "${DOMAIN}"
      authelia_url: 'https://authelia.${DOMAIN}'
      default_redirection_url: 'https://auth.${DOMAIN}'
regulation:
  max_retries: 5
  find_time: 2m
  ban_time: 5m
storage:
  local:
    path: /config/db.sqlite3
notifier:
  filesystem:
    filename: /config/notifications.txt
AUTHELIA_CONFIG
  success "Authelia config written"
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
  step "Authelia Users"
  if [[ ! -f "${AUTHELIA_CONFIG_DIR}/users.yml" ]]; then
    cat > "${AUTHELIA_CONFIG_DIR}/users.yml" << 'AUTHELIA_USERS'
users:
  admin:
    disabled: false
    displayname: "Admin User"
    password: ""
    email: admin@${DOMAIN}
    groups:
      - admins
AUTHELIA_USERS
    info "Users file created. Set a password hash manually."
    warn "Run: docker exec authelia authelia crypto hash generate --password 'your-password'"
  else
    info "users.yml already exists, skipping"
  fi
}

setup_dokploy() {
  step "Dokploy"
  info "Installing Dokploy — this takes a few minutes, please wait..."
  curl -fsSL https://dokploy.com/install.sh | sh

  info "Waiting for Dokploy (please wait)..."
  for i in $(seq 1 60); do
    printf "${C_DIM}  Waiting for Dokploy... (%d/60)${C_R}\r" "$i"
    curl -sf --max-time 5 http://127.0.0.1:3000/api/health &>/dev/null && { success "Dokploy responding"; break; }
    [[ $i -eq 60 ]] && warn "Dokploy timed out. Check: docker service logs dokploy"
    sleep 3
  done

  # Stop Dokploy's Traefik so NPM can own 80/443
  docker service scale dokploy-traefik=0 2>/dev/null || true
  docker service rm dokploy-traefik 2>/dev/null || true
  docker service update --network-add proxy dokploy 2>/dev/null || docker network connect proxy dokploy 2>/dev/null || true

  success "Dokploy deployed (UI :3000, Traefik stopped — NPM handles 80/443)"
}

setup_portainer() {
  step "Portainer CE"
  mkdir -p "$PORTAINER_DIR" "$CROWDSEC_DIR"

  cat > "${NPM_DIR}/docker-compose.portainer.yml" << 'COMPOSE_PORTAINER'
services:
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: always
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    networks:
      - proxy
volumes:
  portainer_data:
networks:
  proxy:
    external: true
COMPOSE_PORTAINER

  docker compose -f "${NPM_DIR}/docker-compose.portainer.yml" pull
  docker compose -f "${NPM_DIR}/docker-compose.portainer.yml" up -d

  info "Waiting for Portainer (please wait)..."
  for i in $(seq 1 40); do
    printf "${C_DIM}  Waiting for Portainer... (%d/40)${C_R}\r" "$i"
    docker exec portainer wget -qO- --timeout=5 http://127.0.0.1:9000/api/status &>/dev/null && { success "Portainer responding"; break; }
    [[ $i -eq 40 ]] && warn "Portainer timed out. Check: docker logs portainer"
    sleep 3
  done
  success "Portainer deployed"
}


setup_firewall() {
  step "Firewall Configuration"
  if [[ "$OS_FAMILY" == "debian" ]]; then setup_firewall_debian
  else setup_firewall_rhel; fi
}

setup_firewall_debian() {
  info "Configuring UFW..."
  apt-get install -y -qq ufw

  # CRITICAL: Docker manipulates iptables directly. UFW's DEFAULT_FORWARD_POLICY=DROP
  # blocks all container traffic. MUST set to ACCEPT.
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

  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing

  local ssh_port; ssh_port=$(ss -tlnp 2>/dev/null | grep -m1 ':22 ' | awk '{print $4}' | cut -d: -f2 || echo "22")
  ufw allow "${ssh_port:-22}/tcp" comment 'SSH'
  ufw allow 80/tcp comment 'HTTP (NPM)'
  ufw allow 443/tcp comment 'HTTPS (NPM)'
  ufw allow 81/tcp comment 'NPM Admin (restrict after setup)'
  ufw allow 3000/tcp comment 'Dokploy UI (direct access)'

  ufw --force enable && ufw reload
  success "UFW configured (Docker-compatible FORWARD policy)"
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
  firewall-cmd --permanent --add-port=3000/tcp

  if ! firewall-cmd --get-zones 2>/dev/null | grep -q '\bdocker\b'; then
    firewall-cmd --permanent --new-zone=docker 2>/dev/null || true
  fi
  firewall-cmd --permanent --zone=docker --add-interface=docker0 2>/dev/null || true
  firewall-cmd --permanent --zone=docker --set-target=ACCEPT 2>/dev/null || true
  firewall-cmd --reload
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

print_summary() {
  local elapsed=$(( $(date +%s) - START_TIME ))
  local ip ext_ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "YOUR_VPS_IP")
  ext_ip=$(get_external_ip)
  local fw_cmd; [[ "$OS_FAMILY" == "debian" ]] && fw_cmd="ufw status verbose" || fw_cmd="firewall-cmd --list-all"

  cat << EOF

${C_B}${C_GRN}DEPLOYMENT COMPLETE${C_R}  (${SCRIPT_NAME} v${SCRIPT_VERSION})
${C_B}Duration:${C_R} $(( elapsed / 60 ))m $(( elapsed % 60 ))s
${C_B}Internal:${C_R} ${ip}
${C_B}External:${C_R} ${ext_ip}

${C_B}${C_CYN}-- SERVICES --${C_R}

${C_B}${C_YEL}── Container Summary ────────────────────────────────────────────────${C_R}
${C_B}CONTAINER   ${C_R}  ${C_B}HOSTNAME    ${C_R}  ${C_B}PORTS              ${C_R}  ${C_B}NPM DOMAIN            ${C_R}
${C_DIM}──────────  ───────────  ─────────────────  ──────────────────────${C_R}
npm          npm         80, 443, 81        ${ip}:81 (admin)
dokploy      dokploy     3000               dokploy.${DOMAIN}
portainer    portainer   9000               portainer.${DOMAIN}
crowdsec     crowdsec    8080 (LAPI)        (internal, no proxy needed)
authelia     authelia    9091               auth.${DOMAIN}

  ${C_B}Nginx Proxy Manager${C_R}  ${C_GRN}(MAIN PROXY)${C_R}
    Admin UI:  http://${ip}:81
    HTTP:      http://${ip}:80
    HTTPS:     https://${ip}:443
    Data:      ${NPM_DATA_DIR}
    SSL certs: ${NPM_LE_DIR}
    Logs:      ${NPM_LOGS_DIR}

  ${C_B}Dokploy${C_R}
  Container: dokploy
  Port:      3000 (internal, no host port)
  Network:   proxy
  Note: Dokploy has native 2FA in Settings → Security

${C_B}Docker${C_R}    $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo N/A)
${C_B}Containers${C_R}  npm, dokploy, portainer, crowdsec, authelia (separate compose files)
${C_B}Compose Files${C_R}  docker-compose.npm.yml, docker-compose.crowdsec.yml,
                docker-compose.portainer.yml, docker-compose.authelia.yml
${C_B}Network${C_R}   proxy (bridge)

${C_B}CrowdSec${C_R}  Collections: sshd, nginx-proxy-manager, linux
${C_B}Firewall${C_R}  $(if [[ "$OS_FAMILY" == "debian" ]]; then echo "UFW"; else echo "firewalld"; fi)

${C_B}${C_YEL}Step 1 — NPM Admin${C_R}
  Open:   http://${ip}:81
  Login:  admin@example.com / changeme
  ${C_RED}→ Change password immediately${C_R}

${C_B}${C_YEL}Step 2 — Add Proxy Host in NPM${C_R}
  Dashboards → Proxy Hosts → Add Proxy Host
  ┌──────────────────────────────────────┐
  │ Domain Names:    dokploy.YOURDOMAIN    │
  │ Scheme:          http                │
  │ Forward Host:    dokploy │
  │ Forward Port:    3000      │
  │ Block Exploits:  ON                  │
  └──────────────────────────────────────┘
  Click Save

${C_B}${C_YEL}Step 3 — SSL Certificate${C_R}
  On the same proxy host → SSL tab
  ┌──────────────────────────────────────┐
  │ SSL:             Request a new cert  │
  │ Force SSL:       ON                  │
  │ HTTP/2 Support:  ON                  │
  │ Email:           your-email@domain   │
  │ Agree to TOS:    ON                  │
  └──────────────────────────────────────┘
  Click Save

${C_B}${C_YEL}Step 4 — Secure Admin Port${C_R}
  $(if [[ "$OS_FAMILY" == "debian" ]]; then echo "  ufw delete allow 81/tcp && ufw reload"; else echo "  firewall-cmd --permanent --remove-port=81/tcp && firewall-cmd --reload"; fi)${C_B}Docker${C_R}
    Engine:    $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo N/A)
    Swarm:     $(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo N/A)
    Compose:   $(docker compose version --short 2>/dev/null || echo N/A)

  ${C_B}CrowdSec${C_R}
    Status:    cscli metrics    cscli decisions list

  ${C_B}Firewall${C_R}   $(if [[ "$OS_FAMILY" == "debian" ]]; then echo "UFW"; else echo "firewalld"; fi)

${C_B}${C_YEL}-- INITIAL SETUP --${C_R}

  1. ${C_B}NPM Admin:${C_R}  Open http://${ip}:81  (admin@example.com / changeme)
     ${C_RED}-> Change password immediately.${C_R}

  2. ${C_B}Dokploy:${C_R}    Open http://${ip}:3000
     ${C_RED}${C_B}First user to visit gets ADMIN. Register IMMEDIATELY!${C_R}

  3. ${C_B}Proxy hosts:${C_R} Add in NPM:
     - dokploy.your-domain.com -> http://dokploy:3000
     - portainer.your-domain.com -> http://portainer:9000

  4. ${C_B}SSL:${C_R}         Use NPM's SSL Certificates tab for Let's Encrypt.

  5. ${C_B}Secure 81/3000:${C_R} After setup, restrict direct access:
$(if [[ "$OS_FAMILY" == "debian" ]]; then
  echo "     ufw delete allow 81/tcp && ufw delete allow 3000/tcp && ufw reload"
else
  echo "     firewall-cmd --permanent --remove-port=81/tcp --remove-port=3000/tcp"
  echo "     firewall-cmd --reload"
fi)

${C_B}${C_CYN}-- TROUBLESHOOTING --${C_R}

  NPM:        cd ${NPM_DIR} && docker compose -f docker-compose.npm.yml restart
  CrowdSec:   cd ${NPM_DIR} && docker compose -f docker-compose.crowdsec.yml restart
  Portainer:  cd ${NPM_DIR} && docker compose -f docker-compose.portainer.yml restart
  Dokploy:    docker service ls && docker service logs dokploy
  Portainer:  docker logs -f portainer
  CrowdSec:   cscli metrics    cscli decisions list
  Firewall:   ${fw_cmd}
  Deploy log: ${LOG_FILE}

EOF
  _log "INFO" "=== Deployment completed in $(( elapsed / 60 ))m $(( elapsed % 60 ))s ==="
}


setup_crowdsec() {
  step "CrowdSec (Docker)"

  mkdir -p "$CROWDSEC_DIR"

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

  docker compose -f "${NPM_DIR}/docker-compose.crowdsec.yml" pull
  docker compose -f "${NPM_DIR}/docker-compose.crowdsec.yml" up -d

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
  printf "\n${C_B}${C_CYN}  VPS Deployment — Docker + NPM + Dokploy + Portainer + CrowdSec + Authelia${C_R}\n"
  printf "${C_DIM}  ${SCRIPT_NAME} v${SCRIPT_VERSION}${C_R}\n\n"

  step "Domain Configuration"
  printf "\n${C_B}Enter your root domain${C_R} (e.g., example.com): "
  read -r DOMAIN
  [[ -z "$DOMAIN" ]] && DOMAIN="yourdomain.com"
  DOMAIN=$(echo "$DOMAIN" | sed 's|https\?://||' | sed 's|/.*||' | tr -d ' ')

  preflight_checks
  idempotent_cleanup
  system_update
  install_dependencies
  install_docker
  setup_docker_network
  setup_docker_swarm
  setup_dokploy
  setup_nginx_proxy_manager
  setup_portainer
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
  setup_firewall
  setup_logrotate
  DEPLOY_STATUS="success"
  print_summary
}

main "$@"
