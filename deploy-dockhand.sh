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

readonly SCRIPT_VERSION="4.5.0-hardened"
readonly SCRIPT_NAME="deploy-dockhand.sh"
readonly START_TIME=$(date +%s)
readonly STACK_DIR="/opt/dockhand-stack"
readonly NPM_DATA_DIR="${STACK_DIR}/data"
readonly NPM_LE_DIR="${STACK_DIR}/letsencrypt"
readonly NPM_LOGS_DIR="${NPM_DATA_DIR}/logs"
readonly CROWDSEC_DIR="${STACK_DIR}/crowdsec"
readonly DOCKHAND_DATA_DIR="${STACK_DIR}/dockhand-data"
readonly AUTHELIA_DIR="${STACK_DIR}/authelia"
readonly AUTHELIA_CONFIG_DIR="${AUTHELIA_DIR}/config"
readonly AUTHELIA_SECRETS_DIR="${AUTHELIA_DIR}/secrets"
readonly AUTHELIA_SNIPPETS_DIR="${AUTHELIA_DIR}/snippets"
readonly DOMAIN_PERSIST_FILE="/etc/vps-deploy-domain"
readonly LOG_FILE="/var/log/vps-deploy.log"

DOMAIN=""  # Set at runtime via user prompt

# Deployment status tracking for guaranteed completion summary
DEPLOY_STATUS="in_progress"
# Colors (TTY only)
if [[ -t 1 ]]; then
  C_R='\033[0m'; C_B='\033[1m'; C_RED='\033[0;31m'; C_GRN='\033[0;32m'
  C_YEL='\033[0;33m'; C_BLU='\033[0;34m'; C_CYN='\033[0;36m'; C_DIM='\033[2m'
else
  C_R=''; C_B=''; C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_CYN=''; C_DIM=''
fi

_ts() { date '+%Y-%m-%d %H:%M:%S'; }
_log() { printf "[%s] [%-5s] %s\n" "$(_ts)" "$1" "${*:2}" >> "$LOG_FILE" 2>/dev/null || true; }
info()    { printf "${C_BLU}?${C_R}  %s\n" "$*" >&2; _log "INFO" "$@"; }
warn()    { printf "${C_YEL}?${C_R}  %s\n" "$*" >&2; _log "WARN" "$@"; }
error()   { printf "${C_RED}?${C_R}  %s\n" "$*" >&2; _log "ERROR" "$@"; }
success() { printf "${C_GRN}?${C_R}  %s\n" "$*" >&2; _log "SUCCESS" "$@"; }
fatal()   { printf "${C_RED}${C_B}FATAL${C_R}${C_RED}: %s${C_R}\n" "$*" >&2; _log "FATAL" "$@"; DEPLOY_STATUS="failed"; exit 1; }
step()    { printf "\n${C_B}${C_CYN}-- %s --${C_R}\n" "$*" >&2; _log "STEP" "$@"; }

rand_secret() {
  openssl rand -base64 32 2>/dev/null || head -c 32 /dev/urandom | base64
}
rand_password() {
  local len="${1:-24}"
  (openssl rand -base64 48 2>/dev/null || head -c 48 /dev/urandom | base64) \
    | tr -d '+/=\n' | head -c "$len"
}

