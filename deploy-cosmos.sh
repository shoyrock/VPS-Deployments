#!/usr/bin/env bash
# Auto-elevate to root if not already running as root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi
# deploy-cosmos.sh -- Docker + NPM + Cosmos + Authelia + CrowdSec
# v4.0.0-cosmos-crowdsec | Usage: sudo ./deploy-cosmos.sh
set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="4.5.0-hardened"
readonly SCRIPT_NAME="deploy-cosmos.sh"
START_TIME=$(date +%s); readonly START_TIME
readonly STACK_DIR="/opt/cosmos-stack"
readonly COSMOS_DATA_DIR="/opt/cosmos-stack/cosmos-data"
readonly NPM_DATA_DIR="${STACK_DIR}/data"
readonly NPM_LE_DIR="${STACK_DIR}/letsencrypt"
readonly NPM_LOGS_DIR="${NPM_DATA_DIR}/logs"
readonly CROWDSEC_DIR="${STACK_DIR}/crowdsec"
readonly LOG_FILE="/var/log/vps-deploy.log"

# -- Authelia paths --
readonly AUTHELIA_DIR="${STACK_DIR}/authelia"
readonly AUTHELIA_SECRETS_DIR="${AUTHELIA_DIR}/secrets"
readonly AUTHELIA_CONFIG_DIR="${AUTHELIA_DIR}/config"
readonly AUTHELIA_SNIPPETS_DIR="${AUTHELIA_DIR}/snippets"
readonly DOMAIN_PERSIST_FILE="/etc/vps-deploy-domain"

# -- Runtime-populated --
DOMAIN=""  # Set at runtime via user prompt

# -- Deployment state --
DEPLOY_STATUS="in_progress"
if [[ -t 1 ]]; then
  C_R='\033[0m'; C_B='\033[1m'; C_RED='\033[0;31m'; C_GRN='\033[0;32m'
  C_YEL='\033[0;33m'; C_BLU='\033[0;34m'; C_CYN='\033[0;36m'; C_DIM='\033[2m'
else
  C_R=''; C_B=''; C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_CYN=''; C_DIM=''
fi

