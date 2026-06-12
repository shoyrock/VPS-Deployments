#!/usr/bin/env bash
# Auto-elevate to root if not already running as root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

set -euo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="3.0.0"
SCRIPT_NAME="deploy-coolify.sh"
START_TIME=$(date +%s)

NPM_DIR="/opt/npm"
NPM_DATA_DIR="${NPM_DIR}/data"
NPM_LE_DIR="${NPM_DIR}/letsencrypt"
NPM_LOGS_DIR="${NPM_DIR}/logs"
CROWDSEC_DIR="${NPM_DIR}/crowdsec"
AUTHELIA_DIR="${NPM_DIR}/authelia"
AUTHELIA_CONFIG_DIR="${AUTHELIA_DIR}/config"
AUTHELIA_SECRETS_DIR="${AUTHELIA_DIR}/secrets"
AUTHELIA_SNIPPETS_DIR="${AUTHELIA_DIR}/snippets"

LOG_FILE="/var/log/vps-deploy.log"
DOMAIN=""
CROWDSEC_CHOICE="crowdsec"

DEPLOY_STATUS="in_progress"

if [[ -t 1 ]]; then
  C_R='\e[0m'
  C_B='\e[1m'
  C_RED='\e[31m'
  C_GRN='\e[32m'
  C_YEL='\e[33m'
  C_BLU='\e[34m'
  C_CYN='\e[36m'
  C_DIM='\e[2m'
else
  C_R=''
  C_B=''
  C_RED=''
  C_GRN=''
  C_YEL=''
  C_BLU=''
  C_CYN=''
  C_DIM=''
fi

_ts() { date '+%Y-%m-%d %H:%M:%S'; }

_log() {
  local level="$1" msg="$2"
  printf "[%s] [%s] %s\n" "$(_ts)" "$level" "$msg" >> "$LOG_FILE"
}

info()    { printf "${C_BLU}[INFO]${C_R} %s\n" "$*"; _log "INFO" "$*"; }
warn()    { printf "${C_YEL}[WARN]${C_R} %s\n" "$*" >&2; _log "WARN" "$*"; }
error()   { printf "${C_RED}[ERROR]${C_R} %s\n" "$*" >&2; _log "ERROR" "$*"; }
success() { printf "${C_GRN}[OK]${C_R} %s\n" "$*"; _log "OK" "$*"; }
fatal()   {
  printf "${C_RED}[FATAL]${C_R} %s\n" "$*" >&2
  _log "FATAL" "$*"
  DEPLOY_STATUS="failed"
  exit 1
}
step()    { printf "\n${C_B}${C_CYN}── %s ──${C_R}\n" "$*"; _log "STEP" "$*"; }

get_external_ip() {
  local ext_ip
  ext_ip=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || \
           curl -sf --max-time 5 https://ifconfig.me 2>/dev/null || \
           curl -sf --max-time 5 https://icanhazip.com 2>/dev/null || \
           echo "unknown")
  printf '%s' "$ext_ip"
}

# ═══════════════════════════════════════════════════════════════════════════════
# GUARANTEED COMPLETION SUMMARY — runs on exit regardless of success/failure
# ═══════════════════════════════════════════════════════════════════════════════
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
    printf "${C_B}║  ${C_YEL}Authelia ${C_R}${C_B}:  https://${C_CYN}%-55s${C_R}${C_B}║${C_R}\n" "auth.${DOMAIN:-yourdomain.com} (via NPM)"
    if [[ "$DEPLOY_STATUS" == "success" ]]; then
      printf "${C_B}║  ${C_YEL}Coolify  ${C_R}${C_B}:  http://${C_CYN}%-56s${C_R}${C_B}║${C_R}\n" "coolify.${DOMAIN:-yourdomain.com} (via NPM)"
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

  success "Pre-flight checks passed"

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
  # Remove ALL previously deployed platform data directories
  info "Removing ALL previous platform data..."
  for dir in /opt/npm /opt/casaos /var/lib/casaos /opt/casaos-stack /opt/coolify-stack /opt/cosmos-stack /opt/dockge-stack /opt/dokploy-stack /opt/portainer-stack /opt/runtipi-stack /opt/freedombox-stack /opt/yunohost-stack /data/coolify; do
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
  docker compose version &>/dev/null && success "Docker $(docker version --format '{{.Server.Version}}') + Compose $(docker compose version --short)" || \
    success "Docker $(docker version --format '{{.Server.Version}}')"
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
  step "Nginx Proxy Manager + CrowdSec"
  mkdir -p "$NPM_DATA_DIR" "$NPM_LE_DIR" "$NPM_LOGS_DIR" "$CROWDSEC_DIR"

  cat > "${NPM_DIR}/docker-compose.npm.yml" << 'COMPOSE_NPM'
