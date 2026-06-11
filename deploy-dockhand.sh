#!/usr/bin/env bash
# Auto-elevate to root if not already running as root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi

# deploy-dockhand.sh -- Docker + NPM + Dockhand + CrowdSec (v4.2.0-oneclick-final)
# One-click VPS deployment. Usage: sudo ./deploy-dockhand.sh
# Dockhand: built-in SSO, MFA, user management + full host file access (read/write)
set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="4.2.0-oneclick-final"
readonly SCRIPT_NAME="deploy-dockhand.sh"
readonly START_TIME=$(date +%s)
readonly STACK_DIR="/opt/dockhand-stack"
readonly NPM_DATA_DIR="${STACK_DIR}/data"
readonly NPM_LE_DIR="${STACK_DIR}/letsencrypt"
readonly NPM_LOGS_DIR="${NPM_DATA_DIR}/logs"
readonly CROWDSEC_DIR="${STACK_DIR}/crowdsec"
readonly DOCKHAND_DATA_DIR="${STACK_DIR}/dockhand-data"
readonly DOMAIN_PERSIST_FILE="/etc/vps-deploy-domain"
readonly LOG_FILE="/var/log/vps-deploy.log"

DOMAIN=""  # Set at runtime via user prompt

# Deployment status tracking for guaranteed completion summary
DEPLOY_STATUS="in_progress"
DEPLOYED_SERVICES=""
CROWDSEC_CHOICE="crowdsec"    # crowdsec | fail2ban

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
error()   { printf "${C_RED}✗${C_R}  %s\n" "$*"; _log "ERROR" "$@"; }
success() { printf "${C_GRN}✔${C_R}  %s\n" "$*"; _log "SUCCESS" "$@"; }
fatal()   { printf "${C_RED}${C_B}FATAL${C_R}${C_RED}: %s${C_R}\n" "$*" >&2; _log "FATAL" "$@"; DEPLOY_STATUS="failed"; exit 1; }
step()    { printf "\n${C_B}${C_CYN}-- %s --${C_R}\n" "$*"; _log "STEP" "$@"; }

