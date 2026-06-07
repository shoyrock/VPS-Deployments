#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# deploy-vps.sh — Hardened VPS Deployment (Docker + NPM + Portainer + Fail2Ban)
# v2.0.0 | Usage: chmod +x deploy-vps.sh && sudo ./deploy-vps.sh
#
# One-shot, idempotent deployment for fresh VPS instances. Installs Docker CE,
# Nginx Proxy Manager, Portainer CE, Fail2Ban, and host firewall with the
# critical Docker+UFW compatibility fix applied.
#
# Supports: Ubuntu 20.04+, Debian 11+, Rocky/Alma 8/9, Fedora 35+,
#           CentOS 7/8, Oracle Linux, Amazon Linux 2023
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_NAME="deploy-vps.sh"
readonly START_TIME=$(date +%s)
readonly NPM_DIR="/opt/npm"
readonly PORTAINER_DIR="/opt/portainer"
readonly NPM_DATA_DIR="${NPM_DIR}/data"
readonly NPM_LE_DIR="${NPM_DIR}/letsencrypt"
readonly NPM_LOGS_DIR="${NPM_DATA_DIR}/logs"  # NPM logs inside /data/logs/
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

  rm -rf /var/lib/docker/* /etc/docker/* "$NPM_DIR" "$PORTAINER_DIR" 2>/dev/null || true
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
# DOCKER NETWORK
# ═══════════════════════════════════════════════════════════════════════════════
setup_docker_network() {
  step "Docker Network: proxy"
  docker network ls --format '{{.Name}}' | grep -qx "proxy" && docker network rm proxy &>/dev/null || true
  docker network create proxy 2>/dev/null || true
  docker network ls --format '{{.Name}}' | grep -qx "proxy" || fatal "Failed to create 'proxy' network"
  success "Network 'proxy' ready"
}

# ═══════════════════════════════════════════════════════════════════════════════
# NGINX PROXY MANAGER
# ═══════════════════════════════════════════════════════════════════════════════
setup_nginx_proxy_manager() {
  step "Nginx Proxy Manager"
  mkdir -p "$NPM_DATA_DIR" "$NPM_LE_DIR" "$NPM_LOGS_DIR" && cd "$NPM_DIR"
  # NPM logs to /data/logs/ inside container. The ./data:/data mount already
  # makes logs available at ./data/logs/ on the host. NO separate log mount needed.
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
  info "Starting NPM..."
  docker compose up -d

  info "Waiting for NPM..."
  for i in $(seq 1 30); do docker ps --format '{{.Names}}' | grep -qx "npm" && break; sleep 2; done

  info "Waiting for NPM admin UI (port 81)..."
  for i in $(seq 1 60); do
    curl -sf --max-time 5 http://127.0.0.1:81/ &>/dev/null && { success "NPM admin UI responding"; break; }
    [[ $i -eq 60 ]] && warn "NPM UI timed out (2m). Still starting?"
    sleep 2
  done

  info "Waiting for NPM log files..."
  # NPM creates log files like: fallback_http_access.log, default-host_access.log,
  # proxy-host-{N}_access.log, proxy-host-{N}_error.log — NOT plain access.log/error.log
  for i in $(seq 1 30); do
    # Check for any access or error log file
    if ls "${NPM_LOGS_DIR}/"*_access.log "${NPM_LOGS_DIR}/"*_error.log &>/dev/null; then
      success "NPM logs present"
      break
    fi
    if [[ $i -eq 30 ]]; then
      warn "NPM logs not created yet (needs first request). Creating placeholders."
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
  info "Waiting for Portainer..."
  for i in $(seq 1 40); do
    # Portainer has no host port mapping — check via docker exec on its internal network
    docker exec portainer wget -qO- --timeout=5 http://127.0.0.1:9000/api/status &>/dev/null && { success "Portainer responding"; break; }
    # Fallback: check container is at least running
    docker ps --format '{{.Names}}' | grep -qx "portainer" || { [[ $i -eq 40 ]] && warn "Portainer container not found"; }
    [[ $i -eq 40 ]] && warn "Portainer timed out. May still be starting — check: docker logs portainer"
    sleep 3
  done
  success "Portainer deployed (access via NPM proxy)"
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

  # ── CRITICAL: Custom filter for NPM access logs ────────────────────────────
  # NPM uses a CUSTOM access log format (NOT standard nginx combined).
  # The IP is inside [Client IP] instead of at the start. This breaks ALL
  # built-in fail2ban access-log filters. We need a custom filter.
  local fdir="/etc/fail2ban/filter.d"
  mkdir -p "$fdir"

  cat > "${fdir}/npm-access.conf" << 'FILTER'
# Fail2Ban filter for Nginx Proxy Manager (NPM) access logs
# NPM uses a custom format; standard nginx filters will NOT match.
# Matches: 401/403/404 responses (brute force, scanning, enumeration)
[Definition]
failregex = ^.*\s+(?:401|403|404)\s+.*\[Client\s+<HOST>\]\s+\[Length\s+\d+\]\s+.*$
ignoreregex = ^.*\s+(?:404)\s+.*".*\.(?:png|jpe?g|gif|ico|svg|css|js|ttf|woff2?|eot|map)(?:\?[^"]*)?"\s+.*$
FILTER

  # Install nginx-http-auth filter if missing (for NPM error logs)
  if [[ ! -f "${fdir}/nginx-http-auth.conf" ]]; then
    cat > "${fdir}/nginx-http-auth.conf" << 'FILTER'
[Definition]
failregex = ^ \[error\] \d+#\d+: \*\d+ user "[^"]*":? (password mismatch|was not found in "[^"]*"|login attempt failed), client: <HOST>, server: \S*, request: "\S+ \S+ HTTP/\d+\.\d+", host: "\S+"\s*$
ignoreregex =
datepattern = {^LN-BEG}%%ExY(?#\s)-(?#\s)%%m(?#\s)-(?#\s)%%d(?#\s)%%H(?#\s):(?#\s)%%M(?#\s):(?#\s)%%S(?:\.%f)?(?:\s+%%z)?
              ^[^\[]*\[({DATE})\s+[-+]\d{4}\]
FILTER
  fi

  # Ensure nginx-botsearch filter exists
  if [[ ! -f "${fdir}/nginx-botsearch.conf" ]]; then
    cat > "${fdir}/nginx-botsearch.conf" << 'FILTER'
[Definition]
failregex = ^<HOST>.*"(\.\.\\|\%\%|\%[0-9a-fA-F][0-9a-fA-F]|\.(git|svn|htaccess|env|ssh|idea|vscode)).*".*(404|403|500)
            ^.*(404|403|500).*[Cc]lient\s+<HOST>.*".*(admin|wp-login|phpmyadmin|xmlrpc|config\.xml|\.env|wp-config).*"
ignoreregex =
FILTER
  fi

  # Ensure log files exist so fail2ban doesn't error on start
  mkdir -p "$NPM_LOGS_DIR"
  touch "${NPM_LOGS_DIR}/fallback_http_access.log" \
        "${NPM_LOGS_DIR}/fallback_http_error.log" \
        "${NPM_LOGS_DIR}/default-host_access.log" \
        "${NPM_LOGS_DIR}/default-host_error.log" 2>/dev/null || true

  cat > /etc/fail2ban/jail.local << EOF
# ═══════════════════════════════════════════════════════════════════════════════
# Auto-generated by ${SCRIPT_NAME} v${SCRIPT_VERSION} on $(date -Iseconds)
#
# CRITICAL NOTE ABOUT NPM LOG FORMAT:
# Nginx Proxy Manager uses a CUSTOM access log format (NOT standard nginx
# combined). The IP is inside [Client IP] instead of at the start. This
# breaks fail2ban's built-in nginx-* access log filters. We use a custom
# 'npm-access' filter for access logs. Error logs still use standard format.
#
# Log files are at: ${NPM_LOGS_DIR}/
#   - proxy-host-{N}_access.log / proxy-host-{N}_error.log
#   - default-host_access.log / default-host_error.log
#   - fallback_http_access.log / fallback_http_error.log
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

# ── NPM: Admin Auth Brute Force ─────────────────────────────────────────────
# NPM error logs use STANDARD nginx format → built-in filter works.
# Catches: "password mismatch", "user was not found", "login attempt failed"
[npm-auth]
enabled  = true
port     = http,https,81
filter   = nginx-http-auth
backend  = auto
logpath  = ${NPM_LOGS_DIR}/*_error.log
maxretry = 3
findtime = 60

# ── NPM: Forceful Browsing / Bot Detection ─────────────────────────────────
# Uses CUSTOM npm-access filter (built-in filters BROKEN on NPM access logs).
# Catches: repeated 401/403/404 responses = bots scanning for vulns.
[npm-forceful-browsing]
enabled  = true
port     = http,https
filter   = npm-access
backend  = auto
logpath  = ${NPM_LOGS_DIR}/*_access.log
maxretry = 15
findtime = 60
bantime  = 3600

# ── NPM: Bot Search (Error Log) ────────────────────────────────────────────
# Only reads error logs (not access) because the error-log pattern works.
[npm-botsearch]
enabled  = true
port     = http,https
filter   = nginx-botsearch
backend  = auto
logpath  = ${NPM_LOGS_DIR}/*_error.log
maxretry = 2
findtime = 600
bantime  = 86400

# ── DISABLED: nginx-badbots ────────────────────────────────────────────────
# BROKEN with NPM — uses apache-badbots filter expecting standard access log.
# The custom npm-forceful-browsing jail replaces this functionality.
#
# ── DISABLED: nginx-limit-req ──────────────────────────────────────────────
# NPM does NOT configure rate limiting by default. Zero log entries to match.
# Enable only if you manually add limit_req directives in NPM Advanced tab.
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
  ufw allow 80/tcp comment 'HTTP'
  ufw allow 443/tcp comment 'HTTPS'
  ufw allow 81/tcp comment 'NPM Admin (restrict after setup)'

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

# ═══════════════════════════════════════════════════════════════════════════════
# LOG ROTATION
# ═══════════════════════════════════════════════════════════════════════════════
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

  ${C_B}Nginx Proxy Manager${C_R}
    Admin UI:  http://${ip}:81
    HTTP:      http://${ip}:80
    HTTPS:     https://${ip}:443
    Data:      ${NPM_DATA_DIR}
    SSL certs: ${NPM_LE_DIR}
    Logs:      ${NPM_LOGS_DIR}

  ${C_B}Portainer CE${C_R}
    Access:    Via NPM proxy (add proxy host → http://portainer:9000)
    Volume:    portainer_data

  ${C_B}Docker${C_R}
    Engine:    $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo N/A)
    Compose:   $(docker compose version --short 2>/dev/null || echo N/A)
    Network:   proxy (bridge)

  ${C_B}Fail2Ban${C_R}
    Config:    /etc/fail2ban/jail.local
    Filters:   /etc/fail2ban/filter.d/npm-access.conf (custom for NPM)
    Jails:     sshd, npm-auth, npm-forceful-browsing, npm-botsearch
    Status:    fail2ban-client status

  ${C_B}Firewall${C_R}   $(if [[ "$OS_FAMILY" == "debian" ]]; then echo "UFW"; else echo "firewalld"; fi)

${C_B}${C_YEL}── INITIAL SETUP ──${C_R}

  1. ${C_B}NPM Admin:${C_R} Open http://${ip}:81
     Login:    admin@example.com / changeme
     ${C_RED}→ Change password immediately.${C_R}

  2. ${C_B}Proxy Hosts:${C_R} In NPM, add:
     - portainer.your-domain.com → http://portainer:9000

  3. ${C_B}SSL:${C_R} Use NPM's SSL Certificates tab for Let's Encrypt.

  4. ${C_B}Secure port 81:${C_R} After setup, restrict access:
$(if [[ "$OS_FAMILY" == "debian" ]]; then
  echo "        ufw delete allow 81/tcp && ufw reload"
else
  echo "        firewall-cmd --permanent --remove-port=81/tcp"
  echo "        firewall-cmd --reload"
fi)

${C_B}${C_CYN}── TROUBLESHOOTING ──${C_R}

  Logs:       docker logs -f npm          docker logs -f portainer
  Restart:    cd ${NPM_DIR} && docker compose restart
             cd ${PORTAINER_DIR} && docker compose restart
  Fail2Ban:   fail2ban-client status
              fail2ban-client status npm-forceful-browsing
              fail2ban-regex -v ${NPM_LOGS_DIR}/proxy-host-1_access.log /etc/fail2ban/filter.d/npm-access.conf
  Firewall:   ${fw_cmd}
  Deploy log: ${LOG_FILE}

EOF
  _log "INFO" "=== Deployment completed in $(( elapsed / 60 ))m $(( elapsed % 60 ))s ==="
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════
main() {
  printf "\n${C_B}${C_CYN}  VPS Deployment — Docker + NPM + Portainer + Fail2Ban${C_R}\n"
  printf "${C_DIM}  ${SCRIPT_NAME} v${SCRIPT_VERSION}${C_R}\n\n"

  preflight_checks
  idempotent_cleanup
  system_update
  install_dependencies
  install_docker
  setup_docker_network
  setup_nginx_proxy_manager
  setup_portainer
  setup_fail2ban
  setup_firewall
  setup_logrotate
  print_summary
}

main "$@"