_ts() { date '+%Y-%m-%d %H:%M:%S'; }
_log() { printf "[%s] [%-5s] %s\n" "$(_ts)" "$1" "${*:2}" >> "$LOG_FILE" 2>/dev/null || true; }
# NOTE: all UI helpers print to STDERR so that functions whose stdout is
# captured via $(...) (e.g. npm_create_proxy_host) are not polluted.
info()    { printf "${C_BLU}[i]${C_R}  %s\n" "$*" >&2; _log "INFO" "$@"; }
warn()    { printf "${C_YEL}[!]${C_R}  %s\n" "$*" >&2; _log "WARN" "$@"; }
error()   { printf "${C_RED}[x]${C_R}  %s\n" "$*" >&2; _log "ERROR" "$@"; }
success() { printf "${C_GRN}[ok]${C_R} %s\n" "$*" >&2; _log "SUCCESS" "$@"; }
fatal()   { printf "${C_RED}${C_B}FATAL${C_R}${C_RED}: %s${C_R}\n" "$*" >&2; _log "FATAL" "$@"; DEPLOY_STATUS="failed"; exit 1; }
step()    { printf "\n${C_B}${C_CYN}-- %s --${C_R}\n" "$*" >&2; _log "STEP" "$@"; }
rand_secret() {
  # 32 bytes base64. Strong fallback via /dev/urandom (never date+sha256).
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

get_external_ip() {
  curl -s -4 --max-time 10 https://api.ipify.org 2>/dev/null || \
  curl -s -4 --max-time 10 https://ifconfig.me 2>/dev/null || \
  curl -s -4 --max-time 10 https://icanhazip.com 2>/dev/null || \
  echo "unknown"
}

# -- Guaranteed completion summary on EXIT (fires even on fatal() / set -e failures) --
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
  printf "${C_B}?  %-72s  ?${C_R}\n" "Elapsed:   ${elapsed}s"
  printf "${C_B}?  %-72s  ?${C_R}\n" "VPS IP:    $ip"
  printf "${C_B}?  %-72s  ?${C_R}\n" "External:  $ext_ip"
  printf "${C_B}?  %-72s  ?${C_R}\n" "Domain:    ${DOMAIN:-<not set>}"
  printf "${C_B}?------------------------------------------------------------------------------?${C_R}\n"
  printf "${C_B}?  %-72s  ?${C_R}\n" "NPM Admin:  http://${ip}:81"
  printf "${C_B}?  %-72s  ?${C_R}\n" "NPM Login: admin@example.com / ${npm_pass}"
  if [[ "$DEPLOY_STATUS" == "success" ]]; then
    printf "${C_B}?  %-72s  ?${C_R}\n" "Cosmos:     http://cosmos.${DOMAIN} (via NPM)"
    printf "${C_B}?  %-72s  ?${C_R}\n" "Authelia:   https://authelia.${DOMAIN}"
    printf "${C_B}?  %-72s  ?${C_R}\n" "CrowdSec:  https://crowdsec.${DOMAIN}"
    printf "${C_B}?  %-72s  ?${C_R}\n" "  Login:   crowdsec@crowdsec.net"
    printf "${C_B}?  %-72s  ?${C_R}\n" "  Pass:    ${mb_pass}"
    printf "${C_B}?------------------------------------------------------------------------------?${C_R}\n"
    printf "${C_B}?  %-72s  ?${C_R}\n" "NPM Proxy Forwarding:"
    printf "${C_B}?  %-72s  ?${C_R}\n" "  authelia.${DOMAIN}          ? authelia:9091"
    printf "${C_B}?  %-72s  ?${C_R}\n" "  cosmos.${DOMAIN}            ? cosmos-server:80"
    printf "${C_B}?  %-72s  ?${C_R}\n" "  crowdsec.${DOMAIN}          ? crowdsec-dashboard:3000"
    printf "${C_B}?  %-72s  ?${C_R}\n" ""
    printf "${C_B}?  ${C_YEL}%-72s${C_R}${C_B}  ?${C_R}\n" "Authelia Username:  admin"
    printf "${C_B}?  ${C_YEL}%-72s${C_R}${C_B}  ?${C_R}\n" "Authelia Password:  $authelia_pass"
    printf "${C_B}?  ${C_RED}%-72s${C_R}${C_B}  ?${C_R}\n" "Change this password immediately after first login!"
    printf "${C_B}?  %-72s  ?${C_R}\n" "Also saved in: ${AUTHELIA_DIR}/password.txt"
    printf "${C_B}?  %-72s  ?${C_R}\n" ""
    printf "${C_B}?  ${C_YEL}%-72s${C_R}${C_B}  ?${C_R}\n" "-- Changing Password or Adding 2FA --"
    printf "${C_B}?  %-72s  ?${C_R}\n" "1. In Authelia, go to Settings ? Password (or 2FA)"
    printf "${C_B}?  %-72s  ?${C_R}\n" "2. Authelia will ask for a verification code"
    printf "${C_B}?  %-72s  ?${C_R}\n" "3. Then run this command to get the code:"
    printf "${C_B}?  ${C_CYN}%-72s${C_R}${C_B}  ?${C_R}\n" "sudo docker exec authelia cat /config/notifications.txt"
    printf "${C_B}?  %-72s  ?${C_R}\n" "4. Paste the code into Authelia and click Verify"
    printf "${C_B}?  %-72s  ?${C_R}\n" ""
  fi
  printf "${C_B}?  %-72s  ?${C_R}\n" "Ports:  80 (HTTP), 443 (HTTPS), 81 (NPM Admin)"
  printf "${C_B}?------------------------------------------------------------------------------?${C_R}\n"
  printf "${C_B}?  %-72s  ?${C_R}\n" "Log: $LOG_FILE"
  printf "${C_B}+------------------------------------------------------------------------------+${C_R}\n"
  printf "\n"
  if [[ "$DEPLOY_STATUS" == "success" ]]; then
    printf "${C_B}${C_GRN}Your VPS is ready!${C_R} Set up DNS ? ${C_CYN}${ext_ip}${C_R} and configure NPM.\n\n"
  else
    printf "${C_B}${C_YEL}Deployment failed.${C_R} Check: ${C_CYN}cat $LOG_FILE${C_R}\n\n"
  fi
  _log "INFO" "=== Script exited (code $exit_code, status: $DEPLOY_STATUS, elapsed: ${elapsed}s) ===" 2>/dev/null || true
  exit $exit_code
}