# -------------------------------------------------------------------------------
# GUARANTEED COMPLETION SUMMARY � runs on exit regardless of success/failure
# -------------------------------------------------------------------------------
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

  printf "\n"
  if [[ "$DEPLOY_STATUS" == "success" ]]; then
    printf "${C_B}${C_GRN}+------------------------------------------------------------------------------+${C_R}\n"
    printf "${C_B}${C_GRN}�                    ?  DEPLOYMENT COMPLETED SUCCESSFULLY                      �${C_R}\n"
    printf "${C_B}${C_GRN}�------------------------------------------------------------------------------�${C_R}\n"
  else
    printf "${C_B}${C_RED}+------------------------------------------------------------------------------+${C_R}\n"
    printf "${C_B}${C_RED}�                     ?  DEPLOYMENT DID NOT COMPLETE                           �${C_R}\n"
    printf "${C_B}${C_RED}�------------------------------------------------------------------------------�${C_R}\n"
  fi
  printf "${C_B}�  %-72s  �${C_R}\n" "Elapsed:  ${elapsed}s"
  printf "${C_B}�  %-72s  �${C_R}\n" "VPS IP:   $ip"
  printf "${C_B}�  %-72s  �${C_R}\n" "External: $ext_ip"
  printf "${C_B}�  %-72s  �${C_R}\n" "Domain:   ${DOMAIN:-<not set>}"
  printf "${C_B}�------------------------------------------------------------------------------�${C_R}\n"
  printf "${C_B}�  %-72s  �${C_R}\n" "NPM Admin: http://${ip}:81"
  if [[ "$DEPLOY_STATUS" == "success" ]]; then
    printf "${C_B}�  %-72s  �${C_R}\n" "Dockhand:  https://dockhand.${DOMAIN}"
    printf "${C_B}�  %-72s  �${C_R}\n" "           https://dockhand.${DOMAIN} (NPM)"
    [[ "$CROWDSEC_CHOICE" == "crowdsec" ]] && [[ "$(uname -m)" == "x86_64" ]] && printf "${C_B}�  %-72s  �${C_R}\n" "CrowdSec:  http://crowdsec.${DOMAIN}"
    [[ "$CROWDSEC_CHOICE" == "crowdsec" ]] && [[ "$(uname -m)" != "x86_64" ]] && printf "${C_B}�  ${C_YEL}%-72s${C_R}${C_B}  �${C_R}\n" "ARM: CrowdSec CLI-only — see guide below"
    [[ "$CROWDSEC_CHOICE" == "fail2ban" ]] && printf "${C_B}�  ${C_YEL}%-72s${C_R}${C_B}  �${C_R}\n" "Fail2Ban:  Active (ARM) — manage with fail2ban-client"
    printf "${C_B}�  %-72s  �${C_R}\n" "NPM Proxy Forwarding:"
    printf "${C_B}�  %-72s  �${C_R}\n" "  dockhand.${DOMAIN}           -> dockhand:3000"
    [[ "$CROWDSEC_CHOICE" == "crowdsec" ]] && [[ "$(uname -m)" == "x86_64" ]] && printf "${C_B}�  %-72s  �${C_R}\n" "  crowdsec.${DOMAIN}          -> crowdsec-dashboard:3000"
    printf "${C_B}�  %-72s  �${C_R}\n" ""
    printf "${C_B}�  ${C_GRN}%-72s${C_R}${C_B}  �${C_R}\n" "Dockhand has full read/write host file access."
  fi
  printf "${C_B}�  %-72s  �${C_R}\n" "Ports: 80 (HTTP), 443 (HTTPS), 81 (NPM Admin)"
  printf "${C_B}�------------------------------------------------------------------------------�${C_R}\n"
  printf "${C_B}�  %-72s  �${C_R}\n" "Log: $LOG_FILE"
  printf "${C_B}+------------------------------------------------------------------------------+${C_R}\n"
  printf "\n"
  if [[ "$DEPLOY_STATUS" == "success" ]]; then
    printf "${C_B}${C_GRN}Your VPS is ready!${C_R} DNS must point ${C_CYN}*.${DOMAIN} ? ${ext_ip}${C_R}\n\n"
  else
    printf "${C_B}${C_YEL}Deployment failed.${C_R} Check: ${C_CYN}cat $LOG_FILE${C_R}\n\n"
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

  # Remove ALL previously deployed platform data directories
  info "Removing ALL previous platform data..."
  for dir in /opt/npm /opt/casaos /var/lib/casaos /opt/casaos-stack /opt/coolify-stack /opt/cosmos-stack /opt/dockge-stack /opt/dockhand-stack /opt/dokploy-stack /opt/portainer-stack /opt/runtipi-stack /opt/freedombox-stack /opt/yunohost-stack; do
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

  # Immediately recreate the stack directory after cleaning
  mkdir -p "$STACK_DIR" "$NPM_DATA_DIR" "$NPM_LE_DIR" "$NPM_LOGS_DIR" "$CROWDSEC_DIR" "$DOCKHAND_DATA_DIR"
  success "Stack directory recreated: $STACK_DIR"
}

system_update() {
  step "System Update"
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  info "Updating packages � this may take a few minutes, please wait..."
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
  info "Installing required packages � please wait..."
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
  info "Installing Docker CE � this may take a few minutes, please wait..."
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
  for i in {1..3}; do
    printf "\r  ${C_DIM}Verifying Docker... %d/3${C_R}" "$i"
    docker run --rm hello-world &>/dev/null && { printf "\r"; break; }
    [[ $i -eq 3 ]] && { printf "\r"; fatal "Docker verification failed after 3 attempts."; }
    sleep 5
  done
  docker compose version &>/dev/null && success "Docker $(docker version --format '{{.Server.Version}}') + Compose $(docker compose version --short)" || \
    success "Docker $(docker version --format '{{.Server.Version}}')"
}

setup_docker_network() {
  step "Docker Network: proxy"
  if ! docker network ls --format '{{.Name}}' | grep -qx "proxy"; then
    docker network create proxy 2>/dev/null || true
  fi
  docker network ls --format '{{.Name}}' | grep -qx "proxy" || fatal "Failed to create 'proxy' network"
  success "Network 'proxy' ready"
}

