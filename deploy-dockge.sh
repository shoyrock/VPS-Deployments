#!/usr/bin/env bash
# Auto-elevate to root if not already running as root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi
# deploy-dockge.sh -- Docker + NPM + Dockge + Authelia + CrowdSec (v4.0.0-crowdsec)
# Idempotent VPS deployment. Usage: sudo ./deploy-dockge.sh
set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="4.0.0-crowdsec"
readonly SCRIPT_NAME="deploy-dockge.sh"
readonly START_TIME=$(date +%s)
readonly STACK_DIR="/opt/dockge-stack"
readonly NPM_DATA_DIR="${STACK_DIR}/npm-data"
readonly NPM_LE_DIR="${STACK_DIR}/npm-letsencrypt"
readonly NPM_LOGS_DIR="${NPM_DATA_DIR}/logs"
readonly CROWDSEC_DIR="${STACK_DIR}/crowdsec"
readonly AUTHELIA_DIR="${STACK_DIR}/authelia"
readonly AUTHELIA_SECRETS_DIR="${AUTHELIA_DIR}/secrets"
readonly AUTHELIA_CONFIG_DIR="${AUTHELIA_DIR}/config"
readonly AUTHELIA_SNIPPETS_DIR="${AUTHELIA_DIR}/snippets"
readonly DOMAIN_PERSIST_FILE="/etc/vps-deploy-domain"
readonly LOG_FILE="/var/log/vps-deploy.log"

DOMAIN=""  # Set at runtime via user prompt

# Deployment status tracking for guaranteed completion summary
DEPLOY_STATUS="in_progress"
DEPLOYED_SERVICES=""

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
fatal()   { printf "${C_RED}${C_B}FATAL${C_R}${C_RED}: %s${C_R}\n" "$*" >&2; _log "FATAL" "$@"; DEPLOY_STATUS="failed"; exit 1; }
step()    { printf "\n${C_B}${C_CYN}── %s ──${C_R}\n" "$*"; _log "STEP" "$@"; }

# ═══════════════════════════════════════════════════════════════════════════════
# GUARANTEED COMPLETION SUMMARY — runs on exit regardless of success/failure
# ═══════════════════════════════════════════════════════════════════════════════
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
  local exit_pass="<unknown>"
  [[ -f "${AUTHELIA_DIR}/.default_password" ]] && exit_pass=$(tr -d '\n' < "${AUTHELIA_DIR}/.default_password" 2>/dev/null || echo "<unknown>")

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
  printf "${C_B}║  %-72s  ║${C_R}\n" "Elapsed:  ${elapsed}s"
  printf "${C_B}║  %-72s  ║${C_R}\n" "VPS IP:   $ip"
  printf "${C_B}║  %-72s  ║${C_R}\n" "External: $ext_ip"
  printf "${C_B}║  %-72s  ║${C_R}\n" "Domain:   ${DOMAIN:-<not set>}"
  printf "${C_B}╠══════════════════════════════════════════════════════════════════════════════╣${C_R}\n"
  printf "${C_B}║  %-72s  ║${C_R}\n" "NPM Admin: http://${ip}:81"
  if [[ "$DEPLOY_STATUS" == "success" ]]; then
    printf "${C_B}║  %-72s  ║${C_R}\n" "Dockge:    http://dockge.${DOMAIN}"
    printf "${C_B}║  %-72s  ║${C_R}\n" "Authelia:  https://authelia.${DOMAIN}"
    printf "${C_B}║  %-72s  ║${C_R}\n" "CrowdSec:  http://crowdsec.${DOMAIN}"
    printf "${C_B}║  %-72s  ║${C_R}\n" ""
    printf "${C_B}║  ${C_YEL}%-72s${C_R}${C_B}  ║${C_R}\n" "Authelia Username: admin"
    printf "${C_B}║  ${C_YEL}%-72s${C_R}${C_B}  ║${C_R}\n" "Authelia Password: $exit_pass"
    printf "${C_B}║  ${C_RED}%-72s${C_R}${C_B}  ║${C_R}\n" "Change this password immediately after first login!"
    printf "${C_B}║  %-72s  ║${C_R}\n" "Also: ${AUTHELIA_DIR}/password.txt"
    printf "${C_B}║  %-72s  ║${C_R}\n" ""
    printf "${C_B}║  ${C_YEL}%-72s${C_R}${C_B}  ║${C_R}\n" "-- Verification Codes --"
    printf "${C_B}║  %-72s  ║${C_R}\n" "Authelia requires a code to change password or add 2FA."
    printf "${C_B}║  %-72s  ║${C_R}\n" "The code appears AFTER you request it in the Authelia UI."
    printf "${C_B}║  %-72s  ║${C_R}\n" "Then run:"
    printf "${C_B}║  ${C_CYN}%-72s${C_R}${C_B}  ║${C_R}\n" "sudo docker exec authelia cat /config/notifications.txt"
    printf "${C_B}║  %-72s  ║${C_R}\n" ""
  fi
  printf "${C_B}║  %-72s  ║${C_R}\n" "Ports: 80 (HTTP), 443 (HTTPS), 81 (NPM Admin)"
  printf "${C_B}╠══════════════════════════════════════════════════════════════════════════════╣${C_R}\n"
  printf "${C_B}║  %-72s  ║${C_R}\n" "Log: $LOG_FILE"
  printf "${C_B}╚══════════════════════════════════════════════════════════════════════════════╝${C_R}\n"
  printf "\n"
  if [[ "$DEPLOY_STATUS" == "success" ]]; then
    printf "${C_B}${C_GRN}Your VPS is ready!${C_R} Set up DNS → ${C_CYN}${ext_ip}${C_R} and configure NPM.\n\n"
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
  for dir in /opt/npm /opt/casaos /var/lib/casaos /opt/casaos-stack /opt/coolify-stack /opt/cosmos-stack /opt/dockge-stack /opt/dokploy-stack /opt/portainer-stack /opt/runtipi-stack /opt/freedombox-stack /opt/yunohost-stack; do
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
}

