#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# deploy-dokploy.sh — Hardened VPS Deployment (Dokploy + Docker Swarm + Fail2Ban)
# v2.0.0-dokploy | Usage: chmod +x deploy-dokploy.sh && sudo ./deploy-dokploy.sh
#
# One-shot, idempotent deployment for fresh VPS instances. Installs Docker CE,
# initializes Docker Swarm, deploys Dokploy (with built-in Traefik), Portainer CE,
# Fail2Ban, and host firewall with the critical Docker+UFW compatibility fix.
#
# Dokploy provides its OWN Traefik reverse proxy on ports 80/443 — no NPM needed.
# The first user to visit the Dokploy UI gets admin access — register immediately.
#
# Supports: Ubuntu 20.04+, Debian 11+, Rocky/Alma 8/9, Fedora 35+,
#           CentOS 7/8, Oracle Linux, Amazon Linux 2023
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="2.0.0-dokploy"
readonly SCRIPT_NAME="deploy-dokploy.sh"
readonly START_TIME=$(date +%s)
readonly PORTAINER_DIR="/opt/portainer"
readonly LOG_FILE="/var/log/vps-deploy.log"

# Colors (TTY only)
if [[ -t 1 ]]; then
  C_R='\033[0m'; C_B='\033[1m'; C_RED='\033[0;31m'; C_GRN='\033[0;32m'
  C_YEL='\033[0;33m'; C_BLU='\033[0;34m'; C_CYN='\033[0;36m'; C_DIM='\033[2m'
else
  C_R=''; C_B=''; C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_CYN=''; C_DIM=''
fi

# ── Logging utilities ─────────────────────────────────────────────────────────
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
_log() { printf "[%s] [%-5s] %s\n" "$(_ts)" "$1" "${*:2}" >> "$LOG_FILE"; }
info()    { printf "${C_BLU}ℹ${C_R}  %s\n" "$*"; _log "INFO" "$@"; }
warn()    { printf "${C_YEL}⚠${C_R}  %s\n" "$*"; _log "WARN" "$@"; }
error()   { printf "${C_RED}✖${C_R}  %s\n" "$*"; _log "ERROR" "$@"; }
success() { printf "${C_GRN}✔${C_R}  %s\n" "$*"; _log "SUCCESS" "$@"; }
fatal()   { printf "${C_RED}${C_B}FATAL${C_R}${C_RED}: %s${C_R}\n" "$*" >&2; _log "FATAL" "$@"; exit 1; }
step()    { printf "\n${C_B}${C_CYN}── %s ──${C_R}\n" "$*"; _log "STEP" "$@"; }

# ═══════════════════════════════════════════════════════════════════════════════
# PRE-FLIGHT CHECKS
# ═══════════════════════════════════════════════════════════════════════════════
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
    if [[ "$OS_ID" == "debian" && "$major_ver" -lt 11 ]]; then fatal "Debian ${OS_VERSION_ID} too old. Min: 11 (bullseye)."; fi
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
    fatal "No internet connectivity. Script requires internet."
  fi
  success "Internet OK"

  local free_mb; free_mb=$(df -m / | awk 'NR==2 {print $4}')
  if [[ "$free_mb" -lt 2048 ]]; then warn "Low disk: ${free_mb}MB free (recommend >= 2048MB)."
  else success "Disk: $(( free_mb / 1024 ))GB free"; fi

  mkdir -p "$(dirname "$LOG_FILE")"
  _log "INFO" "=== ${SCRIPT_NAME} v${SCRIPT_VERSION} started ==="
  _log "INFO" "OS: ${OS_NAME} ${OS_VERSION_ID}, Family: ${OS_FAMILY}, Arch: ${ARCH}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# IDEMPOTENT CLEANUP