services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    restart: always
    container_name: npm
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

  cat > "${NPM_DIR}/docker-compose.authelia.yml" << 'COMPOSE_AUTHELIA'
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

  cat > "${NPM_DIR}/docker-compose.crowdsec.yml" << 'COMPOSE_CROWDSEC'
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
networks:
  proxy:
    external: true
COMPOSE_CROWDSEC

  docker compose -f "${NPM_DIR}/docker-compose.npm.yml" pull
  docker compose -f "${NPM_DIR}/docker-compose.crowdsec.yml" pull

  info "Starting NPM..."
  docker compose -f "${NPM_DIR}/docker-compose.npm.yml" up -d

  info "Verifying NPM ports (80, 443, 81) are bound..."
  local ports_ok=false
  for i in $(seq 1 30); do
    printf "${C_DIM}  Waiting for NPM ports... (%d/30)${C_R}\r" "$i"
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
      printf "\n"; echo "  Port 80 bound:  $has_80"; echo "  Port 443 bound: $has_443"; echo "  Port 81 bound:  $has_81"; echo ""
      ss -tlnp 2>/dev/null | grep -E ':80 |:443 |:81 ' || true; echo ""
      fatal "NPM failed to bind required ports. Check: docker logs npm"
    }
    sleep 2
  done
  printf "\n"


  info "Waiting for NPM container..."
  for i in $(seq 1 30); do
    printf "${C_DIM}  Waiting for NPM container... (%d/30)${C_R}\r" "$i"
    docker ps --format '{{.Names}}' | grep -qx "npm" && { success "NPM container running"; break; }
    [[ $i -eq 30 ]] && warn "NPM container timed out"
    sleep 2
  done
  printf "\n"

  info "Waiting for NPM admin UI (:81)..."
  for i in $(seq 1 60); do
    printf "${C_DIM}  Waiting for NPM admin UI... (%d/60)${C_R}\r" "$i"
    curl -sf --max-time 5 http://127.0.0.1:81/ &>/dev/null && { success "NPM UI ready"; break; }
    [[ $i -eq 60 ]] && warn "NPM UI timed out (2m)."
    sleep 2
  done
  printf "\n"

  info "Waiting for NPM log files..."
  for i in $(seq 1 30); do
    printf "${C_DIM}  Waiting for NPM log files... (%d/30)${C_R}\r" "$i"
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
  printf "\n"

  info "Starting CrowdSec..."
  docker compose -f "${NPM_DIR}/docker-compose.crowdsec.yml" up -d

  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<VPS_IP>")
  success "NPM: http://${ip}:81"

  info "Deploying Authelia..."
  mkdir -p "$AUTHELIA_CONFIG_DIR" "$AUTHELIA_SECRETS_DIR" "$AUTHELIA_SNIPPETS_DIR"

  setup_authelia_secrets
  setup_authelia_config
  setup_authelia_snippets

  docker compose -f "${NPM_DIR}/docker-compose.authelia.yml" pull
  docker compose -f "${NPM_DIR}/docker-compose.authelia.yml" up -d

  info "Waiting for Authelia container..."
  for i in $(seq 1 30); do
    printf "${C_DIM}  Waiting for Authelia container... (%d/30)${C_R}\r" "$i"
    docker ps --format '{{.Names}}' | grep -qx "authelia" && { success "Authelia container running"; break; }
    [[ $i -eq 30 ]] && warn "Authelia container timed out"
    sleep 2
  done
  printf "\n"

  setup_authelia_users
}

setup_authelia_secrets() {
  step "Authelia Secrets"
  mkdir -p "$AUTHELIA_SECRETS_DIR"
  for secret in jwt_session storage_encryption session; do
    if [[ ! -f "${AUTHELIA_SECRETS_DIR}/${secret}" ]]; then
      openssl rand -base64 48 > "${AUTHELIA_SECRETS_DIR}/${secret}"
      success "Generated secret: ${secret}"
    fi
  done
  success "All secrets ready"
}

