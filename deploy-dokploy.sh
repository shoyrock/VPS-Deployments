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
DEPLOYED_SERVICES=""

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
  info "Removing config directories..."
  rm -rf /opt/npm /etc/dokploy 2>/dev/null || true
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
  docker compose version &>/dev/null || fatal "Docker Compose plugin missing."
  success "Docker $(docker version --format '{{.Server.Version}}') + Compose $(docker compose version --short)"
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
  mkdir -p "$NPM_DATA_DIR" "$NPM_LE_DIR" "$NPM_LOGS_DIR" && cd "$NPM_DIR"
  cat > docker-compose.yml << 'COMPOSE'
services:
  app:
    image: 'jc21/nginx-proxy-manager:latest'
    restart: always
    container_name: npm
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

networks:
  proxy:
    external: true
COMPOSE

  docker compose pull
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

  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<VPS_IP>")
  success "NPM deployed: http://${ip}:81"
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
  mkdir -p "$PORTAINER_DIR" && cd "$PORTAINER_DIR"
  cat > docker-compose.yml << 'COMPOSE'
services:
  portainer:
    image: 'portainer/portainer-ce:latest'
    restart: always
    container_name: portainer
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

volumes:
  portainer_data:

networks:
  proxy:
    external: true
COMPOSE

  docker compose pull && docker compose up -d

  info "Waiting for Portainer (please wait)..."
  for i in $(seq 1 40); do
    printf "${C_DIM}  Waiting for Portainer... (%d/40)${C_R}\r" "$i"
    docker exec portainer wget -qO- --timeout=5 http://127.0.0.1:9000/api/status &>/dev/null && { success "Portainer responding"; break; }
    [[ $i -eq 40 ]] && warn "Portainer timed out. Check: docker logs portainer"
    sleep 3
  done
  success "Portainer deployed"
}

setup_crowdsec() {
  step "CrowdSec"

  if command -v cscli &>/dev/null; then
    info "CrowdSec already installed"
  else
    if [[ "$OS_FAMILY" == "debian" ]]; then
      curl -s https://install.crowdsec.net | bash -s -- -d debian >> "$LOG_FILE" 2>&1 || { warn "CrowdSec repo setup failed"; return; }
      apt-get install -y -qq crowdsec >> "$LOG_FILE" 2>&1 || { warn "CrowdSec install failed"; return; }
    else
      curl -s https://install.crowdsec.net | bash -s -- -d rhel >> "$LOG_FILE" 2>&1 || { warn "CrowdSec repo setup failed"; return; }
      local pkg="yum"; command -v dnf &>/dev/null && pkg="dnf"
      $pkg install -y -q crowdsec >> "$LOG_FILE" 2>&1 || { warn "CrowdSec install failed"; return; }
    fi
  fi

  info "Installing CrowdSec collections..."
  cscli collections install crowdsecurity/sshd 2>/dev/null || true
  cscli collections install crowdsecurity/nginx-proxy-manager 2>/dev/null || true
  cscli collections install crowdsecurity/linux 2>/dev/null || true

  info "Installing firewall bouncer..."
  if [[ "$OS_FAMILY" == "debian" ]]; then
    dpkg -l crowdsec-firewall-bouncer-iptables &>/dev/null || apt-get install -y -qq crowdsec-firewall-bouncer-iptables >> "$LOG_FILE" 2>&1 || true
  else
    rpm -q crowdsec-firewall-bouncer-iptables &>/dev/null || {
      local pkg="yum"; command -v dnf &>/dev/null && pkg="dnf"
      $pkg install -y -q crowdsec-firewall-bouncer-iptables >> "$LOG_FILE" 2>&1 || true
    }
  fi

  systemctl enable --now crowdsec >> "$LOG_FILE" 2>&1 || true
  systemctl enable --now crowdsec-firewall-bouncer 2>/dev/null || true

  sleep 2
  if systemctl is-active --quiet crowdsec 2>/dev/null; then
    success "CrowdSec active (local mode)"
  else
    warn "CrowdSec not running — check ${LOG_FILE}"
  fi
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
${C_B}Compose${C_R}   $(docker compose version --short 2>/dev/null || echo N/A)
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

  NPM:        docker logs -f npm    cd ${NPM_DIR} && docker compose restart
  Dokploy:    docker service ls && docker service logs dokploy
  Portainer:  docker logs -f portainer
  CrowdSec:   cscli metrics    cscli decisions list
  Firewall:   ${fw_cmd}
  Deploy log: ${LOG_FILE}

EOF
  _log "INFO" "=== Deployment completed in $(( elapsed / 60 ))m $(( elapsed % 60 ))s ==="
}

main() {
  printf "\n${C_B}${C_CYN}  VPS Deployment — Docker + NPM + Dokploy + Portainer + CrowdSec${C_R}\n"
  printf "${C_DIM}  ${SCRIPT_NAME} v${SCRIPT_VERSION}${C_R}\n\n"

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
  setup_crowdsec
  setup_firewall
  setup_logrotate
  DEPLOY_STATUS="success"
  DEPLOYED_SERVICES="docker npm dokploy portainer crowdsec firewall logrotate"
  print_summary
}

main "$@"