get_user_domain() {
  step "Domain Configuration"
  if [[ -f "${DOMAIN_PERSIST_FILE}" ]]; then
    local existing_domain
    existing_domain=$(tr -d '\n' < "${DOMAIN_PERSIST_FILE}" 2>/dev/null || true)
    if [[ -n "$existing_domain" ]]; then
      printf "\n${C_YEL}??  Previous deployment detected with domain: ${C_B}${existing_domain}${C_R}\n"
      printf "${C_YEL}   Press ${C_B}Y${C_R}${C_YEL} + Enter to REUSE this domain${C_R}\n"
      printf "${C_YEL}   Press ${C_B}N${C_R}${C_YEL} + Enter to enter a NEW domain${C_R}\n\n"
      read -rp "Reuse '${existing_domain}'? [Y/n]: " use_existing
      [[ "$use_existing" =~ ^[Nn]$ ]] || { DOMAIN="$existing_domain"; success "Domain set to: $DOMAIN"; return 0; }
      printf "\n${C_CYN}Switching to new domain entry...${C_R}\n"
    fi
  fi
  printf "\n${C_B}Enter your root domain${C_R} (e.g., example.com): "
  read -r DOMAIN
  [[ -z "$DOMAIN" ]] && fatal "Domain is required."
  DOMAIN=$(echo "$DOMAIN" | sed 's|https\?://||' | sed 's|/.*||' | tr -d ' ')
  printf '%s' "$DOMAIN" > "${DOMAIN_PERSIST_FILE}" || warn "Could not persist domain to ${DOMAIN_PERSIST_FILE}"
  success "Domain set to: $DOMAIN"
}

setup_dockhand() {
  step "Dockhand (standalone)"
  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<VPS_IP>")
  mkdir -p "${DOCKHAND_DATA_DIR}"

  cat > "${STACK_DIR}/docker-compose.dockhand.yml" << 'COMPOSE_DOCKHAND'
services:
  dockhand:
    image: fnsys/dockhand:latest
    container_name: dockhand
    hostname: dockhand
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./dockhand-data:/app/data
      - /:/host           # <-- FULL HOST READ-WRITE (not read-only)
    networks:
      - proxy
networks:
  proxy:
    external: true
COMPOSE_DOCKHAND

  info "Pulling Dockhand image..."
  docker compose -f "${STACK_DIR}/docker-compose.dockhand.yml" pull
  docker compose -f "${STACK_DIR}/docker-compose.dockhand.yml" up -d --force-recreate

  info "Waiting for Dockhand to be ready..."
  for i in $(seq 1 30); do
    printf "\r  ${C_DIM}Waiting for Dockhand... %d/30${C_R}" "$i"
    sleep 2
    if docker ps --format '{{.Names}}' | grep -qx "dockhand"; then
        printf "\r"
        success "Dockhand ready"
        break
    fi
    [[ $i -eq 30 ]] && { printf "\r"; warn "Dockhand may still be starting. Check: docker logs dockhand"; }
  done
  printf "\r"
}