setup_authelia_config() {
  step "Authelia Configuration"
  mkdir -p "$AUTHELIA_CONFIG_DIR"
  cat > "${AUTHELIA_CONFIG_DIR}/configuration.yml" << AUTHELIA_CONFIG
###############################################################
#                   Authelia configuration                    #
###############################################################
server:
  address: 'tcp://:9091/'
  path: ""

log:
  level: info

theme: auto

totp:
  issuer: authelia.com
  period: 30
  skew: 1

authentication_backend:
  file:
    path: /config/users.yml

access_control:
  default_policy: deny
  rules:
    - domain: "coolify.${DOMAIN}"
      policy: two_factor

session:
  name: authelia_session
  expiration: 1h
  inactivity: 5m
  cookies:
    - domain: "${DOMAIN}"
      authelia_url: 'https://authelia.${DOMAIN}'
      default_redirection_url: 'https://coolify.${DOMAIN}'

regulation:
  max_retries: 5
  find_time: 2m
  ban_time: 5m

storage:
  local:
    path: /config/db.sqlite3

notifier:
  filesystem:
    filename: /config/notifications.txt
AUTHELIA_CONFIG
  success "Configuration written"
}

setup_authelia_snippets() {
  step "Authelia NPM Snippets"
  mkdir -p "$AUTHELIA_SNIPPETS_DIR"
  cat > "${AUTHELIA_SNIPPETS_DIR}/authelia-authrequest.conf" << SNIPPET1
auth_request /authelia;
auth_request_set \$target_url \$scheme://\$http_host\$request_uri;
auth_request_set \$user \$upstream_http_remote_user;
auth_request_set \$groups \$upstream_http_remote_groups;
proxy_set_header Remote-User \$user;
proxy_set_header Remote-Groups \$groups;
error_page 401 =302 https://authelia.${DOMAIN}/?rd=\$target_url;

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
  cat > "${AUTHELIA_SNIPPETS_DIR}/authelia-location.conf" << 'SNIPPET2'
location /authelia {
    proxy_pass http://authelia:9091;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $http_host;
}
SNIPPET2
  success "Authelia NPM snippets created"
}

setup_authelia_users() {
  step "Authelia Users"
  if [[ ! -f "${AUTHELIA_CONFIG_DIR}/users.yml" ]]; then
    cat > "${AUTHELIA_CONFIG_DIR}/users.yml" << 'AUTHELIA_USERS'
users:
  admin:
    displayname: "Admin"
    password: "$argon2id$v=19$m=65536,t=3,p=4$c29tZXNhbHQ$RdescudvjCs"
    email: admin@yourdomain.com
    groups:
      - admins
AUTHELIA_USERS
    success "Default users created (admin/changeme)"
    warn "Change the default password immediately!"
  fi
}

setup_coolify() {
  step "Coolify"
  info "Running Coolify installer — this may take 5-10 minutes..."
  # Coolify's Traefik owns 80/443 but NPM needs them. We stop Traefik BEFORE
  # starting NPM (so NPM can bind 80/443), then connect Coolify to the proxy
  # network so NPM routes to Coolify on :8000.
  curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash || fatal "Coolify installation failed"

  info "Waiting for Coolify (:8000)..."
  for i in $(seq 1 60); do
    printf "${C_DIM}  Waiting for Coolify... (%d/60)${C_R}\r" "$i"
    curl -sf --max-time 5 http://127.0.0.1:8000/api/health &>/dev/null && { success "Coolify ready on :8000"; break; }
    [[ $i -eq 60 ]] && warn "Coolify timed out (3m). Check: docker logs coolify"
    sleep 3
  done
  printf "\n"

  info "Stopping Coolify Traefik (frees 80/443 for NPM)..."
  docker stop coolify-proxy 2>/dev/null || true
  docker rm -f coolify-proxy 2>/dev/null || true

  info "Connecting Coolify to proxy network..."
  docker network connect proxy coolify 2>/dev/null || true

  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<VPS_IP>")
  success "Coolify: http://${ip}:8000 (direct) — access via NPM proxy recommended"
  info "Add Proxy Host in NPM: coolify.yourdomain.com → http://coolify:8000"
}

