#!/usr/bin/env bash
# Auto-elevate to root if not already running as root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi
# deploy-freedombox.sh — Hardened VPS Deployment for FreedomBox + NPM
# v2.1.0-freedombox | Usage: chmod +x deploy-freedombox.sh && sudo ./deploy-freedombox.sh
#
# FreedomBox (Debian Pure Blend) manages its own Apache2, firewalld, and fail2ban.
# Supports: Debian 12 (Bookworm) or newer ONLY.
set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="2.1.0-freedombox"
readonly SCRIPT_NAME="deploy-freedombox.sh"
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
  if [[ "$OS_FAMILY" == "debian" ]]; then
    dpkg -l 2>/dev/null | grep -E "docker|containerd|runc" | awk '{print $2}' | xargs -r apt-get remove -y -qq &>/dev/null || true
    apt-get autoremove -y -qq &>/dev/null || true
  else
    yum remove -y -q docker-ce docker-ce-cli containerd.io 2>/dev/null || true
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

  info "Verifying Docker..."
  for i in {1..3}; do docker run --rm hello-world &>/dev/null && break; sleep 5; done
  docker compose version &>/dev/null || fatal "Docker Compose plugin missing."
  success "Docker $(docker version --format '{{.Server.Version}}') + Compose $(docker compose version --short)"
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

  info "Verifying NPM port 81 is bound (FreedomBox Apache owns 80/443)..."
  local ports_ok=false
  for i in $(seq 1 30); do
    if ss -tlnp 2>/dev/null | grep -q ':81[[:space:]]'; then
      success "NPM bound port 81 (FreedomBox Apache owns 80/443)"
      ports_ok=true
      break
    fi
    [[ $i -eq 30 ]] && {
      echo ""; ss -tlnp 2>/dev/null | grep -E ':81 ' || true; echo ""
      fatal "NPM failed to bind port 81. Check: docker logs npm"
    }
    sleep 2
  done


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

  info "Waiting for Plinth to start..."
  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<VPS_IP>")
  for i in $(seq 1 60); do
    if curl -sf --max-time 5 "https://${ip}/freedombox/" -k &>/dev/null || \
       curl -sf --max-time 5 "http://${ip}/freedombox/" &>/dev/null; then
      success "Plinth responding"; break
    fi
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

## SUMMARY
print_summary() {
  local elapsed=$(( $(date +%s) - START_TIME ))
  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "YOUR_VPS_IP")
  local setup_secret; setup_secret=$(cat /var/lib/plinth/firstboot-wizard-secret 2>/dev/null || echo "<run: sudo cat /var/lib/plinth/firstboot-wizard-secret>")

  cat << EOF

${C_B}${C_GRN}DEPLOYMENT COMPLETE${C_R}  (${SCRIPT_NAME} v${SCRIPT_VERSION})
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
  Fail2Ban   (managed by FreedomBox)

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
  Fail2Ban: fail2ban-client status
  Cockpit:  systemctl status cockpit
  NPM:      docker logs -f npm / cd ${NPM_DIR} && docker compose restart
  Deploy:   ${LOG_FILE}

${C_B}${C_YEL}── NOTES ──${C_R}
  Firewall is managed by FreedomBox (firewalld). Do NOT install UFW.
  Apache2 is managed by FreedomBox. Do NOT modify vhosts directly.
  SSL certs can be configured via Plinth UI or Let's Encrypt.
  FreedomBox is a Debian Pure Blend — all packages from Debian repos.
  NPM is a Docker container — managed via docker compose in ${NPM_DIR}.
EOF
  _log "INFO" "=== Deployment completed in $(( elapsed / 60 ))m $(( elapsed % 60 ))s ==="
}

## MAIN
main() {
  printf "\n${C_B}${C_CYN}VPS Deployment — FreedomBox + NPM${C_R}\n"
  printf "${C_DIM}${SCRIPT_NAME} v${SCRIPT_VERSION}${C_R}\n\n"

  preflight_checks
  idempotent_cleanup
  system_update
  install_dependencies
  prepare_system
  setup_freedombox
  install_docker
  setup_docker_network
  setup_nginx_proxy_manager
  setup_fail2ban
  setup_firewall_npm
  setup_logrotate
  harden_ssh
  verify_installation
  print_summary
}

main "$@"