trap _on_exit EXIT

preflight_checks() {
  step "Pre-flight Checks"
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
  if [[ "${EUID:-0}" -ne 0 ]]; then fatal "Run as root (use sudo)."; fi
  success "Running as root"

  if [[ -f /etc/os-release ]]; then
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

  local free_mb; free_mb=$(df -m / 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
  if [[ "$free_mb" -lt 2048 ]]; then warn "Low disk: ${free_mb}MB free (recommend >= 2048MB)."
  else success "Disk: $(( free_mb / 1024 ))GB free"; fi
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

  info "Removing ALL previous platform data..."
  for dir in /opt/npm /opt/casaos /var/lib/casaos /opt/casaos-stack /opt/coolify-stack /opt/cosmos-stack /opt/dockge-stack /opt/dokploy-stack /opt/portainer-stack /opt/runtipi-stack /opt/freedombox-stack /opt/yunohost-stack; do
    rm -rf "$dir" 2>/dev/null || true
  done

  info "Removing ALL previous platform services..."
  for svc in casaos-gateway casaos-user-service casaos-local-storage casaos-message-bus runtipi crowdsec-firewall-bouncer; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    systemctl mask "$svc" 2>/dev/null || true
    rm -f "/etc/systemd/system/${svc}.service" "/etc/systemd/system/${svc}" 2>/dev/null || true
  done
  systemctl daemon-reload 2>/dev/null || true

  rm -f /usr/local/bin/crowdsec-firewall-bouncer 2>/dev/null || true
  rm -f /etc/crowdsec/crowdsec-firewall-bouncer.yaml 2>/dev/null || true
  rm -rf /etc/crowdsec 2>/dev/null || true

  if [[ "$OS_FAMILY" == "debian" ]]; then
    apt-get remove -y -qq crowdsec crowdsec-firewall-bouncer-nftables crowdsec-firewall-bouncer-iptables 2>/dev/null || true
    apt-get autoremove -y -qq 2>/dev/null || true
  else
    local pkg="yum"; command -v dnf &>/dev/null && pkg="dnf"
    $pkg remove -y -q crowdsec crowdsec-firewall-bouncer-nftables crowdsec-firewall-bouncer-iptables 2>/dev/null || true
  fi

  if command -v snap &>/dev/null; then
    snap disable docker 2>/dev/null || true
    snap remove docker 2>/dev/null || true
  fi
}

system_update() {
  step "System Update"
  info "Updating packages ? this may take a few minutes..."
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
  step "Dependencies"
  info "Installing required packages..."
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
  info "Installing Docker CE ? this may take a few minutes..."
  if [[ "$OS_FAMILY" == "debian" ]]; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" -o /etc/apt/keyrings/docker.asc 2>/dev/null || \
      curl -fsSL "https://download.docker.com/linux/ubuntu/gpg" -o /etc/apt/keyrings/docker.asc
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
  for i in $(seq 1 3); do docker run --rm hello-world &>/dev/null && break; sleep 5; done
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

# ------------------------------------------------------------------------------
# Authelia -- Domain, Secrets, Config, Snippets
# ------------------------------------------------------------------------------

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

  # Fresh domain prompt
  printf "\n${C_B}Enter your root domain${C_R} (e.g., example.com): "
  read -r DOMAIN
  [[ -z "$DOMAIN" ]] && fatal "Domain is required."
  DOMAIN=$(echo "$DOMAIN" | sed 's|https\?://||' | sed 's|/.*||' | tr -d ' ')
  printf '%s' "$DOMAIN" > "${DOMAIN_PERSIST_FILE}"
  success "Domain set to: $DOMAIN"
}

setup_authelia_secrets() {
  step "Generating Authelia Secrets"
  mkdir -p "$AUTHELIA_SECRETS_DIR"
  local secret_name secret_file
  for secret_name in jwt_reset storage_encryption session; do
    secret_file="${AUTHELIA_SECRETS_DIR}/${secret_name}"
    if [[ ! -f "$secret_file" ]]; then
      openssl rand -hex 32 > "$secret_file"
      chmod 600 "$secret_file"
      success "Secret '${secret_name}' generated"
    else
      # NOTE: only reachable if idempotent_cleanup is skipped
      info "Secret '${secret_name}' already exists (preserved)"
    fi
  done
  chown -R 1001:1001 "$AUTHELIA_SECRETS_DIR" 2>/dev/null || true
}

setup_authelia_config() {
  step "Authelia Configuration"
  mkdir -p "$AUTHELIA_CONFIG_DIR"

  cat > "${AUTHELIA_CONFIG_DIR}/configuration.yml" << EOF
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
      policy: bypass
    - domain: "cosmos.${DOMAIN}"
      policy: two_factor
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
      default_redirection_url: "https://cosmos.${DOMAIN}"
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
EOF

  chown -R 1001:1001 "$AUTHELIA_CONFIG_DIR" 2>/dev/null || true
  info "users.yml will be created after authelia container starts"
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

setup_stack() {
  step "Deploying Stack (NPM + Cosmos + Authelia + CrowdSec)"
  mkdir -p "$NPM_DATA_DIR" "$NPM_LE_DIR" "$NPM_LOGS_DIR" "$COSMOS_DATA_DIR" "$CROWDSEC_DIR"

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

  cat > "${STACK_DIR}/docker-compose.cosmos.yml" << 'COMPOSE_COSMOS'
services:
  cosmos-server:
    image: azukaar/cosmos-server:latest
    container_name: cosmos-server
    hostname: cosmos-server
    restart: always
    privileged: true
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /var/run/dbus/system_bus_socket:/var/run/dbus/system_bus_socket
      - /:/mnt/host
      - ./cosmos:/config
    networks:
      - proxy
networks:
  proxy:
    external: true
COMPOSE_COSMOS

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

  # Random Metabase admin password (was a hardcoded, publicly-known string).
  METABASE_PASS=$(rand_password 20)
  printf '%s' "$METABASE_PASS" > "${STACK_DIR}/.metabase_password"
  chmod 600 "${STACK_DIR}/.metabase_password"

  cat > "${STACK_DIR}/docker-compose.crowdsec.yml" << 'COMPOSE_CROWDSEC'
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
COMPOSE_CROWDSEC

    cat >> "${STACK_DIR}/docker-compose.crowdsec.yml" << DASHBOARD
  crowdsec-dashboard:
    image: metabase/metabase:latest
    container_name: crowdsec-dashboard
    restart: unless-stopped
    volumes:
      - ./crowdsec/data/crowdsec.db:/metabase-data/crowdsec.db:ro
      - ./crowdsec/metabase.db.mv.db:/app/metabase.db.mv.db
    environment:
      - MB_ADMIN_EMAIL=crowdsec@crowdsec.net
      - MB_ADMIN_PASSWORD=${METABASE_PASS}
    networks:
      - proxy
DASHBOARD

  cat >> "${STACK_DIR}/docker-compose.crowdsec.yml" << 'NETS'
networks:
  proxy:
    external: true
NETS

  if command -v curl &>/dev/null; then
    if [ ! -f "$CROWDSEC_DIR/metabase.db.mv.db" ]; then
      curl -sL -o /tmp/metabase_sqlite.zip https://crowdsec-statics-assets.s3-eu-west-1.amazonaws.com/metabase_sqlite.zip
      command -v unzip &>/dev/null && unzip -o /tmp/metabase_sqlite.zip -d "$CROWDSEC_DIR" && rm -f /tmp/metabase_sqlite.zip
      chown 1000:1000 "$CROWDSEC_DIR/metabase.db.mv.db" 2>/dev/null || true
    fi
  elif command -v wget &>/dev/null; then
    if [ ! -f "$CROWDSEC_DIR/metabase.db.mv.db" ]; then
      wget -qO /tmp/metabase_sqlite.zip https://crowdsec-statics-assets.s3-eu-west-1.amazonaws.com/metabase_sqlite.zip
      command -v unzip &>/dev/null && unzip -o /tmp/metabase_sqlite.zip -d "$CROWDSEC_DIR" && rm -f /tmp/metabase_sqlite.zip
      chown 1000:1000 "$CROWDSEC_DIR/metabase.db.mv.db" 2>/dev/null || true
    fi
  else
    [ ! -f "$CROWDSEC_DIR/metabase.db.mv.db" ] && warn "Metabase template not found — dashboard may not have pre-loaded collections"
  fi
  docker compose -f "${STACK_DIR}/docker-compose.npm.yml" pull
  docker compose -f "${STACK_DIR}/docker-compose.cosmos.yml" pull
  docker compose -f "${STACK_DIR}/docker-compose.authelia.yml" pull
  docker compose -f "${STACK_DIR}/docker-compose.crowdsec.yml" pull
  info "Starting NPM..."
  docker compose -f "${STACK_DIR}/docker-compose.npm.yml" up -d
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
    if [[ $i -eq 30 ]]; then
      echo ""; echo "  Port 80 bound:  $has_80"; echo "  Port 443 bound: $has_443"; echo "  Port 81 bound:  $has_81"; echo ""
      ss -tlnp 2>/dev/null | grep -E ':80 |:443 |:81 ' || true; echo ""
      fatal "NPM failed to bind required ports. Check: docker logs npm"
    fi
    printf "\r  Waiting for NPM ports... %2d/30" "$i"
    sleep 2
  done
  printf "\n"
  info "Waiting for NPM container..."
  for i in $(seq 1 30); do
    docker ps --format '{{.Names}}' | grep -qx "npm" && { success "NPM container running"; break; }
    printf "\r  Waiting... %2d/30" "$i"
    [[ $i -eq 30 ]] && { printf "\n"; warn "NPM container not detected after 60s"; }
    sleep 2
  done
  printf "\n"
  info "Waiting for NPM admin UI (port 81)..."
  for i in $(seq 1 60); do
    curl -sf --max-time 5 http://127.0.0.1:81/ &>/dev/null && { success "NPM admin UI responding"; break; }
    printf "\r  Waiting... %2d/60" "$i"
    [[ $i -eq 60 ]] && { printf "\n"; warn "NPM UI timed out (2m). Still starting?"; }
    sleep 2
  done
  printf "\n"
  info "Waiting for NPM log files..."
  for i in $(seq 1 30); do
    if ls "${NPM_LOGS_DIR}/"*_access.log "${NPM_LOGS_DIR}/"*_error.log &>/dev/null; then
      success "NPM logs present"
      break
    fi
    printf "\r  Waiting... %2d/30" "$i"
    if [[ $i -eq 30 ]]; then
      printf "\n"
      warn "NPM logs not created yet. Creating placeholders."
      touch "${NPM_LOGS_DIR}/fallback_http_access.log" \
            "${NPM_LOGS_DIR}/fallback_http_error.log" \
            "${NPM_LOGS_DIR}/default-host_access.log" \
            "${NPM_LOGS_DIR}/default-host_error.log"
    fi
    sleep 2
  done
  printf "\n"
  info "Starting Cosmos Server..."
  docker compose -f "${STACK_DIR}/docker-compose.cosmos.yml" up -d
  info "Starting CrowdSec..."
  docker compose -f "${STACK_DIR}/docker-compose.crowdsec.yml" up -d crowdsec
  info "Waiting for CrowdSec container to be ready..."
  for i in $(seq 1 30); do
    docker ps --format '{{.Names}}' | grep -qx "crowdsec" && { success "CrowdSec container running"; break; }
    printf "${C_DIM}  Waiting for CrowdSec container... (%d/30)${C_R}\r" "$i"
    [[ $i -eq 30 ]] && warn "CrowdSec container not found"
    sleep 2
  done
  printf "\n"
  info "Starting CrowdSec Dashboard..."
  docker compose -f "${STACK_DIR}/docker-compose.crowdsec.yml" up -d crowdsec-dashboard
  info "Waiting for CrowdSec Dashboard to be ready..."
  for i in $(seq 1 30); do
    docker ps --format '{{.Names}}' | grep -qx "crowdsec-dashboard" && { success "CrowdSec Dashboard ready"; break; }
    printf "${C_DIM}  Waiting for CrowdSec Dashboard... (%d/30)${C_R}\r" "$i"
    [[ $i -eq 30 ]] && warn "CrowdSec Dashboard timeout"
    sleep 2
  done
  printf "\n"
  info "Waiting for Cosmos Server..."
  for i in $(seq 1 60); do
    docker ps --format '{{.Names}}' | grep -qx "cosmos-server" && { success "Cosmos Server responding"; break; }
    printf "\r  Waiting... %2d/60" "$i"
    [[ $i -eq 60 ]] && { printf "\n"; warn "Cosmos timed out (3m). Check: docker logs cosmos-server"; }
    sleep 3
  done
  printf "\n"
  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<VPS_IP>")
  success "Stack deployed: NPM at http://${ip}:81, Cosmos proxied via http://cosmos-server:80, Authelia at http://authelia:9091"
}
setup_firewall() {
  step "Firewall Configuration"
  info "Configuring firewall..."
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
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  local ssh_port; ssh_port=$(detect_ssh_port)
  ufw limit "${ssh_port}/tcp"
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
\1\n  \2   docker exec crowdsec cscli metrics
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
  local npm_password mb_pass
  npm_password=$(_read_cred "${STACK_DIR}/.npm_admin_password")
  mb_pass=$(_read_cred "${STACK_DIR}/.metabase_password")
  local crowdsec_display="crowdsec    crowdsec     8080 (LAPI)        crowdsec.${DOMAIN}"
    dns_crowdsec="  A  crowdsec.${DOMAIN}   ? ${ip}  (CrowdSec Dashboard)"
    proxy_crowdsec=$(cat << CROWDPROXY
    ${C_B}CrowdSec Dashboard:${C_R}
    +----------------------------------------------+
    ? Domain Names:    crowdsec.${DOMAIN}           ?
    ? Scheme:          http                         ?
    ? Forward Host:    crowdsec-dashboard           ?
    ? Forward Port:    3000                         ?
    ? Login:           crowdsec@crowdsec.net        ?
    ? Password:        ${mb_pass}       ?
    ? Block Exploits:  ON                           ?
    ? Access List:     Publicly Accessible          ?
    +----------------------------------------------+
    Save ? SSL tab ? Request cert ? Force SSL ON
    ? Dashboard is read-only ? no Authelia 2FA needed
CROWDPROXY
)
  printf "\n"
  printf "${C_B}${C_GRN}+------------------------------------------------------------------------------+${C_R}\n"
  printf "${C_B}${C_GRN}?                   ??  DEPLOYMENT SUMMARY                                     ?${C_R}\n"
  printf "${C_B}${C_GRN}?------------------------------------------------------------------------------?${C_R}\n"
  printf "${C_B}?  ${SCRIPT_NAME} v${SCRIPT_VERSION}                                                   ?${C_R}\n"
  printf "${C_B}?  Duration: ${C_CYN}%dm %ds${C_R}${C_B}                                                    ?${C_R}\n" $(( elapsed / 60 )) $(( elapsed % 60 ))
  printf "${C_B}?  VPS IP:   ${C_CYN}%-16s${C_R}${C_B}                                                   ?${C_R}\n" "$ip"
  printf "${C_B}?  External: ${C_CYN}%-16s${C_R}${C_B}                                                   ?${C_R}\n" "$ext_ip"
  printf "${C_B}+------------------------------------------------------------------------------+${C_R}\n"
  printf "\n"
  cat << EOF
${C_B}${C_CYN}-- SERVICES --${C_R}
${C_B}Nginx Proxy Manager${C_R}
  Admin UI:  http://${ip}:81
  HTTP:      http://${ip}:80
  HTTPS:     https://${ip}:443
  Data:      ${NPM_DATA_DIR}
  SSL certs: ${NPM_LE_DIR}
  Logs:      ${NPM_LOGS_DIR}
${C_B}Cosmos Server${C_R}
  Container: cosmos-server
  Port:      80 (internal, no host port)
  Network:   proxy
${C_B}${C_YEL}----------------------------------------------------------------${C_R}
${C_B}${C_YEL}  ??  AUTHELIA LOGIN CREDENTIALS (SAVE THESE)${C_R}
${C_B}${C_YEL}----------------------------------------------------------------${C_R}
  ${C_B}URL:${C_R}       https://authelia.${DOMAIN}
  ${C_B}Username:${C_R}  ${C_CYN}admin${C_R}
  ${C_B}Config:${C_R}    ${AUTHELIA_CONFIG_DIR}
  ${C_B}Secrets:${C_R}   ${AUTHELIA_SECRETS_DIR}
  ${C_B}Snippets:${C_R}  ${AUTHELIA_SNIPPETS_DIR}
EOF
  local display_pass
  display_pass=$(_read_cred "${AUTHELIA_DIR}/.default_password")
  printf "  ${C_B}Password:${C_R}  ${C_CYN}%s${C_R}\n" "$display_pass"
  printf "\n  ${C_RED}??  Change this password immediately after first login!${C_R}\n"
cat << EOF
${C_B}Docker${C_R}    $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo N/A)
${C_B}Containers${C_R}  npm, cosmos-server, authelia, crowdsec (separate compose files)
${C_B}Network${C_R}   proxy (bridge)
${C_B}${C_GRN}-- NPM Proxy Forwarding --------------------------------------${C_R}
${C_B}Domain${C_R}                     ${C_B}Forward to${C_R}
${C_DIM}--------------------------  --------------------------${C_R}
authelia.${DOMAIN}          ? authelia:9091
cosmos.${DOMAIN}            ? cosmos-server:80
crowdsec.${DOMAIN}         ? crowdsec-dashboard:3000
${C_B}CROWDSEC${C_R}  Collections: sshd, nginx-proxy-manager, linux
${C_B}Firewall${C_R}  $(if [[ "$OS_FAMILY" == "debian" ]]; then echo "UFW"; else echo "firewalld"; fi)
${C_B}${C_YEL}Step 1 -- NPM Admin${C_R}
  Open:   http://${ip}:81
  Login:  admin@example.com / ${npm_password}
  ${C_RED}? Change password immediately${C_R}
${C_B}${C_YEL}Step 2 -- Add DNS Records${C_R}
  A  authelia.${DOMAIN}   ? ${ip}
  A  cosmos.${DOMAIN}     ? ${ip}
  ${dns_crowdsec}
  A  *.${DOMAIN}          ? ${ip}  (wildcard for other services)
${C_B}${C_YEL}Step 3 -- Add Proxy Hosts in NPM${C_R}
  A) Authelia Portal
     Dashboards ? Proxy Hosts ? Add Proxy Host
     +------------------------------------------+
     ? Domain Names:    authelia.${DOMAIN}       ?
     ? Scheme:          http                    ?
     ? Forward Host:    authelia                ?
     ? Forward Port:    9091                    ?
     ? Block Exploits:  ON                      ?
     +------------------------------------------+
     Click Save
  B) Cosmos Dashboard
     Dashboards ? Proxy Hosts ? Add Proxy Host
     +------------------------------------------+
     ? Domain Names:    cosmos.${DOMAIN}         ?
     ? Scheme:          http                    ?
     ? Forward Host:    cosmos-server           ?
     ? Forward Port:    80                      ?
     ? Block Exploits:  ON                      ?
     ? Custom Locations:                        ?
     ?   Include authelia auth snippets         ?
     +------------------------------------------+
     Click Save
