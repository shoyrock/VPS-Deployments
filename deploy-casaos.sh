#!/usr/bin/env bash
# Auto-elevate to root if not already running as root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi
# deploy-casaos.sh — Docker + NPM + CasaOS + CrowdSec
# v3.0.0-crowdsec | Usage: sudo ./deploy-casaos.sh
set -euo pipefail

readonly SCRIPT_VERSION="3.0.0-crowdsec"
readonly SCRIPT_NAME="deploy-casaos.sh"
readonly START_TIME=$(date +%s)
readonly CASAOS_DATA_DIR="/var/lib/casaos"
readonly CASAOS_CONF_DIR="/etc/casaos"
readonly CASAOS_SHARE_DIR="/usr/share/casaos"
readonly NPM_DIR="/opt/npm"
readonly NPM_DATA_DIR="${NPM_DIR}/data"
readonly NPM_LE_DIR="${NPM_DIR}/letsencrypt"
readonly NPM_LOGS_DIR="${NPM_DATA_DIR}/logs"
readonly CROWDSEC_DIR="${NPM_DIR}/crowdsec"
readonly LOG_FILE="/var/log/vps-deploy.log"

# Colors (TTY only)
if [[ -t 1 ]]; then
  C_R='\033[0m'; C_B='\033[1m'; C_RED='\033[0;31m'; C_GRN='\033[0;32m'
  C_YEL='\033[0;33m'; C_BLU='\033[0;34m'; C_CYN='\033[0;36m'; C_DIM='\033[2m'
else
  C_R=''; C_B=''; C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_CYN=''; C_DIM=''
fi

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
    printf "${C_B}╠══════════════════════════════════════════════════════════════════════════════╣${C_R}\n"
    printf "${C_B}║  ${C_YEL}NPM Admin${C_R}${C_B}:  http://${C_CYN}%-56s${C_R}${C_B}║${C_R}\n" "${ip}:81"
    if [[ "$DEPLOY_STATUS" == "success" ]]; then
      printf "${C_B}║  ${C_YEL}%s${C_R}${C_B}:  http://${C_CYN}%-56s${C_R}${C_B}║${C_R}\n" "Casaos" "casaos.${DOMAIN:-yourdomain.com} (via NPM)"
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

_ts() { date '+%Y-%m-%d %H:%M:%S'; }
_log() { printf "[%s] [%-5s] %s\n" "$(_ts)" "$1" "${*:2}" >> "$LOG_FILE" 2>/dev/null || true; }
info()    { printf "${C_BLU}ℹ${C_R}  %s\n" "$*"; _log "INFO" "$@"; }
warn()    { printf "${C_YEL}⚠${C_R}  %s\n" "$*"; _log "WARN" "$@"; }
error()   { printf "${C_RED}✖${C_R}  %s\n" "$*"; _log "ERROR" "$@"; }
success() { printf "${C_GRN}✔${C_R}  %s\n" "$*"; _log "SUCCESS" "$@"; }
fatal()   { printf "${C_RED}${C_B}FATAL${C_R}${C_RED}: %s${C_R}\n" "$*" >&2; _log "FATAL" "$@"; DEPLOY_STATUS="failed"; exit 1; }
step()    { printf "\n${C_B}${C_CYN}── %s ──${C_R}\n" "$*"; _log "STEP" "$@"; }

preflight_checks() {
  step "Pre-flight Checks"
  [[ "${EUID:-0}" -ne 0 ]] && fatal "Must run as root (use sudo)."
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
      else fatal "Unsupported: ${OS_NAME} (${OS_ID}). Need Ubuntu 20.04+, Debian 11+, Rocky/Alma 8+, Fedora 35+."; fi
      ;;
  esac
  success "OS: ${OS_NAME} ${OS_VERSION_ID} (${OS_FAMILY})"

  if [[ "$OS_FAMILY" == "debian" ]]; then
    local major_ver="${OS_VERSION_ID%%.*}"
    [[ "$OS_ID" == "ubuntu" && "$major_ver" -lt 20 ]] && fatal "Ubuntu ${OS_VERSION_ID} too old. Min: 20.04."
    [[ "$OS_ID" == "debian" && "$major_ver" -lt 11 ]] && fatal "Debian ${OS_VERSION_ID} too old. Min: 11."
  fi

  readonly ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) readonly DOCKER_ARCH="amd64" ;;
    aarch64|arm64) readonly DOCKER_ARCH="arm64" ;;
    *) fatal "Unsupported arch: ${ARCH}. Need x86_64 or arm64/aarch64." ;;
  esac
  success "Arch: ${ARCH} (${DOCKER_ARCH})"

  info "Checking internet..."
  if ! curl -sf --max-time 10 https://download.docker.com/ >/dev/null 2>&1 && \
     ! curl -sf --max-time 10 https://github.com/ >/dev/null 2>&1; then
    fatal "No internet connectivity."
  fi
  success "Internet OK"

  local free_mb; free_mb=$(df -m / | awk 'NR==2 {print $4}')
  [[ "$free_mb" -lt 2048 ]] && warn "Low disk: ${free_mb}MB free (recommend >= 2048MB)." || success "Disk: $(( free_mb / 1024 ))GB free"

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
  info "Removing old config directories..."
  rm -rf /opt/npm /casaos 2>/dev/null || true
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
  info "Verifying Docker, please wait..."
  for i in {1..3}; do docker run --rm hello-world &>/dev/null && break; printf "${C_DIM}  Verifying Docker... (%d/3)${C_R}\r" "$i"; sleep 5; done
  printf "${C_GRN}✔${C_R}  Docker verified\n"
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