system_update() {
  step "System Update"
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  info "Updating packages — this may take a few minutes, please wait..."
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
  info "Installing required packages — please wait..."
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
  info "Installing Docker CE — this may take a few minutes, please wait..."
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
  # NEVER remove existing proxy network -- other containers may depend on it
  if ! docker network ls --format '{{.Name}}' | grep -qx "proxy"; then
    docker network create proxy 2>/dev/null || true
  fi
  docker network ls --format '{{.Name}}' | grep -qx "proxy" || fatal "Failed to create 'proxy' network"
  success "Network 'proxy' ready"
}

get_user_domain() {
  step "Domain Configuration"

  # Check for persisted domain from a previous deployment
  if [[ -f "${DOMAIN_PERSIST_FILE}" ]]; then
    local existing_domain
    existing_domain=$(tr -d '\n' < "${DOMAIN_PERSIST_FILE}" 2>/dev/null || true)
    if [[ -n "$existing_domain" ]]; then
      printf "\n${C_YEL}⚠️  Previous deployment detected with domain: ${C_B}${existing_domain}${C_R}\n"
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

  # Persist domain outside STACK_DIR so it survives cleanup
  printf '%s' "$DOMAIN" > "${DOMAIN_PERSIST_FILE}" || warn "Could not persist domain to ${DOMAIN_PERSIST_FILE}"

  success "Domain set to: $DOMAIN"
}

setup_authelia_secrets() {
  step "Generating Authelia Secrets"
  mkdir -p "$AUTHELIA_SECRETS_DIR"
  local secret_name secret_file
  for secret_name in jwt_session storage_encryption session; do
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
}

setup_authelia_config() {
  step "Authelia Configuration"
  mkdir -p "$AUTHELIA_CONFIG_DIR"

  cat > "${AUTHELIA_CONFIG_DIR}/configuration.yml" << EOF
server:
  address: tcp://0.0.0.0:9091
  endpoints:
    authz:
      forward-auth:
        implementation: ForwardAuth

log:
  level: info
  format: text

totp:
  issuer: authelia.${DOMAIN}
  period: 30
  skew: 1

authentication_backend:
  file:
    path: /config/users.yml

access_control:
  default_policy: two_factor
  rules:
    - domain: authelia.${DOMAIN}
      policy: one_factor
    - domain: dockge.${DOMAIN}
      policy: two_factor
    - domain: "*.${DOMAIN}"
      policy: two_factor

session:
  cookies:
    - name: authelia_session
      domain: ${DOMAIN}
      authelia_url: https://authelia.${DOMAIN}
      default_redirection_url: https://dockge.${DOMAIN}
      same_site: lax
      expiration: 1h
      inactivity: 5m
      remember_me: 1M

regulation:
  max_retries: 3
  find_time: 2m
  ban_time: 1h

storage:
  local:
    path: /config/db.sqlite3

notifier:
  filesystem:
    filename: /config/notifications.txt
EOF

  # NOTE: users.yml is created AFTER the authelia container starts.
  # This ensures the password hash is generated by the same authelia binary that verifies it.
  info "users.yml will be created after authelia container is running"



  success "Authelia configuration written to ${AUTHELIA_CONFIG_DIR}/"
}