detect_ssh_port() {
  local p=""
  p=$(ss -tlnpH 2>/dev/null | awk '/sshd/ { n=split($4,a,":"); print a[n]; exit }')
  if [[ -z "$p" ]]; then
    p=$(awk '/^[Pp]ort[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)
  fi
  echo "${p:-22}"
}

_read_cred() { [[ -f "$1" ]] && tr -d '\n' < "$1" 2>/dev/null || echo "<unknown>"; }

# -------------------------------------------------------------------------------
# GUARANTEED COMPLETION SUMMARY ? runs on exit regardless of success/failure
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
  local authelia_pass npm_pass mb_pass
  authelia_pass=$(_read_cred "${AUTHELIA_DIR}/.default_password")
  npm_pass=$(_read_cred "${STACK_DIR}/.npm_admin_password")
  mb_pass=$(_read_cred "${STACK_DIR}/.metabase_password")

  printf "\n"
  if [[ "$DEPLOY_STATUS" == "success" ]]; then
    printf "${C_B}${C_GRN}+------------------------------------------------------------------------------+${C_R}\n"
    printf "${C_B}${C_GRN}?                    ?  DEPLOYMENT COMPLETED SUCCESSFULLY                      ?${C_R}\n"
    printf "${C_B}${C_GRN}?------------------------------------------------------------------------------?${C_R}\n"
  else
    printf "${C_B}${C_RED}+------------------------------------------------------------------------------+${C_R}\n"
    printf "${C_B}${C_RED}?                     ?  DEPLOYMENT DID NOT COMPLETE                           ?${C_R}\n"
    printf "${C_B}${C_RED}?------------------------------------------------------------------------------?${C_R}\n"
  fi
  printf "${C_B}?  %-72s  ?${C_R}\n" "Elapsed:  ${elapsed}s"
  printf "${C_B}?  %-72s  ?${C_R}\n" "VPS IP:   $ip"
  printf "${C_B}?  %-72s  ?${C_R}\n" "External: $ext_ip"
  printf "${C_B}?  %-72s  ?${C_R}\n" "Domain:   ${DOMAIN:-<not set>}"
  printf "${C_B}?------------------------------------------------------------------------------?${C_R}\n"
  printf "${C_B}?  %-72s  ?${C_R}\n" "NPM Admin:     http://${ip}:81"
  printf "${C_B}?  %-72s  ?${C_R}\n" "NPM Login:     admin@example.com / ${npm_pass}"
  if [[ "$DEPLOY_STATUS" == "success" ]]; then
    printf "${C_B}?  %-72s  ?${C_R}\n" "Dockhand:      https://dockhand.${DOMAIN}"
    printf "${C_B}?  %-72s  ?${C_R}\n" "Authelia:      https://authelia.${DOMAIN}"
    printf "${C_B}?  %-72s  ?${C_R}\n" "CrowdSec:      https://crowdsec.${DOMAIN}"
    printf "${C_B}?  %-72s  ?${C_R}\n" "  Login:       crowdsec@crowdsec.net"
    printf "${C_B}?  %-72s  ?${C_R}\n" "  Pass:        ${mb_pass}"
    printf "${C_B}?------------------------------------------------------------------------------?${C_R}\n"
    printf "${C_B}?  %-72s  ?${C_R}\n" "NPM Proxy Forwarding:"
    printf "${C_B}?  %-72s  ?${C_R}\n" "  dockhand.${DOMAIN}           -> dockhand:3000"
    printf "${C_B}?  %-72s  ?${C_R}\n" "  authelia.${DOMAIN}           -> authelia:9091"
    printf "${C_B}?  %-72s  ?${C_R}\n" "  crowdsec.${DOMAIN}          -> crowdsec-dashboard:3000"
    printf "${C_B}?  %-72s  ?${C_R}\n" ""
    printf "${C_B}?  ${C_YEL}%-72s${C_R}${C_B}  ?${C_R}\n" "Authelia Username: admin"
    printf "${C_B}?  ${C_YEL}%-72s${C_R}${C_B}  ?${C_R}\n" "Authelia Password: $authelia_pass"
    printf "${C_B}?  ${C_RED}%-72s${C_R}${C_B}  ?${C_R}\n" "Change this password immediately after first login!"
    printf "${C_B}?  %-72s  ?${C_R}\n" ""
    printf "${C_B}?  ${C_YEL}%-72s${C_R}${C_B}  ?${C_R}\n" "-- Verification Codes --"
    printf "${C_B}?  %-72s  ?${C_R}\n" "Authelia requires a code to change password or add 2FA."
    printf "${C_B}?  %-72s  ?${C_R}\n" "The code appears AFTER you request it in the Authelia UI."
    printf "${C_B}?  %-72s  ?${C_R}\n" "Then run:"
    printf "${C_B}?  ${C_CYN}%-72s${C_R}${C_B}  ?${C_R}\n" "sudo docker exec authelia cat /config/notifications.txt"
    printf "${C_B}?  %-72s  ?${C_R}\n" ""
  fi
  printf "${C_B}?  %-72s  ?${C_R}\n" "Ports: 80 (HTTP), 443 (HTTPS), 81 (NPM Admin)"
  printf "${C_B}?------------------------------------------------------------------------------?${C_R}\n"
  printf "${C_B}?  %-72s  ?${C_R}\n" "Log: $LOG_FILE"
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
  if [[ "${FORCE_CLEANUP:-0}" != "1" ]]; then
    warn "WARNING: This will STOP and DELETE ALL Docker containers, volumes, and platform data."
    printf "Continue? [y/N] "
    read -r _confirm
    if [[ ! "$_confirm" =~ ^[Yy]([Ee][Ss])?$ ]]; then
      info "Cleanup skipped. Set FORCE_CLEANUP=1 to bypass this prompt."
      return 0
    fi
  fi
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
  info "Updating packages ? this may take a few minutes, please wait..."
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
  info "Installing required packages ? please wait..."
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
  info "Installing Docker CE ? this may take a few minutes, please wait..."
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

  cat > "${STACK_DIR}/docker-compose.authelia.yml" << 'COMPOSE_AUTHELIA'
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
      - AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET_FILE=/config/secrets/jwt_reset
      - AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE=/config/secrets/storage_encryption
      - AUTHELIA_SESSION_SECRET_FILE=/config/secrets/session
      - TZ=America/New_York
    networks:
      - proxy
networks:
  proxy:
    external: true
COMPOSE_AUTHELIA

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
    echo ''
    echo '  crowdsec-dashboard:'
    echo '    image: metabase/metabase:latest'
    echo '    container_name: crowdsec-dashboard'
    echo '    restart: unless-stopped'
    echo '    volumes:'
    echo '      - ./crowdsec/data/crowdsec.db:/metabase-data/crowdsec.db:ro'
    echo '      - ./crowdsec/metabase.db.mv.db:/app/metabase.db.mv.db'
    echo '    environment:'
    echo '      - MB_ADMIN_EMAIL=crowdsec@crowdsec.net'
    echo '      - MB_ADMIN_PASSWORD=!!Cr0wdS3c_M3t4b4s3??'
    echo '    networks:'
    echo '      - proxy'
    echo ''
    echo 'networks:'
    echo '  proxy:'
    echo '    external: true'
  } > "${STACK_DIR}/docker-compose.crowdsec.yml"

  if command -v curl &>/dev/null; then
    DL_CMD="curl -sL -o"
  elif command -v wget &>/dev/null; then
    DL_CMD="wget -qO"
  fi
  if [ ! -f "$CROWDSEC_DIR/metabase.db.mv.db" ] && [ -n "$DL_CMD" ]; then
    $DL_CMD /tmp/metabase_sqlite.zip https://crowdsec-statics-assets.s3-eu-west-1.amazonaws.com/metabase_sqlite.zip
    command -v unzip &>/dev/null && unzip -o /tmp/metabase_sqlite.zip -d "$CROWDSEC_DIR" && rm -f /tmp/metabase_sqlite.zip
    chown 1000:1000 "$CROWDSEC_DIR/metabase.db.mv.db" 2>/dev/null || true
  else
    [ ! -f "$CROWDSEC_DIR/metabase.db.mv.db" ] && warn "Metabase template not found ? dashboard may not have pre-loaded collections"
  fi

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

  info "Deploying Authelia..."
  mkdir -p "$AUTHELIA_DIR" "$AUTHELIA_CONFIG_DIR" "$AUTHELIA_SECRETS_DIR" "$AUTHELIA_SNIPPETS_DIR"
  setup_authelia_secrets
  setup_authelia_config
  setup_authelia_snippets
  docker compose -f "${STACK_DIR}/docker-compose.authelia.yml" pull
  docker compose -f "${STACK_DIR}/docker-compose.authelia.yml" up -d
  info "Waiting for Authelia..."
  for i in $(seq 1 30); do
    docker ps --format '{{.Names}}' | grep -qx "authelia" && { success "Authelia ready"; break; }
    printf "${C_DIM}  Waiting for Authelia container... (%d/30)${C_R}\r" "$i"
    [[ $i -eq 30 ]] && warn "Authelia container not found"
    sleep 2
  done
  printf "\n"
  setup_authelia_users

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

  success "NPM: http://${ip}:81"
  success "Dockhand: https://dockhand.${DOMAIN}"
}