setup_nginx_proxy_manager() {
  step "Nginx Proxy Manager"
  mkdir -p "$NPM_DATA_DIR" "$NPM_LE_DIR" "$NPM_LOGS_DIR" "$CROWDSEC_DIR" && cd "$NPM_DIR"
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
    ports:
      - "127.0.0.1:8080:8080"
    networks:
      - proxy
COMPOSE

  docker compose pull
  info "Starting NPM, please wait..."
  docker compose up -d

  info "Waiting for NPM container..."
  for i in $(seq 1 30); do
    docker ps --format '{{.Names}}' | grep -qx "npm" && break
    printf "${C_DIM}  Waiting for NPM container... (%d/30)${C_R}\r" "$i"
    sleep 2
  done

  info "Verifying NPM ports (80, 443, 81) are bound, please wait..."
  local ports_ok=false
  for i in $(seq 1 30); do
    local has_80=false has_443=false has_81=false
    printf "${C_DIM}  Checking ports... (%d/30)${C_R}\r" "$i"
    ss -tlnp 2>/dev/null | grep -q ':80[[:space:]]' && has_80=true
    ss -tlnp 2>/dev/null | grep -q ':443[[:space:]]' && has_443=true
    ss -tlnp 2>/dev/null | grep -q ':81[[:space:]]' && has_81=true

    if $has_80 && $has_443 && $has_81; then
      success "NPM bound all ports: 80, 443, 81"
      ports_ok=true
      break
    fi
    [[ $i -eq 30 ]] && {
      echo ""
      echo "  Port 80 bound:  $has_80"
      echo "  Port 443 bound: $has_443"
      echo "  Port 81 bound:  $has_81"
      echo ""
      ss -tlnp 2>/dev/null | grep -E ':80 |:443 |:81 ' || true
      echo ""
      fatal "NPM failed to bind required ports. Check: docker logs npm"
    }
    sleep 2
  done

  info "Waiting for NPM admin UI (port 81), please wait..."
  for i in $(seq 1 60); do
    curl -sf --max-time 5 http://127.0.0.1:81/ &>/dev/null && { success "NPM admin UI responding"; break; }
    printf "${C_DIM}  Waiting for NPM admin UI... (%d/60)${C_R}\r" "$i"
    [[ $i -eq 60 ]] && warn "NPM UI timed out (2m). Check: docker logs npm"
    sleep 2
  done

  info "Waiting for NPM log files..."
  for i in $(seq 1 30); do
    if ls "${NPM_LOGS_DIR}/"*_access.log "${NPM_LOGS_DIR}/"*_error.log &>/dev/null; then
      success "NPM logs present"
      break
    fi
    printf "${C_DIM}  Waiting for NPM log files... (%d/30)${C_R}\r" "$i"
    if [[ $i -eq 30 ]]; then
      warn "NPM logs not created yet. Creating placeholders."
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

setup_casaos() {
  step "CasaOS"
  info "Installing CasaOS (this may take a few minutes)..."
  curl -fsSL https://get.casaos.io | bash

  info "Waiting for CasaOS gateway to start, please wait..."
  local health_ok=false
  for i in $(seq 1 60); do
    printf "${C_DIM}  Waiting for CasaOS gateway... (%d/60)${C_R}\r" "$i"
    # Try multiple health endpoints — CasaOS versions differ
    for endpoint in "/v1/gateway/health" "/ping" "/health" "/"; do
      if curl -sf --max-time 5 "http://127.0.0.1:80${endpoint}" &>/dev/null; then
        success "CasaOS gateway responding on port 80 (endpoint: ${endpoint})"
        health_ok=true
        break 2
      fi
    done
    # Also check if the service is at least active
    if [[ $i -eq 30 ]] && systemctl is-active --quiet casaos-gateway 2>/dev/null; then
      success "CasaOS gateway service is active (health endpoint may differ)"
      health_ok=true
      break
    fi
    [[ $i -eq 60 ]] && fatal "CasaOS gateway not responding after 3 minutes. Check: systemctl status casaos-gateway && journalctl -u casaos-gateway -n 20"
    sleep 3
  done

  info "Verifying CasaOS services..."
  local svc svcs=("casaos-gateway" "casaos-user-service" "casaos-app-management" "casaos-local-storage" "casaos-system-service")
  local active_count=0
  for svc in "${svcs[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      success "Service active: ${svc}"
      ((active_count++))
    else
      warn "Service not active: ${svc}"
    fi
  done
  info "CasaOS services: ${active_count}/${#svcs[@]} active"

  # ── CRITICAL: Move CasaOS off port 80 BEFORE NPM starts ──
  step "Reconfiguring CasaOS: 80 → 8080"

  # 1. STOP CasaOS gateway completely (frees port 80)
  info "Stopping CasaOS gateway to free port 80..."
  systemctl stop casaos-gateway 2>/dev/null || true
  sleep 2

  # 2. Find the config file
  local gateway_conf=""
  for f in /etc/casaos/gateway.ini /usr/share/casaos/conf/gateway.ini "${HOME}/.casaos/gateway.ini"; do
    [[ -f "$f" ]] && { gateway_conf="$f"; break; }
  done

  if [[ -z "$gateway_conf" ]]; then
    # Fallback: search for it
    gateway_conf=$(find /etc /usr/share /opt "${HOME}" -name "gateway.ini" 2>/dev/null | grep -i casaos | head -n1)
  fi

  if [[ -n "$gateway_conf" ]]; then
    info "Found config: ${gateway_conf}"
    cat "${gateway_conf}" | grep -i "port" | head -3 || true

    # CasaOS uses format: port=80 (no spaces). Handle both formats.
    # 1. Replace any existing port line
    sed -i '/^[Pp][Oo][Rr][Tt][[:space:]]*=/d' "$gateway_conf" 2>/dev/null || true
    # 2. Insert clean port=8080 line in the [gateway] section
    if grep -q '^\[gateway\]' "$gateway_conf" 2>/dev/null; then
      sed -i '/^\[gateway\]/a port=8080' "$gateway_conf" 2>/dev/null || true
    else
      # No [gateway] section — append to end
      echo "port=8080" >> "$gateway_conf"
    fi

    # Verify change
    if grep -qE "^[Pp][Oo][Rr][Tt][[:space:]]*=[[:space:]]*8080" "$gateway_conf" 2>/dev/null; then
      success "Config updated: port → 8080"
    else
      warn "Config may not have updated correctly"
    fi
  else
    warn "Could not find gateway.ini"
    find /etc /usr/share /opt "${HOME}" -name "gateway.ini" 2>/dev/null | head -5 || true
  fi

  # 3. START CasaOS gateway on new port
  info "Starting CasaOS gateway on port 8080..."
  systemctl start casaos-gateway 2>/dev/null || true
  sleep 3

  # 4. VERIFY: CasaOS is on 8080, port 80 is FREE
  info "Verifying port configuration, please wait..."
  local port_80_free=false port_8080_active=false

  for i in $(seq 1 30); do
    printf "${C_DIM}  Checking ports 80/8080... (%d/30)${C_R}\r" "$i"
    # Check port 80 is free (nothing listening)
    if ! ss -tlnp 2>/dev/null | grep -q ':80[[:space:]]'; then
      port_80_free=true
    fi
    # Check port 8080 has CasaOS
    if ss -tlnp 2>/dev/null | grep -q ':8080[[:space:]]'; then
      port_8080_active=true
    fi

    if $port_80_free && $port_8080_active; then
      success "Port 80 is FREE — CasaOS is on port 8080"
      break
    fi
    sleep 2
  done

  # 5. HARD FAIL if port 80 is still in use — NPM will break otherwise
  if ! $port_80_free; then
    echo ""
    fatal "CRITICAL: Port 80 is still in use after CasaOS reconfiguration. NPM cannot start.

This means CasaOS (or another service) is still binding port 80.

Manual fix steps:
  1. Find what's on port 80:
     ss -tlnp | grep ':80 '

  2. Check CasaOS gateway config:
     cat ${gateway_conf:-/etc/casaos/gateway.ini}
     # Ensure it says: PORT = 8080

  3. Restart CasaOS gateway:
     systemctl stop casaos-gateway
     systemctl start casaos-gateway

  4. Verify port 80 is free:
     ss -tlnp | grep ':80 '
     # Should show NOTHING (or docker-proxy for NPM if already running)

After fixing, run this script again."
  fi

  # 6. Connect gateway to proxy network
  info "Connecting CasaOS gateway to proxy network..."
  docker network connect proxy casaos-gateway 2>/dev/null || true

  # 7. Verify CasaOS is healthy on 8080
  info "Verifying CasaOS health on port 8080, please wait..."
  local health_ok=false
  for i in $(seq 1 30); do
    printf "${C_DIM}  Checking CasaOS health... (%d/30)${C_R}\r" "$i"
    if curl -sf --max-time 5 http://127.0.0.1:8080/v1/gateway/health &>/dev/null; then
      success "CasaOS healthy on port 8080"
      health_ok=true
      break
    fi
    sleep 2
  done
  $health_ok || warn "CasaOS not responding on 8080 — check: systemctl status casaos-gateway"
}


setup_firewall() {
  step "Firewall Configuration"
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
  success "UFW DEFAULT_FORWARD_POLICY=ACCEPT (Docker-compatible)"

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
  local ip ext_ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "YOUR_VPS_IP")
  ext_ip=$(get_external_ip)
  local fw_cmd; [[ "$OS_FAMILY" == "debian" ]] && fw_cmd="ufw status verbose" || fw_cmd="firewall-cmd --list-all"

  cat << EOF

${C_B}${C_GRN}=== DEPLOYMENT COMPLETE ===${C_R}  ${SCRIPT_NAME} v${SCRIPT_VERSION}
${C_B}Duration:${C_R} $(( elapsed / 60 ))m $(( elapsed % 60 ))s
${C_B}Internal IP:${C_R}  ${ip}
${C_B}External IP:${C_R}  ${ext_ip}

${C_B}${C_CYN}-- SERVICES --${C_R}

${C_B}Nginx Proxy Manager${C_R}
  Admin UI:  http://${ip}:81
  HTTP:      http://${ip}:80
  HTTPS:     https://${ip}:443
  Data:      ${NPM_DATA_DIR}
  SSL certs: ${NPM_LE_DIR}
  Logs:      ${NPM_LOGS_DIR}

${C_B}CasaOS${C_R}
  Container: casaos
  Port:      8080 (internal, no host port)
  Network:   proxy

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
  │ Domain Names:    casaos.YOURDOMAIN    │
  │ Scheme:          http                │
  │ Forward Host:    casaos │
  │ Forward Port:    8080      │
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
  $(if [[ "$OS_FAMILY" == "debian" ]]; then echo "  ufw delete allow 81/tcp && ufw reload"; else echo "  firewall-cmd --permanent --remove-port=81/tcp && firewall-cmd --reload"; fi)${C_B}Docker${C_R}    $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo N/A)
