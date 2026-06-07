#!/usr/bin/env bash
# deploy-yunohost.sh — Hardened VPS Deployment for YunoHost + NPM
# v2.1.0-yunohost | Usage: chmod +x deploy-yunohost.sh && sudo ./deploy-yunohost.sh
#
# YunoHost ONLY supports Debian 12 (Bookworm) or newer.
# It explicitly rejects Ubuntu and all RHEL-based distributions.
set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="2.1.0-yunohost"
readonly SCRIPT_NAME="deploy-yunohost.sh"
readonly START_TIME=$(date +%s)
readonly NPM_DIR="/opt/npm"
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

_ts() { date '+%Y-%m-%d %H:%M:%S'; }
_log() { printf "[%s] [%-5s] %s\n" "$(_ts)" "$1" "${*:2}" >> "$LOG_FILE" 2>/dev/null || true; }
info()    { printf "${C_BLU}ℹ${C_R}  %s\n" "$*"; _log "INFO" "$@"; }
warn()    { printf "${C_YEL}⚠${C_R}  %s\n" "$*"; _log "WARN" "$@"; }
error()   { printf "${C_RED}✖${C_R}  %s\n" "$*"; _log "ERROR" "$@"; }
success() { printf "${C_GRN}✔${C_R}  %s\n" "$*"; _log "SUCCESS" "$@"; }
fatal()   { printf "${C_RED}${C_B}FATAL${C_R}${C_RED}: %s${C_R}\n" "$*" >&2; _log "FATAL" "$@"; exit 1; }
step()    { printf "\n${C_B}${C_CYN}── %s ──${C_R}\n" "$*"; _log "STEP" "$@"; }

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

  # YunoHost ONLY supports Debian 12+ (Bookworm)
  [[ "$OS_ID" == "debian" ]] || fatal "YunoHost requires Debian. You have: ${OS_NAME}."
  [[ "${OS_VERSION_ID%%.*}" -ge 12 ]] || fatal "YunoHost requires Debian 12+. You have: ${OS_VERSION_ID}"
  success "OS: Debian ${OS_VERSION_ID}"

  readonly ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) readonly DOCKER_ARCH="amd64" ;;
    aarch64|arm64) readonly DOCKER_ARCH="arm64" ;;
    *) fatal "Unsupported arch: ${ARCH}. Need x86_64 or arm64/aarch64." ;;
  esac
  success "Arch: ${ARCH} (${DOCKER_ARCH})"

  info "Checking internet..."
  if ! curl -sf --max-time 10 https://install.yunohost.org/ >/dev/null 2>&1 && \
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
  step "Idempotent Cleanup"

  if command -v docker &>/dev/null; then
    info "Removing Docker resources..."
    local containers; containers=$(docker ps -aq 2>/dev/null || true)
    [[ -n "$containers" ]] && { docker stop $containers &>/dev/null || true; docker rm -f $containers &>/dev/null || true; }
    local networks; networks=$(docker network ls -q --filter type=custom 2>/dev/null || true)
    [[ -n "$networks" ]] && docker network rm $networks &>/dev/null || true
    local volumes; volumes=$(docker volume ls -q 2>/dev/null || true)
    [[ -n "$volumes" ]] && docker volume rm -f $volumes &>/dev/null || true
    local images; images=$(docker images -aq 2>/dev/null || true)
    [[ -n "$images" ]] && docker rmi -f $images &>/dev/null || true
  fi

  dpkg -l 2>/dev/null | grep -E "docker|containerd|runc" | awk '{print $2}' | xargs -r apt-get remove -y -qq &>/dev/null || true
  rm -f /usr/local/bin/docker-compose /usr/bin/docker-compose &>/dev/null || true
  rm -rf /var/lib/docker/* /etc/docker/* "$NPM_DIR" 2>/dev/null || true

  if command -v yunohost &>/dev/null; then
    info "Removing YunoHost..."
    apt-get remove -y -qq yunohost yunohost-admin 2>/dev/null || true
    rm -rf /etc/yunohost /var/cache/yunohost /home/yunohost.backup 2>/dev/null || true
  fi

  apt-get remove -y -qq apache2 bind9 ufw 2>/dev/null || true
  apt-get autoremove -y -qq 2>/dev/null || true
  systemctl stop apache2 bind9 ufw 2>/dev/null || true
  systemctl disable apache2 bind9 ufw 2>/dev/null || true

  # Flush iptables safely (ACCEPT policies first to avoid lockout)
  iptables -P INPUT ACCEPT 2>/dev/null || true
  iptables -P FORWARD ACCEPT 2>/dev/null || true
  iptables -P OUTPUT ACCEPT 2>/dev/null || true
  iptables -F 2>/dev/null || true
  iptables -t nat -F 2>/dev/null || true
  iptables -t mangle -F 2>/dev/null || true
  iptables -X 2>/dev/null || true
  iptables -t nat -X 2>/dev/null || true
  iptables -t mangle -X 2>/dev/null || true

  success "Cleanup complete"
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

## REMOVE CONFLICTING PACKAGES
remove_conflicts() {
  step "Removing Conflicting Packages"
  # YunoHost manages its own nginx, dnsmasq, fail2ban, and firewall.
  # Remove these to prevent port conflicts and service clashes.
  apt-get remove -y -qq apache2 bind9 ufw 2>/dev/null || true
  apt-get autoremove -y -qq 2>/dev/null || true
  systemctl stop apache2 bind9 ufw 2>/dev/null || true
  systemctl disable apache2 bind9 ufw 2>/dev/null || true
  success "Conflicts removed"
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

  info "Verifying Docker..."
  for i in {1..3}; do docker run --rm hello-world &>/dev/null && break; sleep 5; done
  docker compose version &>/dev/null || fatal "Docker Compose plugin missing."
  success "Docker $(docker version --format '{{.Server.Version}}') + Compose $(docker compose version --short)"
}

## DOCKER NETWORK
setup_docker_network() {
  step "Docker Network: proxy"
  docker network ls --format '{{.Name}}' | grep -qx "proxy" && docker network rm proxy &>/dev/null || true
  docker network create proxy 2>/dev/null || true
  docker network ls --format '{{.Name}}' | grep -qx "proxy" || fatal "Failed to create 'proxy' network"
  success "Network 'proxy' ready"
}

## NGINX PROXY MANAGER (port 81 — YunoHost owns 80/443)
setup_nginx_proxy_manager() {
  step "Nginx Proxy Manager (supplementary proxy on port 81)"
  mkdir -p "$NPM_DATA_DIR" "$NPM_LE_DIR" "$NPM_LOGS_DIR" && cd "$NPM_DIR"

  cat > docker-compose.yml << 'COMPOSE'
services:
  app:
    image: 'jc21/nginx-proxy-manager:latest'
    restart: always
    container_name: npm
    ports:
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

  info "Waiting for NPM container..."
  for i in $(seq 1 30); do docker ps --format '{{.Names}}' | grep -qx "npm" && break; sleep 2; done

  info "Waiting for NPM admin UI (port 81)..."
  for i in $(seq 1 60); do
    curl -sf --max-time 5 http://127.0.0.1:81/ &>/dev/null && { success "NPM admin UI responding"; break; }
    [[ $i -eq 60 ]] && warn "NPM UI timed out (2m). Still starting?"
    sleep 2
  done

  info "Waiting for NPM log files..."
  for i in $(seq 1 30); do
    if ls "${NPM_LOGS_DIR}/"*_access.log "${NPM_LOGS_DIR}/"*_error.log &>/dev/null; then
      success "NPM logs present"; break
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

## FAIL2BAN
setup_fail2ban() {
  step "Fail2Ban"

  apt-get install -y -qq fail2ban
  local banaction="ufw"

  # NPM uses a CUSTOM access log format — IP is inside [Client IP], not at start.
  # Built-in fail2ban nginx filters will NOT match. Custom filter required.
  local fdir="/etc/fail2ban/filter.d"
  mkdir -p "$fdir"

  cat > "${fdir}/npm-access.conf" << 'FILTER'
# Fail2Ban filter for NPM access logs. NPM uses custom format;
# standard nginx filters will NOT match. Matches 401/403/404 responses.
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
failregex = ^<HOST>.*"(\.\.\\|\\%\\%|\%[0-9a-fA-F][0-9a-fA-F]|\.(git|svn|htaccess|env|ssh|idea|vscode)).*".*(404|403|500)
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
# CRITICAL: NPM uses a CUSTOM access log format. Built-in nginx-* filters
# will NOT match. We use a custom 'npm-access' filter for access logs.
# Log files are at: ${NPM_LOGS_DIR}/

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

# NPM error logs use standard nginx format → built-in filter works.
[npm-auth]
enabled  = true
port     = 81
filter   = nginx-http-auth
backend  = auto
logpath  = ${NPM_LOGS_DIR}/*_error.log
maxretry = 3
findtime = 60

# Uses CUSTOM npm-access filter (built-in filters BROKEN on NPM access logs).
[npm-forceful-browsing]
enabled  = true
port     = 81
filter   = npm-access
backend  = auto
logpath  = ${NPM_LOGS_DIR}/*_access.log
maxretry = 15
findtime = 60
bantime  = 3600

# Only reads error logs (access log pattern differs).
[npm-botsearch]
enabled  = true
port     = 81
filter   = nginx-botsearch
backend  = auto
logpath  = ${NPM_LOGS_DIR}/*_error.log
maxretry = 2
findtime = 600
bantime  = 86400

# DISABLED: nginx-badbots — uses apache-badbots filter expecting standard access log.
# DISABLED: nginx-limit-req — NPM doesn't configure rate limiting by default.
EOF

  mkdir -p /var/log/fail2ban
  systemctl restart fail2ban && systemctl enable fail2ban

  sleep 2
  local jails; jails=$(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*://' | tr -d ' ' || true)
  [[ -n "$jails" ]] && success "Active jails: ${jails}" || warn "Check jails: fail2ban-client status"
  success "Fail2Ban configured"
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

## YUNOHOST INSTALLATION
setup_yunohost() {
  step "YunoHost Installation"
  info "Installing YunoHost (this may take 10-20 minutes)..."
  curl https://install.yunohost.org | bash -s -- -a
  success "YunoHost installed"

  info "Post-installation required:"
  info "  yunohost tools postinstall \\"
  info "    --domain your-domain.com \\"
  info "    --username admin \\"
  info "    --password 'YourSecurePassword123'"
  info "Then access: https://your-domain.com/yunohost/admin"
}

## YUNOHOST FIREWALL: Open port 81 for NPM
setup_yunohost_firewall_npm() {
  step "YunoHost Firewall: Opening port 81 for NPM"

  if command -v yunohost &>/dev/null; then
    info "Opening TCP port 81 via YunoHost firewall..."
    yunohost firewall allow TCP 81 2>/dev/null || true
  else
    warn "YunoHost not installed. Opening port 81 via nftables..."
    nft add rule inet filter input tcp dport 81 accept 2>/dev/null || \
      iptables -I INPUT -p tcp --dport 81 -j ACCEPT 2>/dev/null || true
  fi

  success "Port 81 opened for NPM admin UI"
}

## SUMMARY
print_summary() {
  local elapsed=$(( $(date +%s) - START_TIME ))
  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "YOUR_VPS_IP")

  cat << EOF

${C_B}${C_GRN}DEPLOYMENT COMPLETE${C_R}  (${SCRIPT_NAME} v${SCRIPT_VERSION})
${C_B}Duration:${C_R} $(( elapsed / 60 ))m $(( elapsed % 60 ))s

${C_B}${C_CYN}── YUNOHOST ──${C_R}
  Post-install:
    yunohost tools postinstall --domain your-domain.com \\
      --username admin --password 'YourSecurePassword123'
  Admin:    https://your-domain.com/yunohost/admin
  CLI:      yunohost --help
  Services: nginx, dnsmasq, nftables (YunoHost-managed), fail2ban, postfix, dovecot

${C_B}${C_CYN}── NGINX PROXY MANAGER ──${C_R}
  Admin:    http://${ip}:81  (admin@example.com / changeme)
  ${C_RED}→ Change password immediately.${C_R}
  Purpose:  Supplementary proxy for Docker-based services
  Data:     ${NPM_DATA_DIR}
  SSL:      ${NPM_LE_DIR}
  Logs:     ${NPM_LOGS_DIR}

${C_B}${C_CYN}── FAIL2BAN JAILS ──${C_R}
  Config:   /etc/fail2ban/jail.local
  Filters:  /etc/fail2ban/filter.d/npm-access.conf (custom)
  Jails:    sshd, npm-auth, npm-forceful-browsing, npm-botsearch

${C_B}${C_CYN}── PORTS ──${C_R}
  22   SSH         Server access
  25   SMTP        Mail delivery
  80   HTTP        YunoHost nginx
  81   HTTP        NPM Admin UI
  443  HTTPS       YunoHost nginx + apps
  587  SMTP-Submit Mail submission
  993  IMAPS       Secure mail retrieval

${C_B}${C_YEL}── NOTES ──${C_R}
  YunoHost manages its own nftables-based firewall. Do NOT install UFW.
  Manage rules with: yunohost firewall --help

${C_B}${C_CYN}── TROUBLESHOOTING ──${C_R}
  YunoHost:  yunohost diagnosis run && yunohost diagnosis show
  Firewall:  yunohost firewall list
  Services:  yunohost service status
  Backup:    yunohost backup create
  NPM logs:  docker logs -f npm
  Restart:   cd ${NPM_DIR} && docker compose restart
  Deploy:    ${LOG_FILE}
  Docs:      https://yunohost.org/en/administer
EOF
  _log "INFO" "=== Deployment completed in $(( elapsed / 60 ))m $(( elapsed % 60 ))s ==="
}

## MAIN
main() {
  printf "\n${C_B}${C_CYN}VPS Deployment — YunoHost + NPM${C_R}\n"
  printf "${C_DIM}${SCRIPT_NAME} v${SCRIPT_VERSION}${C_R}\n\n"

  preflight_checks
  idempotent_cleanup
  system_update
  install_dependencies
  remove_conflicts
  setup_yunohost
  install_docker
  setup_docker_network
  setup_nginx_proxy_manager
  setup_fail2ban
  setup_yunohost_firewall_npm
  setup_logrotate
  print_summary
}

main "$@"