# -------------------------------------------------------------------------------
# NPM API automation ? secure password & proxy hosts
# -------------------------------------------------------------------------------
NPM_TOKEN=""
NPM_API_BASE="http://127.0.0.1:81/api"

_npm_api() {
  local path="$1"; shift
  local args=(-s --max-time 60 -H "Content-Type: application/json")
  [[ -n "$NPM_TOKEN" ]] && args+=(-H "Authorization: Bearer ${NPM_TOKEN}")
  curl "${args[@]}" "${NPM_API_BASE}${path}" "$@"
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
    warn "Could not get NPM token ? skipping automated NPM setup"
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
    success "NPM admin password changed ? saved to ${STACK_DIR}/.npm_admin_password"
    return 0
  else
    warn "NPM password change failed ? manual intervention required"
    return 1
  fi
}

npm_create_proxy_host() {
  local DOMAIN_NAME="$1"
  local FWD_HOST="$2"
  local FWD_PORT="$3"
  local WS="${4:-true}"
  local ADVANCED_CONFIG="${5:-}"

  local JSON
  JSON=$(jq -nc --arg domain "$DOMAIN_NAME" --arg fwd_host "$FWD_HOST" --argjson fwd_port "$FWD_PORT" \
    --argjson ws "$WS" --arg adv "$ADVANCED_CONFIG" \
    '{
      domain_names: [$domain],
      forward_scheme: "http",
      forward_host: $fwd_host,
      forward_port: $fwd_port,
      access_list_id: 0,
      certificate_id: 0,
      ssl_forced: false,
      caching_enabled: false,
      block_exploits: true,
      allow_websocket_upgrade: $ws,
      http2_support: false,
      hsts_enabled: false,
      hsts_subdomains: false,
      advanced_config: $adv
    }')

  local RESP ID
  RESP=$(_npm_api "/nginx/proxy-hosts" -X POST -d "$JSON")
  ID=$(echo "$RESP" | jq -r '.id // empty')
  if [[ -n "$ID" ]]; then
    success "Created proxy host: ${DOMAIN_NAME} -> ${FWD_HOST}:${FWD_PORT}"
    echo "$ID"
  else
    warn "Failed to create proxy host for ${DOMAIN_NAME}: $(echo "$RESP" | jq -r '.error.message // .message // "unknown error"' 2>/dev/null)"
    return 1
  fi
}