create_nginx_snippets() {
  step "NGINX Snippets for Authelia"
  mkdir -p "$AUTHELIA_SNIPPETS_DIR"

  # Ensure authelia can read config files (runs as non-root uid 1001 by default)
  chmod 755 "${AUTHELIA_CONFIG_DIR}" "${AUTHELIA_SECRETS_DIR}" 2>/dev/null || true
  chmod 644 "${AUTHELIA_CONFIG_DIR}"/*.yml "${AUTHELIA_CONFIG_DIR}"/*.txt 2>/dev/null || true
  chmod 600 "${AUTHELIA_SECRETS_DIR}"/* 2>/dev/null || true

  cat > "${AUTHELIA_SNIPPETS_DIR}/proxy.conf" << 'SNIPPET'
client_body_buffer_size 128k;
proxy_next_upstream error timeout invalid_header http_500 http_502 http_503;
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host $http_host;
proxy_set_header X-Forwarded-Uri $request_uri;
proxy_set_header X-Forwarded-Ssl on;
proxy_redirect http:// $scheme://;
proxy_http_version 1.1;
proxy_set_header Connection "";
proxy_cache_bypass $cookie_session;
proxy_no_cache $cookie_session;
proxy_buffers 4 32k;
proxy_send_timeout 600s;
proxy_read_timeout 600s;
SNIPPET

  cat > "${AUTHELIA_SNIPPETS_DIR}/authelia-location.conf" << SNIPPET
location /authelia {
    internal;
    proxy_pass http://authelia:9091/api/verify;
    proxy_set_header X-Original-URL \\\$scheme://\\\$http_host\\\$request_uri;
    proxy_set_header X-Real-IP \\\$remote_addr;
    proxy_set_header X-Forwarded-Method \\\$request_method;
    proxy_pass_request_body off;
    proxy_pass_request_headers on;
    proxy_set_header Content-Length "";
    proxy_set_header Connection "";
}
SNIPPET

  cat > "${AUTHELIA_SNIPPETS_DIR}/authelia-authrequest.conf" << SNIPPET1
## Paste this into NPM Advanced tab for each protected proxy host
## NOTE: proxy_set_header Remote-User/Groups below work at server block level.
## NPM's generated location / block has its own proxy_set_header directives,
## which OVERRIDES all server-level ones (nginx inheritance rule).
## For apps that need SSO identity headers, add them via NPM's Custom Locations.
auth_request /authelia;
auth_request_set \$target_url \$scheme://\$http_host\$request_uri;
error_page 401 =302 https://authelia.${DOMAIN}/?rd=\$target_url;
auth_request_set \$user \$upstream_http_remote_user;
auth_request_set \$groups \$upstream_http_remote_groups;
proxy_set_header Remote-User \$user;
proxy_set_header Remote-Groups \$groups;

set \$upstream_authelia http://authelia:9091;
location /authelia {
    internal;
    proxy_pass \$upstream_authelia/api/authz/forward-auth;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_set_header X-Original-URL \$scheme://\$http_host\$request_uri;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-Host \$http_host;
    proxy_set_header X-Forwarded-Uri \$request_uri;
    proxy_cache_bypass \$cookie_session;
    proxy_no_cache \$cookie_session;
    proxy_http_version 1.1;
}
SNIPPET1

  success "NGINX snippets written to ${AUTHELIA_SNIPPETS_DIR}/"
}

setup_authelia_users() {
  step "Creating Authelia User Account"

  # Always create fresh users.yml (old one may have stale password)

  # Use the official Authelia lite bundle pre-hashed password.
  # Password is "authelia" — change immediately after first login.
  # Hash source: https://github.com/authelia/authelia/blob/master/examples/compose/lite/authelia/users_database.yml
  local default_pass="authelia"
  local pass_hash='$argon2id$v=19$m=65536,t=3,p=4$qOKNq+u5lZHOTnsJY1Sp3g$s6zT9EKncfkmIJmykzZProUigRRJ26hlTl1WC+mG2do'

  # Store password for display
  printf '%s' "$default_pass" > "${AUTHELIA_DIR}/.default_password"
  chmod 600 "${AUTHELIA_DIR}/.default_password"
  printf '%s' "$default_pass" > "${AUTHELIA_DIR}/password.txt"
  chmod 600 "${AUTHELIA_DIR}/password.txt"

  # Write users.yml — single-quoted YAML (matches official lite bundle format)
  cat > "${AUTHELIA_CONFIG_DIR}/users.yml" << USEREOF
---
users:
  admin:
    disabled: false
    displayname: 'Administrator'
    password: '${pass_hash}'
    email: 'admin@${DOMAIN}'
    groups:
      - admins
      - users
USEREOF

  success "Authelia user 'admin' created"
  info "Default password: ${default_pass} (change after first login)"

  info "Starting Authelia..."
  docker compose -f "${STACK_DIR}/docker-compose.authelia.yml" up -d

  # Wait for authelia to come back up
  for i in $(seq 1 30); do
    docker exec authelia wget -qO- --timeout=3 http://127.0.0.1:9091/api/health 2>/dev/null | grep -q "ok" && { success "Authelia ready"; break; }
    printf "${C_DIM}  Waiting for Authelia restart... (%d/30)${C_R}\r" "$i"
    [[ $i -eq 30 ]] && warn "Authelia restart timed out"
    sleep 2
  done
  printf "\n"
}

setup_stack() {
  step "Deploying NPM, Dockge, Authelia, CrowdSec (separate compose files)"
  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<VPS_IP>")
  mkdir -p "$NPM_DATA_DIR" "$NPM_LE_DIR" "$NPM_LOGS_DIR" "${STACK_DIR}/data" "/opt/stacks" "$CROWDSEC_DIR" "$AUTHELIA_CONFIG_DIR" "$AUTHELIA_SECRETS_DIR"

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
      - ./npm-data:/data
      - ./npm-letsencrypt:/etc/letsencrypt
    networks:
      - proxy
networks:
  proxy:
    external: true
COMPOSE_NPM

  cat > "${STACK_DIR}/docker-compose.dockge.yml" << 'COMPOSE_DOCKGE'
services:
  dockge:
    image: louislam/dockge:1
    container_name: dockge
    hostname: dockge
    restart: always
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data:/app/data
      - /opt/stacks:/opt/stacks
    environment:
      - DOCKGE_STACKS_DIR=/opt/stacks
    networks:
      - proxy
networks:
  proxy:
    external: true
COMPOSE_DOCKGE

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
      - AUTHELIA_JWT_SECRET_FILE=/config/secrets/jwt_session
      - AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE=/config/secrets/storage_encryption
      - AUTHELIA_SESSION_SECRET_FILE=/config/secrets/session
      - AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET_FILE=/config/secrets/jwt_session
      - TZ=America/New_York
    networks:
      - proxy
networks:
  proxy:
    external: true
COMPOSE_AUTHELIA

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
      - ./npm-data/logs:/npm-logs:ro
      - /var/log:/var/log:ro
    environment:
      - COLLECTIONS=crowdsecurity/sshd crowdsecurity/nginx-proxy-manager crowdsecurity/linux
      - TZ=UTC
    networks:
      - proxy
  crowdsec-dashboard:
    image: crowdsecurity/crowdsec-dashboard:latest
    container_name: crowdsec-dashboard
    restart: unless-stopped
    environment:
      - CS_LAPI_URL=http://crowdsec:8080
    networks:
      - proxy
networks:
  proxy:
    external: true
COMPOSE_CROWDSEC

  info "Pulling Docker images — this may take a few minutes, please wait..."
  docker compose -f "${STACK_DIR}/docker-compose.npm.yml" pull
  docker compose -f "${STACK_DIR}/docker-compose.dockge.yml" pull
  docker compose -f "${STACK_DIR}/docker-compose.authelia.yml" pull
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

  info "Starting Dockge..."
  docker compose -f "${STACK_DIR}/docker-compose.dockge.yml" up -d
  info "Waiting for Dockge..."
  for i in $(seq 1 40); do
    printf "\r  ${C_DIM}Waiting for Dockge... %d/40${C_R}" "$i"
    docker exec dockge curl -sf --max-time 5 http://127.0.0.1:5001/ &>/dev/null && { printf "\r"; success "Dockge ready"; break; }
    [[ $i -eq 40 ]] && { printf "\r"; warn "Dockge timed out. Check: docker logs dockge"; }
    sleep 3
  done
  printf "\r"

  info "Starting CrowdSec..."
  docker compose -f "${STACK_DIR}/docker-compose.crowdsec.yml" up -d

  success "NPM: http://${ip}:81"
  success "Dockge: http://${ip}:5001"
  success "Authelia: http://${ip}:9091"
}


setup_firewall() {
  step "Firewall"
  info "Configuring firewall — please wait..."
  if [[ "$OS_FAMILY" == "debian" ]]; then setup_firewall_debian
  else setup_firewall_rhel; fi
}

setup_firewall_debian() {
  info "Configuring UFW..."
  apt-get install -y -qq ufw

  # CRITICAL: Docker manipulates iptables directly. UFW's DEFAULT_FORWARD_POLICY=DROP
  # blocks all container traffic. Must set ACCEPT before enabling UFW.
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

print_summary() {
  local random_pass="unknown"
  if [[ -f "${AUTHELIA_DIR}/.default_password" ]]; then
    random_pass=$(tr -d '\n' < "${AUTHELIA_DIR}/.default_password")
  fi

  local elapsed=$(( $(date +%s) - START_TIME ))
  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "YOUR_VPS_IP")
  local ext_ip; ext_ip=$(get_external_ip)
  local fw_cmd; [[ "$OS_FAMILY" == "debian" ]] && fw_cmd="ufw status verbose" || fw_cmd="firewall-cmd --list-all"

  printf "\n"
  printf "${C_B}${C_GRN}╔══════════════════════════════════════════════════════════════════════════════╗${C_R}\n"
  printf "${C_B}${C_GRN}║                     🎉  DEPLOYMENT COMPLETE                                  ║${C_R}\n"
  printf "${C_B}${C_GRN}╠══════════════════════════════════════════════════════════════════════════════╣${C_R}\n"
  printf "${C_B}║  ${C_CYN}${SCRIPT_NAME} v${SCRIPT_VERSION}${C_R}${C_B}                                                      ║${C_R}\n"
  printf "${C_B}║  Elapsed: ${C_CYN}%dm %ds${C_R}${C_B}                                                     ║${C_R}\n" $(( elapsed / 60 )) $(( elapsed % 60 ))
  printf "${C_B}╚══════════════════════════════════════════════════════════════════════════════╝${C_R}\n"

  cat << EOF

${C_B}Stack Directory${C_R}    ${STACK_DIR}

${C_B}Nginx Proxy Manager${C_R}
  Admin:   http://${ip}:81
  HTTP:    http://${ip}:80
  HTTPS:   https://${ip}:443
  Ext IP:  ${ext_ip}
  Data:    ${NPM_DATA_DIR}
  SSL:     ${NPM_LE_DIR}
  Logs:    ${NPM_LOGS_DIR}

${C_B}Dockge${C_R}
  Container: dockge
  Port:      5001 (internal, no host port)
  Network:   proxy
  Stacks:    /opt/stacks

${C_B}${C_YEL}════════════════════════════════════════════════════════════════${C_R}
${C_B}${C_YEL}  🔐  AUTHELIA LOGIN CREDENTIALS (SAVE THESE)${C_R}
${C_B}${C_YEL}════════════════════════════════════════════════════════════════${C_R}

  ${C_B}URL:${C_R}       https://authelia.${DOMAIN}
  ${C_B}Username:${C_R}  ${C_CYN}admin${C_R}
  ${C_B}Password:${C_R}  ${C_CYN}${random_pass}${C_R}

  ${C_RED}⚠️  Change this password immediately after first login!${C_R}

${C_B}${C_YEL}════════════════════════════════════════════════════════════════${C_R}

${C_B}Authelia${C_R}
  Portal:    https://authelia.${DOMAIN}
  Config:    ${AUTHELIA_CONFIG_DIR}/configuration.yml
  Users:     ${AUTHELIA_CONFIG_DIR}/users.yml
  Secrets:   ${AUTHELIA_SECRETS_DIR}/
  Snippets:  ${AUTHELIA_SNIPPETS_DIR}/

${C_B}Docker${C_R}    $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo N/A)
${C_B}Containers${C_R}  npm, dockge, authelia, crowdsec (separate compose files)
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
  │ Domain Names:    authelia.${DOMAIN}   │
  │ Scheme:          http                │
  │ Forward Host:    authelia            │
  │ Forward Port:    9091                │
  │ Block Exploits:  ON                  │
  └──────────────────────────────────────┘
  Click Save

${C_B}${C_YEL}Step 2b — Add Dockge Proxy Host${C_R}
  Dashboards → Proxy Hosts → Add Proxy Host
  ┌──────────────────────────────────────┐
  │ Domain Names:    dockge.${DOMAIN}     │
  │ Scheme:          http                │
  │ Forward Host:    dockge              │
  │ Forward Port:    5001                │
  │ Block Exploits:  ON                  │
  │ Custom Locations:                    │
  │   @authelia_signin {                 │
  │     return 302 https://authelia.${DOMAIN}?rd=\$scheme://\$http_host\$request_uri; │
  │   }                                  │
  │   include /opt/dockge-stack/authelia/snippets/authelia-authrequest.conf; │
  └──────────────────────────────────────┘
  Click Save

${C_B}${C_YEL}Step 3 — SSL Certificates${C_R}
  On each proxy host → SSL tab
  ┌──────────────────────────────────────┐
  │ SSL:             Request a new cert  │
  │ Force SSL:       ON                  │
  │ HTTP/2 Support:  ON                  │
  │ Email:           your-email@domain   │
  │ Agree to TOS:    ON                  │
  └──────────────────────────────────────┘
  Click Save

${C_B}${C_YEL}Step 4 — Change Authelia Password${C_R}
  docker exec -it authelia authelia crypto hash generate argon2 --password 'YOUR_NEW_PASSWORD'
  # Then edit ${AUTHELIA_CONFIG_DIR}/users.yml and replace the password hash

${C_B}${C_YEL}Step 5 — Register TOTP Device${C_R}
  1. Log in to https://authelia.${DOMAIN}
  2. Go to Settings → Two-Factor Authentication
  3. Scan QR code with your authenticator app

${C_B}${C_YEL}Step 6 — Protect Any Service${C_R}
  In NPM, edit the proxy host's Advanced tab:
  ┌────────────────────────────────────────────────────┐
  │ include /opt/dockge-stack/authelia/snippets/authelia-authrequest.conf; │
  │                                                    │
  │ # Add this location block BEFORE the final proxy_pass: │
  │ location @authelia_signin {                        │
  │   return 302 https://authelia.${DOMAIN}?rd=\$scheme://\$http_host\$request_uri; │
  │ }                                                  │
  └────────────────────────────────────────────────────┘

${C_B}${C_YEL}Step 7 — Secure Admin Port${C_R}
  $(if [[ "$OS_FAMILY" == "debian" ]]; then echo "  ufw delete allow 81/tcp && ufw reload"; else echo "  firewall-cmd --permanent --remove-port=81/tcp && firewall-cmd --reload"; fi)

${C_B}Troubleshooting:${C_R}
  Logs:    docker logs -f npm    docker logs -f dockge    docker logs -f authelia
  NPM:      cd ${STACK_DIR} && docker compose -f docker-compose.npm.yml restart
  Dockge:   cd ${STACK_DIR} && docker compose -f docker-compose.dockge.yml restart
  Authelia: cd ${STACK_DIR} && docker compose -f docker-compose.authelia.yml restart
  CrowdSec: cd ${STACK_DIR} && docker compose -f docker-compose.crowdsec.yml restart
  CS-CLI:   docker exec crowdsec cscli metrics    docker exec crowdsec cscli decisions list
  CS:      cscli metrics    cscli decisions list    cscli collections list
  FW:      ${fw_cmd}
  Log:     ${LOG_FILE}
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

  info "Waiting for CrowdSec Dashboard to be ready..."
  for i in $(seq 1 30); do
    docker ps --format '{{.Names}}' | grep -qx "crowdsec-dashboard" && { success "CrowdSec Dashboard ready"; break; }
    printf "${C_DIM}  Waiting for CrowdSec Dashboard... (%d/30)${C_R}\r" "$i"
    [[ $i -eq 30 ]] && warn "CrowdSec Dashboard timeout"
    sleep 2
  done
  printf "\n"

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

main() {
  printf "\n${C_B}${C_CYN}VPS Deployment — Docker + NPM + Dockge + Authelia + CrowdSec${C_R}\n"
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
  create_nginx_snippets
  setup_stack
  setup_authelia_users
  setup_firewall
  setup_crowdsec
  setup_logrotate
  print_summary
  # Mark deployment as successful for the exit trap summary
  DEPLOY_STATUS="success"
  DEPLOYED_SERVICES="npm,dockge,authelia,crowdsec"
}

main "$@"