${proxy_crowdsec}
${C_B}${C_YEL}Step 4 -- SSL Certificates${C_R}
  On each proxy host ? SSL tab
  +------------------------------------------+
  ? SSL:             Request a new cert      ?
  ? Force SSL:       ON                      ?
  ? HTTP/2 Support:  ON                      ?
  ? Email:           your-email@${DOMAIN}    ?
  ? Agree to TOS:    ON                      ?
  +------------------------------------------+
  Click Save
${C_B}${C_YEL}Step 5 -- Configure Authelia Protection${C_R}
  In NPM Advanced tab for cosmos.${DOMAIN}, add:
    include /opt/cosmos-stack/authelia/snippets/authelia-authrequest.conf;
  Create location @authelia_signin:
    return 302 https://authelia.${DOMAIN}/?rd=\$scheme://\$http_host\$request_uri;
${C_B}${C_YEL}Step 6 -- Register TOTP Device${C_R}
  Visit https://authelia.${DOMAIN}
  Username: admin
  Password: (see credential box above)
  Follow prompts to register your authenticator app
${C_B}${C_YEL}Step 7 -- Secure Admin Port${C_R}
  $(if [[ "$OS_FAMILY" == "debian" ]]; then echo "  ufw delete allow 81/tcp && ufw reload"; else echo "  firewall-cmd --permanent --remove-port=81/tcp && firewall-cmd --reload"; fi)