npm_enable_ssl() {
  local HOST_ID="$1"
  local DOMAIN_NAME="$2"
  local EMAIL="${3:-admin@${DOMAIN}}"
  local JSON RESP CERT_ID

  JSON=$(jq -nc --arg email "$EMAIL" --arg domain "$DOMAIN_NAME" '{
    provider: "letsencrypt",
    nice_name: $domain,
    domain_names: [$domain],
    meta: { letsencrypt_email: $email, letsencrypt_agree: true, dns_challenge: false }
  }')
  info "Requesting Let's Encrypt certificate for ${DOMAIN_NAME} (can take up to 2 minutes)..."
  RESP=$(_npm_api "/nginx/certificates" --max-time 180 -X POST -d "$JSON") || true
  CERT_ID=$(echo "$RESP" | jq -r '.id // empty')
  if [[ -z "$CERT_ID" ]]; then
    warn "Certificate issuance failed for ${DOMAIN_NAME} (is DNS pointed at this server yet?). Host stays HTTP-only; add SSL in the NPM UI once DNS resolves."
    return 1
  fi

  JSON=$(jq -nc --argjson cert "$CERT_ID" '{
    certificate_id: $cert,
    ssl_forced: true,
    hsts_enabled: true,
    hsts_subdomains: false,
    http2_support: true
  }')
  RESP=$(_npm_api "/nginx/proxy-hosts/${HOST_ID}" -X PUT -d "$JSON") || true
  if [[ -n "$(echo "$RESP" | jq -r '.id // empty')" ]]; then
    success "SSL enabled + forced for ${DOMAIN_NAME} (cert id ${CERT_ID})"
  else
    warn "Could not attach certificate ${CERT_ID} to host ${HOST_ID} - attach it manually in NPM UI"
  fi
}

# -------------------------------------------------------------------------------
# Authelia SSO/MFA setup
# -------------------------------------------------------------------------------
setup_authelia_secrets() {
  step "Authelia Secrets"
  mkdir -p "$AUTHELIA_SECRETS_DIR"
  local jwt_reset storage_encryption session
  jwt_reset=$(openssl rand -base64 32 2>/dev/null || echo "$(date +%s | sha256sum | base64 | head -c 44)")
  storage_encryption=$(openssl rand -base64 32 2>/dev/null || echo "$(date +%s | sha256sum | base64 | head -c 44)")
  session=$(openssl rand -base64 32 2>/dev/null || echo "$(date +%s | sha256sum | base64 | head -c 44)")
  printf '%s' "$jwt_reset" > "${AUTHELIA_SECRETS_DIR}/jwt_reset"
  printf '%s' "$storage_encryption" > "${AUTHELIA_SECRETS_DIR}/storage_encryption"
  printf '%s' "$session" > "${AUTHELIA_SECRETS_DIR}/session"
  chmod 600 "${AUTHELIA_SECRETS_DIR}/"*
  chown -R 1001:1001 "$AUTHELIA_SECRETS_DIR" 2>/dev/null || true
  success "Authelia secrets generated: $AUTHELIA_SECRETS_DIR"
}

setup_authelia_config() {
  step "Authelia Configuration"
  mkdir -p "$AUTHELIA_CONFIG_DIR"
  cat > "${AUTHELIA_CONFIG_DIR}/configuration.yml" << AUTHELIA_CONF
server:
  address: 'tcp://:9091/'
log:
  level: info
totp:
  issuer: authelia.${DOMAIN}
authentication_backend:
  file:
    path: /config/users.yml
access_control:
  default_policy: deny
  rules:
    - domain: "authelia.${DOMAIN}"
      policy: bypass
    - domain: "crowdsec.${DOMAIN}"
      policy: bypass   # Metabase has its own login
    - domain: "*.${DOMAIN}"
      policy: two_factor   # wildcard protects ALL other subdomains
session:
  name: authelia_session
  expiration: 1h
  inactivity: 5m
  remember_me: 1M
  cookies:
    - domain: "${DOMAIN}"
      authelia_url: "https://authelia.${DOMAIN}"
      default_redirection_url: "https://dockhand.${DOMAIN}"
regulation:
  max_retries: 5
  find_time: 2m
  ban_time: 10m
storage:
  local:
    path: /config/db.sqlite3
notifier:
  filesystem:
    filename: /config/notifications.txt
AUTHELIA_CONF
  info "users.yml will be created after authelia container starts"
  chown -R 1001:1001 "$AUTHELIA_CONFIG_DIR" 2>/dev/null || true
  success "Authelia configuration created"
}