setup_stack() {
  step "Deploying NPM and CrowdSec"
  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<VPS_IP>")
  mkdir -p "$NPM_DATA_DIR" "$NPM_LE_DIR" "$NPM_LOGS_DIR" "$CROWDSEC_DIR"
  # Generate CrowdSec LAPI credentials for dashboard (used in both compose and machine registration)
  local CROWDSEC_LOGIN CROWDSEC_PASSWORD BETTER_AUTH_SECRET
  CROWDSEC_LOGIN="dashboard-user-$(openssl rand -hex 4 2>/dev/null || echo "a1b2c3d4")"
  CROWDSEC_PASSWORD="$(openssl rand -base64 24 2>/dev/null || echo "$(date +%s | sha256sum | base64 | head -c 32)")"
  BETTER_AUTH_SECRET="$(openssl rand -base64 32 2>/dev/null || echo "$(date +%s | sha256sum | base64 | head -c 44)")"

  cat > "${STACK_DIR}/docker-compose.npm.yml" << 'COMPOSE_NPM'
services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    restart: always
    container_name: npm
    hostname: npm
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

  {
    echo 'services:'
    echo '  crowdsec:'
    echo '    image: crowdsecurity/crowdsec:latest'
    echo '    container_name: crowdsec'
    echo '    hostname: crowdsec'
    echo '    restart: unless-stopped'
    echo '    ports:'
    echo '      - "127.0.0.1:8080:8080"'
    echo '    volumes:'
    echo '      - ./crowdsec/data:/var/lib/crowdsec/data'
    echo '      - ./crowdsec/config:/etc/crowdsec'
    echo '      - ./data/logs:/npm-logs:ro'
    echo '      - /var/log:/var/log:ro'
    echo '    environment:'
    echo '      - COLLECTIONS=crowdsecurity/sshd crowdsecurity/nginx-proxy-manager crowdsecurity/linux'
    echo '      - TZ=UTC'
    echo '    networks:'
    echo '      - proxy'
    if [[ "$DOCKER_ARCH" == "amd64" ]]; then
      echo ''
      echo '  crowdsec-dashboard:'
      echo '    image: partitio/crowdsec-dashboard:latest'
      echo '    container_name: crowdsec-dashboard'
      echo '    restart: unless-stopped'
      echo '    environment:'
      echo '      - CROWDSEC_API_URL=http://crowdsec:8080'
      echo '      - CROWDSEC_LOGIN='"${CROWDSEC_LOGIN}"''
      echo '      - CROWDSEC_PASSWORD='"${CROWDSEC_PASSWORD}"''
      echo '      - BETTER_AUTH_SECRET='"${BETTER_AUTH_SECRET}"''
      echo '    volumes:'
      echo '      - ./crowdsec/data:/var/lib/crowdsec/data:ro'
      echo '    networks:'
      echo '      - proxy'
    fi
    echo ''
    echo 'networks:'
    echo '  proxy:'
    echo '    external: true'
  } > "${STACK_DIR}/docker-compose.crowdsec.yml"

  info "Pulling images..."
  docker compose -f "${STACK_DIR}/docker-compose.npm.yml" pull
  docker compose -f "${STACK_DIR}/docker-compose.crowdsec.yml" pull

  info "Starting NPM..."
  docker compose -f "${STACK_DIR}/docker-compose.npm.yml" up -d
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
    [[ $i -eq 30 ]] && {
      echo ""; echo "  Port 80 bound:  $has_80"; echo "  Port 443 bound: $has_443"; echo "  Port 81 bound:  $has_81"; echo ""
      ss -tlnp 2>/dev/null | grep -E ':80 |:443 |:81 ' || true; echo ""
      fatal "NPM failed to bind required ports. Check: docker logs npm"
    }
    printf "\r  ${C_DIM}Waiting for NPM ports... %d/30${C_R}" "$i"
    sleep 2
  done
  printf "\r"

  info "Waiting for NPM container..."
  for i in $(seq 1 30); do
    printf "\r  ${C_DIM}Waiting for NPM container... %d/30${C_R}" "$i"
    docker ps --format '{{.Names}}' | grep -qx "npm" && { printf "\r"; success "NPM container running"; break; }
    [[ $i -eq 30 ]] && { printf "\r"; warn "NPM container did not appear within 60s"; }
    sleep 2
  done
  printf "\r"

  info "Waiting for NPM admin UI (:81)..."
  for i in $(seq 1 60); do
    printf "\r  ${C_DIM}Waiting for NPM admin UI... %d/60${C_R}" "$i"
    curl -sf --max-time 5 http://127.0.0.1:81/ &>/dev/null && { printf "\r"; success "NPM UI ready"; break; }
    [[ $i -eq 60 ]] && { printf "\r"; warn "NPM UI timed out (2m)."; }
    sleep 2
  done
  printf "\r"

  info "Waiting for NPM log files..."
  for i in $(seq 1 30); do
    printf "\r  ${C_DIM}Waiting for NPM log files... %d/30${C_R}" "$i"
    if ls "${NPM_LOGS_DIR}/"*_access.log "${NPM_LOGS_DIR}/"*_error.log &>/dev/null; then
      printf "\r"
      success "NPM logs present"
      break
    fi
    if [[ $i -eq 30 ]]; then
      printf "\r"
      warn "NPM logs not found. Creating placeholders."
      touch "${NPM_LOGS_DIR}/fallback_http_access.log" \
            "${NPM_LOGS_DIR}/fallback_http_error.log" \
            "${NPM_LOGS_DIR}/default-host_access.log" \
            "${NPM_LOGS_DIR}/default-host_error.log"
    fi
    sleep 2
  done
  printf "\r"

  info "Starting CrowdSec..."
  docker compose -f "${STACK_DIR}/docker-compose.crowdsec.yml" up -d crowdsec
  info "Waiting for CrowdSec container..."
  for i in $(seq 1 30); do
    docker ps --format '{{.Names}}' | grep -qx "crowdsec" && { success "CrowdSec container running"; break; }
    printf "${C_DIM}  Waiting for CrowdSec container... (%d/30)${C_R}\r" "$i"
    [[ $i -eq 30 ]] && warn "CrowdSec container not found"
    sleep 2
  done
  printf "\n"

  if [[ "$DOCKER_ARCH" == "amd64" ]]; then
    info "Registering CrowdSec LAPI machine for dashboard..."
    docker exec crowdsec cscli machines add "$CROWDSEC_LOGIN" --password "$CROWDSEC_PASSWORD" 2>/dev/null || true
    info "Starting CrowdSec Dashboard..."
    docker compose -f "${STACK_DIR}/docker-compose.crowdsec.yml" up -d crowdsec-dashboard
    info "Waiting for CrowdSec Dashboard..."
    for i in $(seq 1 30); do
      docker ps --format '{{.Names}}' | grep -qx "crowdsec-dashboard" && { success "CrowdSec Dashboard ready"; break; }
      printf "${C_DIM}  Waiting for CrowdSec Dashboard... (%d/30)${C_R}\r" "$i"
      [[ $i -eq 30 ]] && warn "CrowdSec Dashboard timeout"
      sleep 2
    done
    printf "\n"
  fi

  success "NPM: http://${ip}:81"
  success "Dockhand: https://dockhand.${DOMAIN}"
}

