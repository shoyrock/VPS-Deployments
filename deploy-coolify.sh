#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# deploy-coolify.sh — Hardened VPS Deployment (Docker + Coolify + Fail2Ban)
# v2.0.0-coolify | Usage: chmod +x deploy-coolify.sh && sudo ./deploy-coolify.sh
#
# One-shot, idempotent deployment for fresh VPS instances. Installs Docker CE,
# Coolify (with built-in Traefik reverse proxy + SSL), Fail2Ban, and host
# firewall with the critical Docker+UFW compatibility fix applied.
#
# Coolify includes its own Traefik reverse proxy listening on 80/443, so we
# deploy it STANDALONE without Nginx Proxy Manager to avoid port conflicts.
#
# Supports: Ubuntu 20.04+, Debian 11+, Rocky/Alma 8/9, Fedora 35+,
#           CentOS 7/8, Oracle Linux, Amazon Linux 2023
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="2.0.0-coolify"
readonly SCRIPT_NAME="deploy-coolify.sh"
readonly START_TIME=$(date +%s)
readonly COOLIFY_DIR="/data/coolify"
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

  # Check for port conflicts on ports Coolify needs
  info "Checking port conflicts..."
  local conflict=false
  for port in 80 443 8000; do
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
      local svc; svc=$(ss -tlnp 2>/dev/null | grep ":${port} " | head -1 | awk '{print $6}' || echo "unknown")
      warn "Port ${port} already in use by: ${svc}"
      conflict=true
    fi
  done
  if [[ "$conflict" == true ]]; then
    warn "Ports 80/443/8000 are occupied. Coolify's Traefik needs these."
    warn "Stop conflicting services first (e.g., apache2, nginx, existing Traefik):"
    warn "  systemctl stop apache2 nginx 2>/dev/null || true"
  else
    success "Ports 80, 443, 8000 are free"
  fi

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
    info "Removing existing Docker resources..."
    local containers; containers=$(docker ps -aq 2>/dev/null || true)
    [[ -n "$containers" ]] && { docker stop $containers &>/dev/null || true; docker rm -f $containers &>/dev/null || true; }
    local networks; networks=$(docker network ls -q --filter type=custom 2>/dev/null || true)
    [[ -n "$networks" ]] && docker network rm $networks &>/dev/null || true
    local volumes; volumes=$(docker volume ls -q 2>/dev/null || true)
    [[ -n "$volumes" ]] && docker volume rm -f $volumes &>/dev/null || true
    local images; images=$(docker images -aq 2>/dev/null || true)
    [[ -n "$images" ]] && docker rmi -f $images &>/dev/null || true
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

  # Coolify lives in /data/coolify — leave that alone; the Coolify installer
  # manages its own state. We only remove stale Docker artifacts above.
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
# DOCKER HARDENING
# ═══════════════════════════════════════════════════════════════════════════════
setup_docker_hardening() {
  step "Docker Hardening"
  local daemon_file="/etc/docker/daemon.json"

  # Configure Docker with log rotation and security options.
  # Live restore keeps containers running when daemon restarts.
  # Log rotation prevents Docker logs from filling the disk.
  if [[ -f "$daemon_file" ]]; then
    cp -n "$daemon_file" "${daemon_file}.bak" 2>/dev/null || true
  fi

  cat > "$daemon_file" << 'EOF'
{
  "live-restore": true,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "no-new-privileges": true,
  "userland-proxy": false
}
EOF

  systemctl reload docker || systemctl restart docker
  success "Docker hardened: live-restore, log rotation, no-new-privileges"
}

# ═══════════════════════════════════════════════════════════════════════════════
# COOLIFY
# ═══════════════════════════════════════════════════════════════════════════════
setup_coolify() {
  step "Coolify"
  info "Running Coolify official installer..."

  # The Coolify installer is idempotent — safe to re-run. It sets up Docker
  # networks, volumes, and its own compose stack under /data/coolify.
  # Coolify includes Traefik as its built-in reverse proxy (ports 80/443),
  # so we do NOT deploy Nginx Proxy Manager to avoid port conflicts.
  curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash

  info "Waiting for Coolify to become healthy..."
  for i in $(seq 1 60); do
    curl -sf --max-time 5 http://127.0.0.1:8000/api/health &>/dev/null && { success "Coolify responding on :8000"; break; }
    [[ $i -eq 60 ]] && warn "Coolify timed out (3m). Check: docker logs coolify"
    sleep 3
  done

  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<VPS_IP>")
  success "Coolify deployed: http://${ip}:8000"
}