setup_authelia_snippets() {
  step "Authelia NPM Snippets"
  mkdir -p "$AUTHELIA_SNIPPETS_DIR"

  cat > "${AUTHELIA_SNIPPETS_DIR}/authelia-authrequest.conf" << 'SNIPPET'
auth_request /internal/authelia/authz;
auth_request_set $user $upstream_http_remote_user;
auth_request_set $groups $upstream_http_remote_groups;
auth_request_set $name $upstream_http_remote_name;
auth_request_set $email $upstream_http_remote_email;
proxy_set_header Remote-User $user;
proxy_set_header Remote-Groups $groups;
proxy_set_header Remote-Name $name;
proxy_set_header Remote-Email $email;
auth_request_set $redirection_url $upstream_http_location;
error_page 401 =302 $redirection_url;
SNIPPET

  cat > "${AUTHELIA_SNIPPETS_DIR}/authelia-location.conf" << 'SNIPPET1'
location /internal/authelia/authz {
    internal;
    proxy_pass http://authelia:9091/api/authz/auth-request;
    proxy_set_header X-Original-Method $request_method;
    proxy_set_header X-Original-URL $scheme://$http_host$request_uri;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header Content-Length "";
    proxy_pass_request_body off;
}
SNIPPET1

  # Also write to NPM's custom config directory so they're accessible inside the container
  local npm_custom_dir="${NPM_DATA_DIR}/nginx/custom"
  mkdir -p "$npm_custom_dir"
  cp "${AUTHELIA_SNIPPETS_DIR}/authelia-location.conf" "$npm_custom_dir/"
  cp "${AUTHELIA_SNIPPETS_DIR}/authelia-authrequest.conf" "$npm_custom_dir/"
  success "Authelia NPM snippets created"
}

setup_authelia_users() {
  step "Authelia Users"
  local default_pass hash
  default_pass=$(rand_password 16)
  info "Generating argon2 hash for default admin user..."
  hash=$(docker run --rm authelia/authelia:latest \
           authelia crypto hash generate argon2 --password "$default_pass" 2>/dev/null \
         | awk -F': ' '/Digest/ {print $2}')
  [[ -n "$hash" ]] || fatal "Failed to generate Authelia password hash"
  cat > "${AUTHELIA_CONFIG_DIR}/users.yml" << USERS
users:
  admin:
    displayname: "Admin User"
    password: "${hash}"
    email: admin@${DOMAIN}
    groups:
      - admins
USERS
  chmod 600 "${AUTHELIA_CONFIG_DIR}/users.yml"
  printf '%s' "$default_pass" > "${AUTHELIA_DIR}/.default_password"
  chmod 600 "${AUTHELIA_DIR}/.default_password"
  success "Default user created. Login: admin / (see ${AUTHELIA_DIR}/.default_password) - change after first login"
}

register_dockhand_stacks() {
  step "Registering editable stacks in Dockhand"
  info "Creating combined compose files in Dockhand data directory..."

  # Combine all compose files into one for easy editing
  {
    echo "# Combined stack - NPM + Authelia + CrowdSec"
    echo "# Edit this file and run: docker compose -f ${STACK_DIR}/docker-compose.yml up -d"
    echo ""
    cat "${STACK_DIR}/docker-compose.npm.yml" 2>/dev/null || true
    echo ""
    # Extract the services from authelia compose (remove networks: section to avoid duplicates)
    sed '1,/^services:/b;/^networks:/,$d' "${STACK_DIR}/docker-compose.authelia.yml" 2>/dev/null || true
    echo ""
    sed '1,/^services:/b;/^networks:/,$d' "${STACK_DIR}/docker-compose.crowdsec.yml" 2>/dev/null || true
  } > "${DOCKHAND_DATA_DIR}/infrastructure.yml" 2>/dev/null || true

  # Also copy individual compose files for reference
  cp "${STACK_DIR}/docker-compose.npm.yml" "${DOCKHAND_DATA_DIR}/npm.yml" 2>/dev/null || true
  cp "${STACK_DIR}/docker-compose.authelia.yml" "${DOCKHAND_DATA_DIR}/authelia.yml" 2>/dev/null || true
  cp "${STACK_DIR}/docker-compose.crowdsec.yml" "${DOCKHAND_DATA_DIR}/crowdsec.yml" 2>/dev/null || true

  success "Compose files available in Dockhand file browser: ${DOCKHAND_DATA_DIR}"
}