# -------------------------------------------------------------------------------
# NPM API automation � secure password & proxy hosts
# -------------------------------------------------------------------------------
NPM_TOKEN=""
NPM_API_BASE="http://127.0.0.1:81/api"

_npm_api() {
  curl -s --max-time 10 "${NPM_API_BASE}${1}" \
    ${2:+-H "Content-Type: application/json"} \
    ${NPM_TOKEN:+-H "Authorization: Bearer ${NPM_TOKEN}"} \
    "${@:3}"
}

npm_change_password() {
  step "Securing NPM admin password"
  local NEW_PASS
  NEW_PASS=$(openssl rand -base64 18 | tr -d '+/=' | head -c 24)
  local JSON
  JSON=$(printf '{"identity":"admin@example.com","secret":"changeme"}')
  local LOGIN
  LOGIN=$(_npm_api "/tokens" "json" -d "$JSON" 2>/dev/null)
  NPM_TOKEN=$(echo "$LOGIN" | jq -r '.token // empty')
  if [[ -z "$NPM_TOKEN" ]]; then
    warn "Could not get NPM token � skipping automated NPM setup"
    return 1
  fi

  JSON=$(printf '{"type":"password","current":"changeme","secret":"%s"}' "$NEW_PASS")
  _npm_api "/users/1/auth" "json" -X PUT -d "$JSON" >/dev/null 2>&1
  # Re-authenticate with new password
  JSON=$(printf '{"identity":"admin@example.com","secret":"%s"}' "$NEW_PASS")
  LOGIN=$(_npm_api "/tokens" "json" -d "$JSON" 2>/dev/null)
  NPM_TOKEN=$(echo "$LOGIN" | jq -r '.token // empty')
  if [[ -n "$NPM_TOKEN" ]]; then
    echo "$NEW_PASS" > "${STACK_DIR}/.npm_admin_password"
    success "NPM admin password changed � saved to ${STACK_DIR}/.npm_admin_password"
    return 0
  else
    warn "NPM password change failed � manual intervention required"
    return 1
  fi
}

npm_create_proxy_host() {
  local DOMAIN_NAME="$1"
  local FWD_HOST="$2"
  local FWD_PORT="$3"
  local WS="${4:-true}"
  local SSL="${5:-true}"

  local JSON
  JSON=$(jq -nc --arg domain "$DOMAIN_NAME" --arg fwd_host "$FWD_HOST" --argjson fwd_port "$FWD_PORT" \
    --argjson ws "$WS" --argjson ssl "$SSL" \
    '{
      domain_names: [$domain],
      forward_scheme: "http",
      forward_host: $fwd_host,
      forward_port: $fwd_port,
      access_list_id: 0,
      certificate_id: 0,
      ssl_forced: $ssl,
      caching_enabled: true,
      block_exploits: true,
      allow_websocket_upgrade: $ws,
      http2_support: true,
      hsts_enabled: true,
      hsts_subdomains: true,
      advanced_config: ""
    }')

  local RESP
  RESP=$(_npm_api "/nginx/proxy-hosts" "json" -X POST -d "$JSON")
  local ID
  ID=$(echo "$RESP" | jq -r '.id // empty')
  if [[ -n "$ID" ]]; then
    success "Created proxy host: ${DOMAIN_NAME} ? ${FWD_HOST}:${FWD_PORT}"
    echo "$ID"
  else
    warn "Failed to create proxy host for ${DOMAIN_NAME}"
    return 1
  fi
}