# ═══════════════════════════════════════════════════════════════════════════════
idempotent_cleanup() {
  step "Idempotent Cleanup"

  if command -v docker &>/dev/null; then
    info "Removing existing Docker containers..."
    local containers; containers=$(docker ps -aq 2>/dev/null || true)
    [[ -n "$containers" ]] && { docker stop $containers &>/dev/null || true; docker rm -f $containers &>/dev/null || true; }
    local networks; networks=$(docker network ls -q --filter type=custom 2>/dev/null || true)
    [[ -n "$networks" ]] && docker network rm $networks &>/dev/null || true
    local volumes; volumes=$(docker volume ls -q 2>/dev/null || true)
    [[ -n "$volumes" ]] && docker volume rm -f $volumes &>/dev/null || true
    local images; images=$(docker images -aq 2>/dev/null || true)
    [[ -n "$images" ]] && docker rmi -f $images &>/dev/null || true
    # Leave Swarm if active (Dokploy installer will re-init)
    docker swarm leave --force 2>/dev/null || true
  fi

  if [[ "$OS_FAMILY" == "debian" ]]; then
    dpkg -l 2>/dev/null | grep -E "docker|containerd|runc" | awk '{print $2}' | xargs -r apt-get remove -y -qq &>/dev/null || true
  else
    rpm -qa 2>/dev/null | grep -E "docker|containerd|runc|podman|buildah" | xargs -r yum remove -y -q &>/dev/null || true
  fi

  rm -f /usr/local/bin/docker-compose /usr/bin/docker-compose &>/dev/null || true
  systemctl stop firewalld fail2ban ufw 2>/dev/null || true
  systemctl disable firewalld fail2ban ufw 2>/dev/null || true

  # Flush iptables safely (set policies to ACCEPT first so we don't lock ourselves out)
  iptables -P INPUT ACCEPT 2>/dev/null || true
  iptables -P FORWARD ACCEPT 2>/dev/null || true
  iptables -P OUTPUT ACCEPT 2>/dev/null || true
  iptables -F 2>/dev/null || true
  iptables -t nat -F 2>/dev/null || true
  iptables -t mangle -F 2>/dev/null || true
  iptables -X 2>/dev/null || true
  iptables -t nat -X 2>/dev/null || true
  iptables -t mangle -X 2>/dev/null || true

  rm -rf /var/lib/docker/* /etc/docker/* "$PORTAINER_DIR" 2>/dev/null || true
  success "Cleanup complete"
}

# ═══════════════════════════════════════════════════════════════════════════════
# SYSTEM UPDATE & DEPENDENCIES
# ═══════════════════════════════════════════════════════════════════════════════
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

# ═══════════════════════════════════════════════════════════════════════════════
# DOCKER CE INSTALLATION
# ═══════════════════════════════════════════════════════════════════════════════
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
  info "Verifying Docker..."
  for i in {1..3}; do docker run --rm hello-world &>/dev/null && break; sleep 5; done
  docker compose version &>/dev/null || fatal "Docker Compose plugin missing."
  success "Docker $(docker version --format '{{.Server.Version}}') + Compose $(docker compose version --short)"
}

# ═══════════════════════════════════════════════════════════════════════════════
# DOCKER SWARM (required by Dokploy)
# ═══════════════════════════════════════════════════════════════════════════════
setup_docker_swarm() {
  step "Docker Swarm"
  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  if docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q "active"; then
    success "Docker Swarm already active"
  else
    info "Initializing Docker Swarm (advertise-addr: ${ip})..."
    docker swarm init --advertise-addr "${ip}" || fatal "Docker Swarm init failed"
    success "Docker Swarm initialized"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# DOKPOLY
# ═══════════════════════════════════════════════════════════════════════════════
setup_dokploy() {
  step "Dokploy"
  info "Running Dokploy official installer..."
  # Dokploy installer initializes Docker Swarm and deploys Dokploy stack
  # It sets up Traefik (ports 80/443), Dokploy API/UI (port 3000), and PostgreSQL
  curl -sSL https://dokploy.com/install.sh | sh

  info "Waiting for Dokploy..."
  for i in $(seq 1 60); do
    curl -sf --max-time 5 http://127.0.0.1:3000/api/health &>/dev/null && { success "Dokploy responding"; break; }
    [[ $i -eq 60 ]] && warn "Dokploy timed out (3m). Check: docker service logs dokploy"
    sleep 3
  done
  success "Dokploy deployed"
}

# ═══════════════════════════════════════════════════════════════════════════════
# PORTAINER CE
# ═══════════════════════════════════════════════════════════════════════════════
setup_portainer() {
  step "Portainer CE"
  mkdir -p "$PORTAINER_DIR" && cd "$PORTAINER_DIR"
  cat > docker-compose.yml << 'COMPOSE'
services:
  portainer:
    image: 'portainer/portainer-ce:latest'
    restart: always
    container_name: portainer
    ports:
      - '127.0.0.1:9000:9000'
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://127.0.0.1:9000/api/status"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

volumes:
  portainer_data:
COMPOSE

  docker compose pull && docker compose up -d
  info "Waiting for Portainer..."
  for i in $(seq 1 40); do
    # Portainer listens on 127.0.0.1:9000 — check via localhost
    curl -sf --max-time 5 http://127.0.0.1:9000/api/status &>/dev/null && { success "Portainer responding"; break; }
    # Fallback: check container is at least running
    docker ps --format '{{.Names}}' | grep -qx "portainer" || { [[ $i -eq 40 ]] && warn "Portainer container not found"; }
    [[ $i -eq 40 ]] && warn "Portainer timed out. May still be starting — check: docker logs portainer"
    sleep 3
  done
  success "Portainer deployed (bind: 127.0.0.1:9000 — proxy via Dokploy Traefik)"
}

# ═══════════════════════════════════════════════════════════════════════════════
# FAIL2BAN
# ═══════════════════════════════════════════════════════════════════════════════
setup_fail2ban() {
  step "Fail2Ban"

  if [[ "$OS_FAMILY" == "debian" ]]; then
    apt-get install -y -qq fail2ban
    local banaction="ufw"
  else
    local pkg="yum"; command -v dnf &>/dev/null && pkg="dnf"
    $pkg install -y -q fail2ban
    local banaction="firewallcmd-rich-rules"
  fi

  cat > /etc/fail2ban/jail.local << EOF
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

[recidive]
enabled  = true
backend  = auto
logpath  = /var/log/fail2ban.log
banaction = ${banaction}
bantime  = 604800
findtime = 86400
maxretry = 5
EOF

  mkdir -p /var/log/fail2ban
  systemctl restart fail2ban && systemctl enable fail2ban
  sleep 2
  local jails; jails=$(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*://' | tr -d ' ' || true)
  [[ -n "$jails" ]] && success "Active jails: ${jails}" || warn "Check jails: fail2ban-client status"
  success "Fail2Ban configured"
}

# ═══════════════════════════════════════════════════════════════════════════════
# FIREWALL
# ═══════════════════════════════════════════════════════════════════════════════
setup_firewall() {
  step "Firewall Configuration"
  if [[ "$OS_FAMILY" == "debian" ]]; then setup_firewall_debian
  else setup_firewall_rhel; fi
}

setup_firewall_debian() {
  info "Configuring UFW..."
  apt-get install -y -qq ufw

  # ═══════════════════════════════════════════════════════════════════════════
  # CRITICAL FIX: Docker + UFW Compatibility
  # Docker manipulates iptables directly. UFW's DEFAULT_FORWARD_POLICY=DROP
  # blocks ALL container traffic. MUST set to ACCEPT before enabling UFW.
  # ═══════════════════════════════════════════════════════════════════════════
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

  # Allow SSH (auto-detect port)
  local ssh_port; ssh_port=$(ss -tlnp 2>/dev/null | grep -m1 ':22 ' | awk '{print $4}' | cut -d: -f2 || echo "22")
  ufw allow "${ssh_port:-22}/tcp" comment 'SSH'
  ufw allow 80/tcp comment 'HTTP (Dokploy Traefik)'
  ufw allow 443/tcp comment 'HTTPS (Dokploy Traefik)'
  ufw allow 3000/tcp comment 'Dokploy UI'

  ufw --force enable && ufw reload
  ufw status verbose
  success "UFW configured with Docker-compatible FORWARD policy"
}

setup_firewall_rhel() {
  info "Configuring firewalld..."
  local pkg="yum"; command -v dnf &>/dev/null && pkg="dnf"
  $pkg install -y -q firewalld
  systemctl start firewalld && systemctl enable firewalld

  firewall-cmd --permanent --add-service=ssh
  firewall-cmd --permanent --add-service=http
  firewall-cmd --permanent --add-service=https
  firewall-cmd --permanent --add-port=3000/tcp

  if ! firewall-cmd --get-zones 2>/dev/null | grep -q '\bdocker\b'; then
    firewall-cmd --permanent --new-zone=docker 2>/dev/null || true
  fi
  firewall-cmd --permanent --zone=docker --add-interface=docker0 2>/dev/null || true
  firewall-cmd --permanent --zone=docker --set-target=ACCEPT 2>/dev/null || true
  firewall-cmd --reload
  firewall-cmd --list-all
  success "Firewalld configured"
}

# ═══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════
print_summary() {
  local elapsed=$(( $(date +%s) - START_TIME ))
  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "YOUR_VPS_IP")
  local fw_cmd; [[ "$OS_FAMILY" == "debian" ]] && fw_cmd="ufw status verbose" || fw_cmd="firewall-cmd --list-all"

  cat << EOF

${C_B}${C_GRN}═════════════════════════════════════════════════════════════════════════════${C_R}
${C_B}${C_GRN}  DEPLOYMENT COMPLETE${C_R}  (${SCRIPT_NAME} v${SCRIPT_VERSION})
${C_B}${C_GRN}═════════════════════════════════════════════════════════════════════════════${C_R}

${C_B}Duration:${C_R} $(( elapsed / 60 ))m $(( elapsed % 60 ))s

${C_B}${C_CYN}── SERVICES ──${C_R}

  ${C_B}Dokploy${C_R}
    UI:        http://${ip}:3000
    Traefik:   http://${ip}:80  →  https://${ip}:443
    Note:      Dokploy has built-in Traefik (no NPM needed)

  ${C_B}Portainer CE${C_R}
    Bind:      127.0.0.1:9000
    Access:    Proxy via Dokploy (add domain → http://host.docker.internal:9000)
    Volume:    portainer_data

  ${C_B}Docker${C_R}
    Engine:    $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo N/A)
    Swarm:     $(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo N/A)
    Compose:   $(docker compose version --short 2>/dev/null || echo N/A)

  ${C_B}Fail2Ban${C_R}
    Config:    /etc/fail2ban/jail.local
    Jails:     sshd, recidive
    Status:    fail2ban-client status

  ${C_B}Firewall${C_R}   $(if [[ "$OS_FAMILY" == "debian" ]]; then echo "UFW"; else echo "firewalld"; fi)

${C_B}${C_YEL}── CRITICAL: FIRST SETUP ──${C_R}

  ${C_RED}${C_B}→  Dokploy UI: http://${ip}:3000${C_R}
     The FIRST user to visit gets ADMIN access.
     ${C_RED}${C_B}Register IMMEDIATELY after deployment!${C_R}

${C_B}${C_CYN}── NEXT STEPS ──${C_R}

  1. ${C_B}Register Admin:${C_R} Open http://${ip}:3000 and create your admin account.

  2. ${C_B}Add Server:${C_R} In Dokploy, add your VPS as a server (if needed).

  3. ${C_B}Deploy Apps:${C_R} Use Dokploy's UI to deploy applications, databases,
     and services. Dokploy's Traefik handles reverse proxy + SSL automatically.

  4. ${C_B}Portainer Access:${C_R} Add a proxy host in Dokploy:
     - Domain: portainer.your-domain.com
     - Target: http://host.docker.internal:9000
     - Enable SSL via Dokploy/Let's Encrypt

  5. ${C_B}Secure Port 3000:${C_R} After admin registration, restrict Dokploy UI:
$(if [[ "$OS_FAMILY" == "debian" ]]; then
  echo "        ufw delete allow 3000/tcp && ufw reload"
else
  echo "        firewall-cmd --permanent --remove-port=3000/tcp"
  echo "        firewall-cmd --reload"
fi)
     Then access Dokploy via its proxied domain (Traefik on 80/443).

${C_B}${C_CYN}── TROUBLESHOOTING ──${C_R}

  Dokploy:    docker service ls
              docker service logs dokploy
              docker service logs dokploy-traefik
  Portainer:  docker logs -f portainer
  Restart:    cd ${PORTAINER_DIR} && docker compose restart
  Fail2Ban:   fail2ban-client status
              fail2ban-client status recidive
  Firewall:   ${fw_cmd}
  Deploy log: ${LOG_FILE}

EOF
  _log "INFO" "=== Deployment completed in $(( elapsed / 60 ))m $(( elapsed % 60 ))s ==="
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════
main() {
  printf "\n${C_B}${C_CYN}  VPS Deployment — Dokploy + Docker Swarm + Portainer + Fail2Ban${C_R}\n"
  printf "${C_DIM}  ${SCRIPT_NAME} v${SCRIPT_VERSION}${C_R}\n\n"

  preflight_checks
  idempotent_cleanup
  system_update
  install_dependencies
  install_docker
  setup_docker_swarm
  setup_dokploy
  setup_portainer
  setup_fail2ban
  setup_firewall
  print_summary
}

main "$@"