automate_npm() {
  step "Automating NPM setup (proxy hosts + SSL)"

  if ! npm_change_password; then
    warn "Could not change NPM password; continuing with manual setup needed"
    return
  fi

  # Create proxy host for Dockhand
  local dockhand_id
  local auth_snippet=$'include /data/nginx/custom/authelia-location.conf;\ninclude /data/nginx/custom/authelia-authrequest.conf;'
  dockhand_id=$(npm_create_proxy_host "dockhand.${DOMAIN}" "dockhand" 3000 true "$auth_snippet")
  if [[ -n "$dockhand_id" ]]; then
    npm_enable_ssl "$dockhand_id" "dockhand.${DOMAIN}"
  fi

  # Create proxy host for Authelia
  local authelia_id
  authelia_id=$(npm_create_proxy_host "authelia.${DOMAIN}" "authelia" 9091 true "")
  if [[ -n "$authelia_id" ]]; then
    npm_enable_ssl "$authelia_id" "authelia.${DOMAIN}"
  fi

  # Create proxy host for CrowdSec dashboard (partitio amd64 / Metabase arm64 ? same name+port)
    local crowdsec_id
    crowdsec_id=$(npm_create_proxy_host "crowdsec.${DOMAIN}" "crowdsec-dashboard" 3000 false "")
    if [[ -n "$crowdsec_id" ]]; then
      npm_enable_ssl "$crowdsec_id" "crowdsec.${DOMAIN}"
    fi
  fi

  success "NPM automation completed"
}