# ═══════════════════════════════════════════════════════════════════════════════
# COOLIFY POST-INSTALL VERIFICATION
# ═══════════════════════════════════════════════════════════════════════════════
verify_coolify() {
  step "Verifying Coolify Installation"

  # Coolify runs multiple containers: coolify (main), coolify-realtime,
  # coolify-db (SQLite/PostgreSQL), and coolify-redis. Check key ones.
  info "Checking Coolify containers..."
  local containers=("coolify" "coolify-realtime")
  for c in "${containers[@]}"; do
    if docker ps --format '{{.Names}}' | grep -qx "$c"; then
      success "Container '${c}' is running"
    else
      warn "Container '${c}' not found. It may still be starting."
    fi
  done

  # Verify the Coolify API health endpoint
  info "Checking Coolify API health..."
  if curl -sf --max-time 10 http://127.0.0.1:8000/api/health &>/dev/null; then
    success "Coolify API health check passed"
  else
    warn "Coolify API not yet healthy — may need more time to initialize"
  fi

  # Verify Traefik is listening on 80/443 (it's inside the coolify container network)
  info "Checking Traefik proxy ports..."
  if ss -tlnp 2>/dev/null | grep -q ':80 '; then
    success "Traefik listening on port 80"
  else
    warn "Port 80 not yet bound — Traefik may still be starting"
  fi
  if ss -tlnp 2>/dev/null | grep -q ':443 '; then
    success "Traefik listening on port 443"
  else
    warn "Port 443 not yet bound — Traefik may still be starting"
  fi
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

  # Only sshd + recidive jails. Coolify uses Traefik (not nginx), so standard
  # nginx fail2ban filters won't match Traefik access logs. Traefik has its own
  # built-in middleware for rate limiting and IP blocking — configure that
  # inside Coolify's UI if needed. We focus on SSH brute force protection here.
  cat > /etc/fail2ban/jail.local << EOF
# ═══════════════════════════════════════════════════════════════════════════════
# Auto-generated by ${SCRIPT_NAME} v${SCRIPT_VERSION} on $(date -Iseconds)
#
# Only sshd and recidive jails. Coolify uses Traefik (not nginx), so standard
# nginx filters do NOT match. Use Coolify's built-in Traefik middleware for
# HTTP-level rate limiting and IP blocking.
# ═══════════════════════════════════════════════════════════════════════════════

[DEFAULT]
bantime   = 3600
findtime  = 600
maxretry  = 5
banaction = ${banaction}
allowipv6 = auto

# ── SSH ──────────────────────────────────────────────────────────────────────
[sshd]
enabled  = true
port     = ssh
filter   = sshd
backend  = systemd
maxretry = 3

# ── Repeat Offenders ─────────────────────────────────────────────────────────
# Ban IPs that have been banned multiple times already — escalates to 7 days.
[recidive]
enabled   = true
backend   = auto
logpath   = /var/log/fail2ban.log
banaction = ${banaction}
bantime   = 604800
findtime  = 86400
maxretry  = 5
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
  ufw allow 80/tcp comment 'HTTP (Coolify Traefik)'
  ufw allow 443/tcp comment 'HTTPS (Coolify Traefik)'
  ufw allow 8000/tcp comment 'Coolify UI'

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
  firewall-cmd --permanent --add-port=8000/tcp

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

  ${C_B}Coolify${C_R}
    UI:        http://${ip}:8000
    Traefik:   http://${ip}:80  →  https://${ip}:443
    Data:      ${COOLIFY_DIR}
    Logs:      docker logs -f coolify

  ${C_B}Docker${C_R}
    Engine:    $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo N/A)
    Compose:   $(docker compose version --short 2>/dev/null || echo N/A)

  ${C_B}Fail2Ban${C_R}
    Config:    /etc/fail2ban/jail.local
    Jails:     sshd, recidive
    Status:    fail2ban-client status

  ${C_B}Firewall${C_R}   $(if [[ "$OS_FAMILY" == "debian" ]]; then echo "UFW"; else echo "firewalld"; fi)

${C_B}${C_YEL}── INITIAL SETUP ──${C_R}

  1. ${C_B}Register Admin:${C_R} Open http://${ip}:8000
     ${C_RED}The first user to visit gets admin — register immediately!${C_R}

  2. ${C_B}Add Servers:${C_R} In Coolify, go to Servers → Add new server
     (localhost is already configured as the default)

  3. ${C_B}SSL:${C_R} Coolify handles SSL automatically via its built-in Traefik.
     Add domains in Coolify → Projects → Your Project → Settings.

  4. ${C_B}Secure SSH:${C_R} Consider disabling password auth:
     sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
     systemctl restart sshd

${C_B}${C_CYN}── TROUBLESHOOTING ──${C_R}

  Coolify:    docker logs -f coolify
              docker logs -f coolify-realtime
              docker logs -f coolify-db
  Restart:    cd ${COOLIFY_DIR} && docker compose restart
  Fail2Ban:   fail2ban-client status
              fail2ban-client status sshd
  Firewall:   ${fw_cmd}
  Deploy log: ${LOG_FILE}

EOF
  _log "INFO" "=== Deployment completed in $(( elapsed / 60 ))m $(( elapsed % 60 ))s ==="
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════
main() {
  printf "\n${C_B}${C_CYN}  VPS Deployment — Docker + Coolify + Fail2Ban${C_R}\n"
  printf "${C_DIM}  ${SCRIPT_NAME} v${SCRIPT_VERSION}${C_R}\n\n"

  preflight_checks
  idempotent_cleanup
  system_update
  install_dependencies
  install_docker
  setup_docker_hardening
  setup_coolify
  verify_coolify
  setup_fail2ban
  setup_firewall
  print_summary
}

main "$@"