npm_request_ssl() {
  local HOST_ID="$1"
  local DOMAIN_NAME="$2"
  local EMAIL="${3:-admin@${DOMAIN}}"
  local JSON
  JSON=$(jq -nc --arg email "$EMAIL" --arg domain "$DOMAIN_NAME" '{
    provider: "letsencrypt",
    domain_names: [$domain],
    letsencrypt_email: $email,
    letsencrypt_agree: true
  }')
  RESP=$(_npm_api "/nginx/proxy-hosts/${HOST_ID}/certificates" "json" -X POST -d "$JSON")
  local SUCCESS
  SUCCESS=$(echo "$RESP" | jq -r '.id // empty')
  if [[ -n "$SUCCESS" ]]; then
    success "SSL certificate requested for proxy host ID ${HOST_ID}"
  else
    warn "SSL request may have failed for proxy host ID ${HOST_ID}"
  fi
}

automate_npm() {
  step "Automating NPM setup (proxy hosts + SSL)"

  if ! npm_change_password; then
    warn "Could not change NPM password; continuing with manual setup needed"
    return
  fi

  # Create proxy host for Dockhand
  local dockhand_id
  dockhand_id=$(npm_create_proxy_host "dockhand.${DOMAIN}" "dockhand" 3000 true true)
  if [[ -n "$dockhand_id" ]]; then
    npm_request_ssl "$dockhand_id" "dockhand.${DOMAIN}"
  fi

  # Create proxy host for CrowdSec dashboard (if on amd64)
  if [[ "$DOCKER_ARCH" == "amd64" ]]; then
    local crowdsec_id
    crowdsec_id=$(npm_create_proxy_host "crowdsec.${DOMAIN}" "crowdsec-dashboard" 3000 false true)
    if [[ -n "$crowdsec_id" ]]; then
      npm_request_ssl "$crowdsec_id" "crowdsec.${DOMAIN}"
    fi
  fi

  success "NPM automation completed"
}