${C_B}Compose${C_R}   $(docker compose version --short 2>/dev/null || echo N/A)
${C_B}Network${C_R}   proxy (bridge)

${C_B}CrowdSec${C_R}
  Status:    cscli metrics    cscli decisions list

${C_B}Firewall${C_R}  $(if [[ "$OS_FAMILY" == "debian" ]]; then echo "UFW"; else echo "firewalld"; fi)

${C_B}${C_YEL}-- INITIAL SETUP --${C_R}

1. ${C_B}NPM Admin:${C_R} Open http://${ip}:81
   Login: admin@example.com / changeme
   ${C_RED}→ Change password immediately.${C_R}

2. ${C_B}Proxy CasaOS:${C_R} In NPM, add: casaos.your-domain.com → http://casaos-gateway:8080

3. ${C_B}CasaOS:${C_R} Open http://${ip}:8080 and create admin account.

4. ${C_B}SSL:${C_R} Use NPM's SSL Certificates tab for Let's Encrypt.

5. ${C_B}Secure port 81:${C_R} After setup, restrict access:
$(if [[ "$OS_FAMILY" == "debian" ]]; then
  echo "   ufw delete allow 81/tcp && ufw reload"
else
  echo "   firewall-cmd --permanent --remove-port=81/tcp && firewall-cmd --reload"
fi)

${C_B}${C_CYN}-- TROUBLESHOOTING --${C_R}

  NPM logs:   docker logs -f npm
  CasaOS:     systemctl status casaos-gateway
  Restart:    cd ${NPM_DIR} && docker compose restart
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
  printf "\n${C_B}${C_CYN}VPS Deployment — Docker + NPM + CasaOS + CrowdSec${C_R}\n"
  printf "${C_DIM}${SCRIPT_NAME} v${SCRIPT_VERSION}${C_R}\n\n"
  preflight_checks
  idempotent_cleanup
  system_update
  install_dependencies
  install_docker
  setup_docker_network
  setup_casaos
  setup_nginx_proxy_manager
  setup_crowdsec
  setup_firewall
  setup_logrotate
  print_summary
  DEPLOYED_SERVICES="NPM, CasaOS, CrowdSec"
  DEPLOY_STATUS="success"
}

main "$@"