# -------------------------------------------------------------------------------
# Firewall, logrotate, CrowdSec setup
# -------------------------------------------------------------------------------
setup_firewall() {
  step "Firewall"
  info "Configuring firewall ? please wait..."
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
  local ssh_port; ssh_port=$(detect_ssh_port)
  ufw limit "${ssh_port}/tcp"
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

setup_crowdsec() {
  step "CrowdSec (Docker)"

  local mb_pass
  mb_pass=$(rand_password 20)
  printf '%s' "$mb_pass" > "${STACK_DIR}/.metabase_password"
  chmod 600 "${STACK_DIR}/.metabase_password"
  info "Metabase dashboard password stored (crowdsec@crowdsec.net / see ${STACK_DIR}/.metabase_password)"

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
  type: nginx-proxy-manager
NPM_ACQUIS
  if docker exec crowdsec cat /etc/crowdsec/acquis.d/npm.yaml &>/dev/null; then
    success "NPM acquisition configured"
  else
    docker exec -i crowdsec sh -c "mkdir -p /etc/crowdsec/acquis.d && cat > /etc/crowdsec/acquis.d/npm.yaml" << 'EOF' || true
filenames:
  - /npm-logs/*.log
labels:
  type: nginx-proxy-manager
EOF
    warn "NPM acquisition written (via docker exec)"
  fi
  info "Restarting CrowdSec to apply acquisition config..."
  docker restart crowdsec &>/dev/null || true
  for i in $(seq 1 30); do
    docker exec crowdsec cscli metrics &>/dev/null && { success "CrowdSec back up"; break; }
    [[ $i -eq 30 ]] && warn "CrowdSec slow to restart - check: docker logs crowdsec"
    sleep 2
  done
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
    warn "Firewall bouncer download failed -- check network connectivity"
    return 0
  fi
  docker exec crowdsec cscli bouncers delete npm-bouncer 2>/dev/null || true
  local api_key
  api_key=$(docker exec crowdsec cscli bouncers add npm-bouncer -o raw 2>/dev/null | tr -d '[:space:]' || true)
  if [[ -z "$api_key" ]]; then
    docker exec crowdsec cscli bouncers delete npm-bouncer 2>/dev/null || true
    api_key=$(docker exec crowdsec cscli bouncers add npm-bouncer 2>/dev/null | grep -oE '[A-Za-z0-9+/=_-]{30,}' | head -1 || true)
  fi
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
iptables_chains:
  - INPUT
  - FORWARD
  - DOCKER-USER
BOUNCER
    systemctl daemon-reload 2>/dev/null || true
    systemctl unmask crowdsec-firewall-bouncer >>"$LOG_FILE" 2>&1 || true
    if ! /usr/local/bin/crowdsec-firewall-bouncer -c /etc/crowdsec/crowdsec-firewall-bouncer.yaml -t >>"$LOG_FILE" 2>&1; then
      warn "Bouncer config self-test failed - details in ${LOG_FILE}"
    fi
    systemctl enable crowdsec-firewall-bouncer >>"$LOG_FILE" 2>&1 || warn "systemctl enable failed for bouncer"
    systemctl restart crowdsec-firewall-bouncer >>"$LOG_FILE" 2>&1 || true
    local bouncer_ok=false
    for i in $(seq 1 10); do
      if systemctl is-active --quiet crowdsec-firewall-bouncer; then bouncer_ok=true; break; fi
      sleep 2
      [[ $i -eq 5 ]] && systemctl restart crowdsec-firewall-bouncer >>"$LOG_FILE" 2>&1 || true
    done
    if $bouncer_ok; then
      success "Firewall bouncer registered and ACTIVE"
    else
      journalctl -u crowdsec-firewall-bouncer -n 30 --no-pager >>"$LOG_FILE" 2>&1 || true
      error "Firewall bouncer is NOT running - bans are not enforced. Journal saved to ${LOG_FILE}. Debug: journalctl -u crowdsec-firewall-bouncer -n 30"
    fi
  else
    error "Could not obtain bouncer API key - config NOT written, bans will not be enforced. Fix manually: docker exec crowdsec cscli bouncers add npm-bouncer -o raw"
  fi
}

# -------------------------------------------------------------------------------
# Final summary
# -------------------------------------------------------------------------------

verify_deployment() {
  step "Post-Deploy Verification"
  local fails=0

  _check() {
    local label="$1"; shift
    if "$@" &>/dev/null; then success "VERIFY: ${label}"
    else warn "VERIFY FAILED: ${label}"; fails=$((fails+1)); fi
  }

  # Containers
  local want="npm authelia crowdsec crowdsec-dashboard"
  local c
  for c in $want; do
    _check "container '$c' running" bash -c "docker ps --format '{{.Names}}' | grep -qx '$c'"
  done

  # Core service health
  _check "NPM API responding"        curl -sf --max-time 5 http://127.0.0.1:81/api/
  _check "NPM default creds REJECTED (password was changed)" bash -c \
    "! curl -s --max-time 5 -X POST http://127.0.0.1:81/api/tokens -H 'Content-Type: application/json' -d '{\"identity\":\"admin@example.com\",\"secret\":\"changeme\"}' | grep -q token"
  _check "Authelia health endpoint OK" bash -c \
    "docker exec authelia wget -q -O- http://127.0.0.1:9091/api/health 2>/dev/null | grep -q OK"
  _check "nginx config valid inside NPM" docker exec npm nginx -t
  _check "Authelia snippets present in NPM custom dir" bash -c \
    "test -f '${NPM_DATA_DIR}/nginx/custom/authelia-location.conf' && test -f '${NPM_DATA_DIR}/nginx/custom/authelia-authrequest.conf'"

    _check "CrowdSec LAPI responding"   docker exec crowdsec cscli metrics
    _check "acquisition label is nginx-proxy-manager" bash -c \
      "docker exec crowdsec cat /etc/crowdsec/acquis.d/npm.yaml 2>/dev/null | grep -q 'type: nginx-proxy-manager'"
    _check "nginx-proxy-manager collection installed" bash -c \
      "docker exec crowdsec cscli collections list 2>/dev/null | grep -q crowdsecurity/nginx-proxy-manager"
    _check "bouncer registered in LAPI" bash -c \
      "docker exec crowdsec cscli bouncers list 2>/dev/null | grep -q npm-bouncer"
    _check "firewall bouncer service ACTIVE" systemctl is-active --quiet crowdsec-firewall-bouncer
    if systemctl is-active --quiet crowdsec-firewall-bouncer; then
      info "Running live ban round-trip test (192.0.2.1, reserved test IP)..."
      docker exec crowdsec cscli decisions add --ip 192.0.2.1 --duration 2m --reason "deploy-verify" &>/dev/null || true
      sleep 15
      local banned=false
      if command -v nft &>/dev/null && nft list ruleset 2>/dev/null | grep -q '192\.0\.2\.1'; then banned=true; fi
      if ! $banned && iptables -S 2>/dev/null | grep -q '192\.0\.2\.1'; then banned=true; fi
      if ! $banned && ipset list 2>/dev/null | grep -q '192\.0\.2\.1'; then banned=true; fi
      docker exec crowdsec cscli decisions delete --ip 192.0.2.1 &>/dev/null || true
      if $banned; then success "VERIFY: end-to-end ban enforcement works"
      else warn "VERIFY FAILED: test ban did not appear in firewall rules"; fails=$((fails+1)); fi
    fi

  if [[ $fails -eq 0 ]]; then
    success "All verification checks passed"
  else
    warn "${fails} verification check(s) failed - review warnings above and ${LOG_FILE}"
  fi
}

print_summary() {
  local elapsed=$(( $(date +%s) - START_TIME ))
  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "YOUR_VPS_IP")
  local ext_ip; ext_ip=$(get_external_ip)
  local fw_cmd; [[ "$OS_FAMILY" == "debian" ]] && fw_cmd="ufw status verbose" || fw_cmd="firewall-cmd --list-all"
  local npm_password authelia_pass mb_pass
  npm_password=$(_read_cred "${STACK_DIR}/.npm_admin_password")
  authelia_pass=$(_read_cred "${AUTHELIA_DIR}/.default_password")
  mb_pass=$(_read_cred "${STACK_DIR}/.metabase_password")

  printf "\n"
  printf "${C_B}${C_GRN}+------------------------------------------------------------------------------+${C_R}\n"
  printf "${C_B}${C_GRN}?                     ??  DEPLOYMENT COMPLETE                                  ?${C_R}\n"
  printf "${C_B}${C_GRN}?------------------------------------------------------------------------------?${C_R}\n"
  printf "${C_B}?  ${C_CYN}${SCRIPT_NAME} v${SCRIPT_VERSION}${C_R}${C_B}                                                      ?${C_R}\n"
  printf "${C_B}?  Elapsed: ${C_CYN}%dm %ds${C_R}${C_B}                                                     ?${C_R}\n" $(( elapsed / 60 )) $(( elapsed % 60 ))
  printf "${C_B}+------------------------------------------------------------------------------+${C_R}\n"

    dns_crowdsec="  A  crowdsec.${DOMAIN}   ? ${ip}  (CrowdSec Dashboard)"
    proxy_crowdsec=$(cat << CROWDPROXY

    ${C_B}CrowdSec Dashboard:${C_R}
    +----------------------------------------+
    ? Domain Names:    crowdsec.${DOMAIN}           ?
    ? Scheme:          http                         ?
    ? Forward Host:    crowdsec-dashboard           ?
    ? Forward Port:    3000                         ?
    ? Login:           crowdsec@crowdsec.net        ?
    ? Password:        ${mb_pass}       ?
    ? Block Exploits:  ON                           ?
    ? Access List:     Publicly Accessible          ?
    +-----------------------------------------+
    Save ? SSL tab ? Request cert ? Force SSL ON
    ? Dashboard is read-only ? no Authelia 2FA needed
CROWDPROXY
)

  cat << EOF

${C_B}Stack Directory${C_R}    ${STACK_DIR}

${C_B}${C_GRN}-- NPM Proxy Forwarding --------------------------------------${C_R}
${C_B}Domain${C_R}                     ${C_B}Forward to${C_R}
${C_DIM}--------------------------  --------------------------${C_R}
dockhand.${DOMAIN}           ? dockhand:3000
authelia.${DOMAIN}            ? authelia:9091
crowdsec.${DOMAIN}         ? crowdsec-dashboard:3000

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

${C_B}Authelia${C_R}
  URL:      https://authelia.${DOMAIN}
  Container: authelia
  Network:   proxy
  Config:    ${AUTHELIA_CONFIG_DIR}
  Login:     admin / ${authelia_pass} (CHANGE IMMEDIATELY! � default password)
  Info:      Check notifications: sudo docker exec authelia cat /config/notifications.txt
  Note:      Dockhand is protected with 2FA via Authelia

${proxy_crowdsec}
${C_B}Firewall${C_R}  $(if [[ "$OS_FAMILY" == "debian" ]]; then echo "UFW"; else echo "firewalld"; fi)

${C_B}Docker${C_R}    $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo N/A)
${C_B}Containers${C_R}  npm, dockhand, authelia, crowdsec
${C_B}Network${C_R}   proxy (bridge)

${C_B}${C_YEL}Next Steps (already done automatically):${C_R}
  ? Proxy hosts for Dockhand created
  ? Proxy host for Authelia created
  ? Let's Encrypt SSL certificates requested (may take a moment to issue)
  ? NPM admin password securely changed
  ? Dockhand has full read/write access to the host filesystem
  ? Authelia 2FA protecting Dockhand access

${C_B}Access:${C_R}
  - Authelia:   https://authelia.${DOMAIN}
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
  printf "\n${C_B}${C_CYN}VPS Deployment -- Docker + NPM + Dockhand + Authelia + CrowdSec${C_R}\n"
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
  setup_crowdsec
  setup_logrotate
  automate_npm
  register_dockhand_stacks
  verify_deployment
  DEPLOY_STATUS="success"
  print_summary
}

main "$@"