# -------------------------------------------------------------------------------
# Firewall, logrotate, CrowdSec setup
# -------------------------------------------------------------------------------
setup_firewall() {
  step "Firewall"
  info "Configuring firewall � please wait..."
  if [[ "$OS_FAMILY" == "debian" ]]; then setup_firewall_debian
  else setup_firewall_rhel; fi
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

setup_fail2ban() {
  step "Fail2Ban (ARM alternative to CrowdSec)"
  info "Installing Fail2Ban..."
  if [[ "$OS_FAMILY" == "debian" ]]; then
    apt-get install -y -qq fail2ban
  else
    local pkg="yum"; command -v dnf &>/dev/null && pkg="dnf"
    $pkg install -y -q fail2ban
  fi
  mkdir -p /etc/fail2ban/jail.d /etc/fail2ban/filter.d
  cat > /etc/fail2ban/filter.d/nginx-proxy-manager.conf << 'FILTER'
[Definition]
failregex = ^<HOST> - - \[.*\] ".*" 4\d\d .*$
ignoreregex =
FILTER
  cat > /etc/fail2ban/jail.d/nginx-proxy-manager.conf << JAIL
[nginx-proxy-manager]
enabled = true
port    = http,https
filter  = nginx-proxy-manager
logpath = ${NPM_LOGS_DIR}/*_access.log
maxretry = 5
bantime  = 3600
findtime = 600
JAIL
  systemctl enable fail2ban
  systemctl restart fail2ban
  success "Fail2Ban installed with NPM jail"
  DEPLOYED_SERVICES+=",fail2ban"
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
  api_key=$(docker exec crowdsec cscli bouncers add npm-bouncer 2>/dev/null | grep -oE '[a-f0-9]{32,}' | head -1 || true)
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

# -------------------------------------------------------------------------------
# Final summary
# -------------------------------------------------------------------------------
print_summary() {
  local elapsed=$(( $(date +%s) - START_TIME ))
  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "YOUR_VPS_IP")
  local ext_ip; ext_ip=$(get_external_ip)
  local fw_cmd; [[ "$OS_FAMILY" == "debian" ]] && fw_cmd="ufw status verbose" || fw_cmd="firewall-cmd --list-all"
  local npm_password="<see ${STACK_DIR}/.npm_admin_password>"
  if [[ -f "${STACK_DIR}/.npm_admin_password" ]]; then
    npm_password=$(cat "${STACK_DIR}/.npm_admin_password")
  fi

  printf "\n"
  printf "${C_B}${C_GRN}+------------------------------------------------------------------------------+${C_R}\n"
  printf "${C_B}${C_GRN}�                     ??  DEPLOYMENT COMPLETE                                  �${C_R}\n"
  printf "${C_B}${C_GRN}�------------------------------------------------------------------------------�${C_R}\n"
  printf "${C_B}�  ${C_CYN}${SCRIPT_NAME} v${SCRIPT_VERSION}${C_R}${C_B}                                                      �${C_R}\n"
  printf "${C_B}�  Elapsed: ${C_CYN}%dm %ds${C_R}${C_B}                                                     �${C_R}\n" $(( elapsed / 60 )) $(( elapsed % 60 ))
  printf "${C_B}+------------------------------------------------------------------------------+${C_R}\n"

  local crowdsec_display="crowdsec    crowdsec     8080 (LAPI)        crowdsec.${DOMAIN} (amd64 only)"
  [[ "$CROWDSEC_CHOICE" == "fail2ban" ]] && crowdsec_display="fail2ban   fail2ban   —                  (internal, no proxy needed)"
  local dns_crowdsec=""
  local proxy_crowdsec=""
  if [[ "$CROWDSEC_CHOICE" == "crowdsec" ]] && [[ "$(uname -m)" == "x86_64" ]]; then
    dns_crowdsec="  A  crowdsec.${DOMAIN}   → ${ip}  (CrowdSec Dashboard)"
    proxy_crowdsec=$(cat << 'CROWDPROXY'

    ${C_B}CrowdSec Dashboard:${C_R}
    ┌────────────────────────────────────────┐
    │ Domain Names:    crowdsec.${DOMAIN}           │
    │ Scheme:          http                         │
    │ Forward Host:    crowdsec-dashboard           │
    │ Forward Port:    3000                         │
    │ Block Exploits:  ON                           │
    │ Access List:     Publicly Accessible          │
    └─────────────────────────────────────────┘
    Save → SSL tab → Request cert → Force SSL ON
    → Dashboard is read-only — no Authelia 2FA needed
CROWDPROXY
)
  elif [[ "$CROWDSEC_CHOICE" == "crowdsec" ]] && [[ "$(uname -m)" != "x86_64" ]]; then
    dns_crowdsec="  A  crowdsec.${DOMAIN}   → ${ip}  (not used — CLI-only)"
    proxy_crowdsec=$(cat << 'CROWDSECCLI'

    ${C_B}CrowdSec (CLI-only, ARM):${C_R}
    ┌─────────────────────────────────────────┐
    │ No dashboard — manage CrowdSec via CLI         │
    │ Check alerts:   cscli alerts list              │
    │ Check bouncers: cscli bouncers list            │
    │ Check metrics:  cscli metrics                  │
    │ Decisions:      cscli decisions list           │
    │ Logs:           sudo journalctl -u crowdsec -f │
    └────────────────────────────────────────┘
CROWDSECCLI
)
  else
    dns_crowdsec="  A  crowdsec.${DOMAIN}   → ${ip}  (not used with Fail2Ban)"
    proxy_crowdsec=$(cat << 'FAIL2BANPROXY'

    ${C_B}Fail2Ban (ARM):${C_R}
    ┌─────────────────────────────────────────┐
    │ No proxy host needed — Fail2Ban runs on host   │
    │ Manage with: fail2ban-client status nginx-proxy-manager
    │ Ban IP: fail2ban-client set nginx-proxy-manager banip <IP>
    │ Unban IP: fail2ban-client set nginx-proxy-manager unbanip <IP>
    └────────────────────────────────────────┘
FAIL2BANPROXY
)
  fi

  cat << EOF

${C_B}Stack Directory${C_R}    ${STACK_DIR}

${C_B}${C_GRN}── NPM Proxy Forwarding ──────────────────────────────────────${C_R}
${C_B}Domain${C_R}                     ${C_B}Forward to${C_R}
${C_DIM}──────────────────────────  ──────────────────────────${C_R}
dockhand.${DOMAIN}           → dockhand:3000
$(if [[ "$CROWDSEC_CHOICE" == "crowdsec" ]] && [[ "$(uname -m)" == "x86_64" ]]; then echo "crowdsec.${DOMAIN}         → crowdsec-dashboard:3000"; fi)
$(if [[ "$CROWDSEC_CHOICE" == "fail2ban" ]]; then echo "# Fail2Ban active — no proxy host needed"; fi)

${C_B}Nginx Proxy Manager${C_R}
  Admin:   http://${ip}:81
  Login:   admin@example.com
  Password:${C_YEL} ${npm_password}${C_R}
  HTTP:    http://${ip}:80
  HTTPS:   https://${ip}:443
  Ext IP:  ${ext_ip}
  Data:    ${NPM_DATA_DIR}
  SSL:     ${NPM_LE_DIR}
  Logs:    ${NPM_LOGS_DIR}

${C_B}Dockhand${C_R}
  URL:      https://dockhand.${DOMAIN}
  Direct:   https://dockhand.${DOMAIN}
  Container: dockhand
  Network:   proxy
  Data:      ${DOCKHAND_DATA_DIR}
  Auth:      Built-in SSO, MFA, user management (setup wizard on first visit)
  Host Files: FULL READ/WRITE access under /host

${proxy_crowdsec}
${C_B}Firewall${C_R}  $(if [[ "$OS_FAMILY" == "debian" ]]; then echo "UFW"; else echo "firewalld"; fi)

${C_B}Docker${C_R}    $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo N/A)
${C_B}Containers${C_R}  npm, dockhand, ${CROWDSEC_CHOICE}
${C_B}Network${C_R}   proxy (bridge)

${C_B}${C_YEL}Next Steps (already done automatically):${C_R}
  ? Proxy hosts for Dockhand created
  ? Let's Encrypt SSL certificates requested (may take a moment to issue)
  ? NPM admin password securely changed
  ? Dockhand has full read/write access to the host filesystem

${C_B}Access:${C_R}
  - Dockhand:   https://dockhand.${DOMAIN}
  - NPM Admin:  http://${ip}:81   (use password above)

${C_B}Troubleshooting:${C_R}
  Logs:    docker logs -f npm    docker logs -f dockhand
  Restart: cd ${STACK_DIR} && docker compose -f docker-compose.*.yml restart
  FW:      ${fw_cmd}
  Log:     ${LOG_FILE}
EOF
  _log "INFO" "=== Deployment completed in $(( elapsed / 60 ))m $(( elapsed % 60 ))s ==="
}

main() {
  printf "\n${C_B}${C_CYN}VPS Deployment -- Docker + NPM + Dockhand + CrowdSec${C_R}\n"
  printf "${C_DIM}${SCRIPT_NAME} v${SCRIPT_VERSION}${C_R}\n\n"
  preflight_checks
  idempotent_cleanup
  system_update
  install_dependencies
  install_docker
  setup_docker_network
  get_user_domain
  setup_dockhand
  setup_stack
  setup_firewall
  if [[ "$DOCKER_ARCH" == "amd64" ]]; then
    setup_crowdsec
  else
    printf "\n${C_YEL}ARM architecture detected -- CrowdSec dashboard not available.${C_R}\n"
    printf "${C_B}Options:${C_R}\n"
    printf "  ${C_CYN}1)${C_R} CrowdSec (CLI-only, no dashboard)\n"
    printf "  ${C_CYN}2)${C_R} Fail2Ban (traditional, no dashboard needed)\n"
    printf "${C_B}Choice [1/2]:${C_R} "
    read -r arm_choice
    case "$arm_choice" in
      2) setup_fail2ban; CROWDSEC_CHOICE="fail2ban" ;;
      *) setup_crowdsec ;;
    esac
  fi
  setup_logrotate
  automate_npm
  DEPLOY_STATUS="success"
  DEPLOYED_SERVICES="npm,dockhand,${CROWDSEC_CHOICE},firewall"
  print_summary
}

main "$@"