verify_coolify() {
  step "Verifying Coolify"
  local containers=("coolify" "coolify-realtime")
  for c in "${containers[@]}"; do
    if docker ps --format '{{.Names}}' | grep -qx "$c"; then
      success "Container '${c}' running"
    else
      warn "Container '${c}' not found — may still be starting"
    fi
  done

  if curl -sf --max-time 10 http://127.0.0.1:8000/api/health &>/dev/null; then
    success "Coolify API healthy"
  else
    warn "Coolify API not yet healthy — may need more time"
  fi

  if ss -tlnp 2>/dev/null | grep -q ':80 '; then success "NPM on port 80"
  else warn "Port 80 not bound"; fi
  if ss -tlnp 2>/dev/null | grep -q ':443 '; then success "NPM on port 443"
  else warn "Port 443 not bound"; fi
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
  api_key=$(docker exec crowdsec cscli bouncers add npm-bouncer 2>/dev/null | tail -1 || true)
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


setup_firewall() {
  step "Firewall"
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
  ufw allow 8000/tcp comment 'Coolify UI'

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
  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "YOUR_VPS_IP")
  local ext_ip; ext_ip=$(get_external_ip)
  local fw_cmd; [[ "$OS_FAMILY" == "debian" ]] && fw_cmd="ufw status verbose" || fw_cmd="firewall-cmd --list-all"

  printf "\n${C_B}${C_BLU}══════════════════════════════════════════════════════════════════════════════${C_R}\n"
  printf "${C_B}${C_BLU}  Internal IP: ${C_CYN}%s${C_R}${C_B}${C_BLU}  |  External IP: ${C_CYN}%s${C_R}\n" "$ip" "$ext_ip"
  printf "${C_B}${C_BLU}══════════════════════════════════════════════════════════════════════════════${C_R}\n\n"

  cat << EOF
${C_B}${C_GRN}Deployment Complete${C_R}  (${SCRIPT_NAME} v${SCRIPT_VERSION})  ${C_B}$(( elapsed / 60 ))m $(( elapsed % 60 ))s${C_R}

${C_B}Nginx Proxy Manager${C_R}
  Admin:   http://${ip}:81
  HTTP:    http://${ip}:80
  HTTPS:   https://${ip}:443
  Data:    ${NPM_DATA_DIR}
  SSL:     ${NPM_LE_DIR}
  Logs:    ${NPM_LOGS_DIR}

${C_B}Coolify${C_R}
  Container: coolify
  Port:      8000 (internal, no host port)
  Network:   proxy
  Note: Coolify has native 2FA in Settings → Security

${C_B}Authelia${C_R}
  Container: authelia
  URL:       https://auth.${DOMAIN:-yourdomain.com}
  Config:    ${AUTHELIA_CONFIG_DIR}
  Secrets:   ${AUTHELIA_SECRETS_DIR}
  Reset PW:  sudo docker exec authelia cat /config/notifications.txt

${C_B}Docker${C_R}    $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo N/A)
${C_B}Containers${C_R}  npm, crowdsec, authelia, coolify (separate compose files)
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
  │ Domain Names:    coolify.YOURDOMAIN    │
  │ Scheme:          http                │
  │ Forward Host:    coolify │
  │ Forward Port:    8000      │
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

${C_B}${C_YEL}Setup:${C_R}
  1. NPM:     http://${ip}:81  (admin@example.com / changeme) → change password
  2. Proxy:   Add coolify.yourdomain.com → http://coolify:8000
  3. SSL:     Use NPM SSL Certificates tab
  4. Secure:  $(if [[ "$OS_FAMILY" == "debian" ]]; then echo "ufw delete allow 81/tcp && ufw reload"; else echo "firewall-cmd --permanent --remove-port=81/tcp && firewall-cmd --reload"; fi)

${C_B}Troubleshooting:${C_R}
  Logs:    docker logs -f npm    docker logs -f coolify    docker logs -f coolify-realtime
${C_B}Restart${C_R}
  NPM:      cd ${NPM_DIR} && docker compose -f docker-compose.npm.yml restart
  CrowdSec: cd ${NPM_DIR} && docker compose -f docker-compose.crowdsec.yml restart
  CS:      cscli metrics    cscli decisions list    cscli collections list
  FW:      ${fw_cmd}
  Log:     ${LOG_FILE}
EOF
  _log "INFO" "=== Deployment completed in $(( elapsed / 60 ))m $(( elapsed % 60 ))s ==="
}

main() {
  printf "\n${C_B}${C_CYN}VPS Deployment — Docker + NPM + Coolify + CrowdSec + Authelia${C_R}\n"
  printf "${C_DIM}${SCRIPT_NAME} v${SCRIPT_VERSION}${C_R}\n\n"

  step "Domain Configuration"
  printf "\n${C_B}Enter your root domain${C_R} (e.g., example.com): "
  read -r DOMAIN
  [[ -z "$DOMAIN" ]] && DOMAIN="yourdomain.com"
  DOMAIN=$(echo "$DOMAIN" | sed 's|https\?://||' | sed 's|/.*||' | tr -d ' ')

  preflight_checks
  idempotent_cleanup
  system_update
  install_dependencies
  install_docker
  setup_docker_network
  setup_coolify
  setup_nginx_proxy_manager
  verify_coolify
  setup_crowdsec
  setup_firewall
  setup_logrotate
  DEPLOY_STATUS="success"
  print_summary
}

main "$@"