${C_B}${C_YEL}Step 8 -- Change Default Password${C_R}
  ${C_RED}IMPORTANT:${C_R} Change the default Authelia password immediately:
    1. Login to https://authelia.${DOMAIN}
    2. Go to Settings ? Password
    3. Or edit ${AUTHELIA_CONFIG_DIR}/users.yml and restart authelia
${C_B}${C_CYN}-- TROUBLESHOOTING --${C_R}
  Logs:       docker logs -f npm   docker logs -f cosmos-server   docker logs -f authelia
  Restart:    cd ${STACK_DIR} && docker compose -f docker-compose.npm.yml restart
              cd ${STACK_DIR} && docker compose -f docker-compose.cosmos.yml restart
              cd ${STACK_DIR} && docker compose -f docker-compose.authelia.yml restart
              cd ${STACK_DIR} && docker compose -f docker-compose.crowdsec.yml restart
  CrowdSec:   cscli metrics    cscli decisions list
  Firewall:   ${fw_cmd}
  Deploy log: ${LOG_FILE}
EOF
  _log "INFO" "=== Deployment completed in $(( elapsed / 60 ))m $(( elapsed % 60 ))s ==="
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
    return 0
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

register_cosmos_stacks() {
  step "Registering editable stacks in Cosmos"
  local stacks_dir="${COSMOS_DATA_DIR}/imports"
  mkdir -p "$stacks_dir"

  for stack in npm authelia crowdsec; do
    local compose_file="${STACK_DIR}/docker-compose.${stack}.yml"
    [[ ! -f "$compose_file" ]] && continue

    local target="${stacks_dir}/${stack}.yml"
    cp "$compose_file" "$target" 2>/dev/null || true

    if [[ -f "$target" ]]; then
      success "Cosmos stack saved: ${stack}"
    else
      warn "Failed to save Cosmos stack: ${stack}"
    fi
  done

  info "Compose files saved to ${stacks_dir}/"
  info "Import them via Cosmos UI -> Stacks -> Import"
  info "Cosmos API import: cosmos-cli stack create --file <path> (if available)"
}

main() {
  printf "\n${C_B}${C_CYN}VPS Deployment -- Docker + NPM + Cosmos + Authelia + CrowdSec${C_R}\n"
  printf "${C_DIM}${SCRIPT_NAME} v${SCRIPT_VERSION}${C_R}\n\n"
  preflight_checks
  idempotent_cleanup
  system_update
  install_dependencies
  install_docker
  setup_docker_network
  get_user_domain
  setup_authelia_secrets
  setup_authelia_config
  setup_authelia_snippets
  setup_stack
  setup_authelia_users
  setup_firewall
  setup_crowdsec
  setup_logrotate
  register_cosmos_stacks
  verify_deployment
  DEPLOY_STATUS="success"
  print_summary
}

main "$@"
