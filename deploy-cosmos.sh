#!/usr/bin/env bash
# Auto-elevate to root if not already running as root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi

# deploy-cosmos.sh -- Docker + NPM + Cosmos + Authelia + CrowdSec (v4.3.0-hardened)
# One-click VPS deployment. Usage: sudo ./deploy-cosmos.sh
#   Optional env vars:
#     FORCE_CLEANUP=1              skip the destructive-cleanup confirmation
#     CF_API_TOKEN=<token>         Cloudflare USER API token; enables the CrowdSec
#                                  Cloudflare Worker bouncer (edge IP-ban enforcement).
#                                  If unset, the script prompts; blank = configure later.
#     CF_BOUNCER_ACTION=ban        edge action for banned IPs: ban | captcha (default ban)
#     LOCK_HTTP_TO_CLOUDFLARE=true restrict 80/443 to Cloudflare IP ranges in the
#                                  firewall (default false; turn on once all DNS is proxied)
set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="4.6.0-hardened-cloudflare"
readonly SCRIPT_NAME="deploy-cosmos.sh"
START_TIME=$(date +%s); readonly START_TIME
readonly STACK_DIR="/opt/cosmos-stack"
readonly NPM_DATA_DIR="${STACK_DIR}/data"
readonly NPM_LE_DIR="${STACK_DIR}/letsencrypt"
readonly NPM_LOGS_DIR="${NPM_DATA_DIR}/logs"
readonly CROWDSEC_DIR="${STACK_DIR}/crowdsec"
readonly COSMOS_DATA_DIR="${STACK_DIR}/cosmos-data"
readonly AUTHELIA_DIR="${STACK_DIR}/authelia"
readonly AUTHELIA_CONFIG_DIR="${AUTHELIA_DIR}/config"
readonly AUTHELIA_SECRETS_DIR="${AUTHELIA_DIR}/secrets"
readonly AUTHELIA_SNIPPETS_DIR="${AUTHELIA_DIR}/snippets"
readonly DOMAIN_PERSIST_FILE="/etc/vps-deploy-domain"
readonly LOG_FILE="/var/log/vps-deploy.log"

DOMAIN=""  # Set at runtime via user prompt

# --- Cloudflare integration (Worker bouncer + origin lockdown) ---------------
CF_API_TOKEN="${CF_API_TOKEN:-}"                              # CF USER API token (prompted if empty)
CF_BOUNCER_KEY=""                                            # generated; shared LAPI <-> CF bouncer
CF_BOUNCER_ACTION="${CF_BOUNCER_ACTION:-ban}"                # edge action: ban | captcha
LOCK_HTTP_TO_CLOUDFLARE="${LOCK_HTTP_TO_CLOUDFLARE:-false}"  # restrict 80/443 to Cloudflare ranges
CF_IPS_CACHE=""                                             # filled by get_cloudflare_ips()

# Deployment status tracking for guaranteed completion summary
DEPLOY_STATUS="in_progress"

# Colors (TTY only)
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

# Cloudflare published edge IP ranges (v4 + v6). Fetched live, with a hardcoded
# fallback if the network call fails. Cached after first call. Used by both the
# firewall lockdown and the NPM real-IP restoration.
get_cloudflare_ips() {
  [[ -n "$CF_IPS_CACHE" ]] && { printf '%s\n' "$CF_IPS_CACHE"; return 0; }
  local v4 v6 all
  v4=$(curl -sf --max-time 10 https://www.cloudflare.com/ips-v4 2>/dev/null || true)
  v6=$(curl -sf --max-time 10 https://www.cloudflare.com/ips-v6 2>/dev/null || true)
  all=$(printf '%s\n%s\n' "$v4" "$v6" | grep -E '^[0-9a-fA-F:.]+/[0-9]+$' || true)
  if [[ -z "$all" ]]; then
    all=$(cat <<'CFIPS'
173.245.48.0/20
103.21.244.0/22
103.22.200.0/22
103.31.4.0/22
141.101.64.0/18
108.162.192.0/18
190.93.240.0/20
188.114.96.0/20
197.234.240.0/22
198.41.128.0/17
162.158.0.0/15
104.16.0.0/13
104.24.0.0/14
172.64.0.0/13
131.0.72.0/22
2400:cb00::/32
2606:4700::/32
2803:f800::/32
2405:b500::/32
2405:8100::/32
2a06:98c0::/29
2c0f:f248::/32
CFIPS
)
  fi
  CF_IPS_CACHE="$all"
  printf '%s\n' "$all"
}

# -------------------------------------------------------------------------------
# GUARANTEED COMPLETION SUMMARY - runs on exit regardless of success/failure
# -------------------------------------------------------------------------------
get_external_ip() {
  curl -s -4 --max-time 10 https://api.ipify.org 2>/dev/null || \
  curl -s -4 --max-time 10 https://ifconfig.me 2>/dev/null || \
  curl -s -4 --max-time 10 https://icanhazip.com 2>/dev/null || \
  echo "unknown"
}

_read_cred() { [[ -f "$1" ]] && tr -d '\n' < "$1" 2>/dev/null || echo "<unknown>"; }

_on_exit() {
  local exit_code=$?
  local elapsed=$(( $(date +%s) - START_TIME ))
  local ip ext_ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<internal_ip>")
  ext_ip=$(get_external_ip)
  local authelia_pass npm_pass
  authelia_pass=$(_read_cred "${AUTHELIA_DIR}/.default_password")
  npm_pass=$(_read_cred "${STACK_DIR}/.npm_admin_password")

  printf "\n"
  if [[ "$DEPLOY_STATUS" == "success" ]]; then
    printf "${C_B}${C_GRN}==============================================================================\n"
    printf "                    DEPLOYMENT COMPLETED SUCCESSFULLY\n"
    printf "==============================================================================${C_R}\n"
  else
    printf "${C_B}${C_RED}==============================================================================\n"
    printf "                        DEPLOYMENT DID NOT COMPLETE\n"
    printf "==============================================================================${C_R}\n"
  fi
  printf "${C_B}  Elapsed:  %ss${C_R}\n" "$elapsed"
  printf "${C_B}  VPS IP:   %s${C_R}\n" "$ip"
  printf "${C_B}  External: %s${C_R}\n" "$ext_ip"
  printf "${C_B}  Domain:   %s${C_R}\n" "${DOMAIN:-<not set>}"
  printf "${C_B}------------------------------------------------------------------------------${C_R}\n"
  printf "${C_B}  NPM Admin:     http://%s:81${C_R}\n" "$ip"
  printf "${C_B}  NPM Login:     admin@example.com / %s${C_R}\n" "$npm_pass"
  if [[ "$DEPLOY_STATUS" == "success" ]]; then
    printf "${C_B}  Cosmos:      https://cosmos.%s${C_R}\n" "$DOMAIN"
    printf "${C_B}  Authelia:      https://authelia.%s${C_R}\n" "$DOMAIN"
    printf "${C_B}------------------------------------------------------------------------------${C_R}\n"
    printf "${C_B}${C_YEL}  Containers (hostname = container name, via NPM proxy network):${C_R}\n"
    printf "${C_B}    npm                  ->  ports 80, 443, 81 (admin)${C_R}\n"
    printf "${C_B}    cosmos-server        ->  port 80${C_R}\n"
    printf "${C_B}    authelia             ->  port 9091${C_R}\n"
    printf "${C_B}    crowdsec             ->  port 8080 (LAPI, localhost only)${C_R}\n"
    printf "${C_B}------------------------------------------------------------------------------${C_R}\n"
    printf "${C_B}  ${C_YEL}Authelia Username: admin${C_R}\n"
    printf "${C_B}  ${C_YEL}Authelia Password: %s${C_R}\n" "$authelia_pass"
    printf "${C_B}  ${C_RED}Change this password after first login!${C_R}\n"
    printf "\n"
    printf "${C_B}  ${C_YEL}-- Verification Codes --${C_R}\n"
    printf "${C_B}  Authelia requires a code to change password or add 2FA.${C_R}\n"
    printf "${C_B}  The code appears AFTER you request it in the Authelia UI. Then run:${C_R}\n"
    printf "${C_B}  ${C_CYN}sudo docker exec authelia cat /config/notifications.txt${C_R}\n"
    printf "\n"
    printf "${C_B}  All credentials are stored (mode 600) under: %s${C_R}\n" "$STACK_DIR"
  fi
  printf "${C_B}  Ports: 80 (HTTP), 443 (HTTPS), 81 (NPM Admin)${C_R}\n"
  printf "${C_B}  Log: %s${C_R}\n" "$LOG_FILE"
  printf "${C_B}==============================================================================${C_R}\n\n"
  if [[ "$DEPLOY_STATUS" == "success" ]]; then
    printf "${C_B}${C_GRN}Your VPS is ready!${C_R} DNS must point ${C_CYN}*.${DOMAIN} -> ${ext_ip}${C_R}\n\n"
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

  ARCH=$(uname -m); readonly ARCH
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
  touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
  _log "INFO" "=== ${SCRIPT_NAME} v${SCRIPT_VERSION} started ==="
  _log "INFO" "OS: ${OS_NAME} ${OS_VERSION_ID}, Family: ${OS_FAMILY}, Arch: ${ARCH}"
}

idempotent_cleanup() {
  step "Cleanup"
  # ---------------------------------------------------------------------------
  # FRESH vs EXISTING. On a fresh system there is nothing to destroy -> skip
  # silently. On an existing system, take ONE explicit confirmation, then do ALL
  # destruction (Docker + /opt data + services + CrowdSec packages). Unattended:
  # FORCE_CLEANUP=1 skips the prompt.
  # ---------------------------------------------------------------------------
  local not_fresh=0; local -a reasons=(); local d
  if command -v docker &>/dev/null && docker info &>/dev/null; then
    [[ -n "$(docker ps -aq 2>/dev/null)"       ]] && { not_fresh=1; reasons+=("Docker containers"); }
    [[ -n "$(docker volume ls -q 2>/dev/null)" ]] && { not_fresh=1; reasons+=("Docker volumes"); }
    [[ -n "$(docker images -aq 2>/dev/null)"   ]] && { not_fresh=1; reasons+=("Docker images"); }
  fi
  for d in /opt/*-stack /opt/npm /opt/casaos /var/lib/casaos; do
    [[ -e "$d" ]] && { not_fresh=1; reasons+=("$d"); break; }
  done
  [[ -d /etc/crowdsec || -f /usr/local/bin/crowdsec-firewall-bouncer ]] && { not_fresh=1; reasons+=("CrowdSec install"); }
  dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -qiE '^crowdsec' && { not_fresh=1; reasons+=("CrowdSec packages"); }

  if [[ "$not_fresh" -eq 0 ]]; then
    success "Fresh system detected -- nothing to destroy."
    mkdir -p "$STACK_DIR"; chmod 750 "$STACK_DIR"
    return 0
  fi

  warn "Existing install detected: ${reasons[*]}"
  if [[ "${FORCE_CLEANUP:-0}" != "1" ]]; then
    printf "\n${C_RED}${C_B}WARNING:${C_R}${C_RED} This is NOT a fresh system. Continuing will STOP and DELETE ALL Docker containers, volumes, images and custom networks, remove /opt/*-stack data, and PURGE CrowdSec packages on this host (irreversible).${C_R}\n" >&2
    read -rp "Destroy everything and start clean? [yes/no]: " _confirm
    [[ "$_confirm" =~ ^[Yy]([Ee][Ss])?$ ]] || fatal "Aborted by user. Nothing was changed. Re-run with FORCE_CLEANUP=1 to skip this prompt."
  fi

  # ---- destructive from here (confirmed, or FORCE_CLEANUP=1) -----------------
  if command -v docker &>/dev/null && docker info &>/dev/null; then
    info "Removing ALL existing containers, volumes, images and custom networks..."
    # Leave any Swarm FIRST (dokploy/coolify) so killed task containers don't respawn.
    docker swarm leave --force &>/dev/null || true
    local _pass
    for _pass in 1 2; do
      docker ps -aq 2>/dev/null | xargs -r docker rm -f &>/dev/null || true
    done
    docker volume ls -q 2>/dev/null | xargs -r docker volume rm -f &>/dev/null || true
    docker images -aq 2>/dev/null | xargs -r docker rmi -f &>/dev/null || true
    docker system prune -af --volumes &>/dev/null || true
    local _left; _left="$(docker ps -aq 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "${_left:-0}" != "0" ]]; then
      warn "${_left} container(s) survived -- a Swarm service may be re-arming. Run: docker swarm leave --force; docker rm -f \$(docker ps -aq)"
    else
      success "Docker fully reset (containers, volumes, images, networks)"
    fi
  fi

  info "Removing ALL previous platform data..."
  for d in /opt/npm /opt/casaos /var/lib/casaos /opt/casaos-stack /opt/coolify-stack /opt/cosmos-stack /opt/dockge-stack /opt/dockhand-stack /opt/dokploy-stack /opt/portainer-stack /opt/runtipi-stack /opt/freedombox-stack /opt/yunohost-stack /opt/netbird-stack; do
    rm -rf "$d" 2>/dev/null || true
  done

  info "Removing ALL previous platform services..."
  if command -v crowdsec-cloudflare-worker-bouncer &>/dev/null \
     && [[ -f /etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml ]]; then
    info "Removing Cloudflare Worker bouncer infrastructure from Cloudflare..."
    crowdsec-cloudflare-worker-bouncer -d \
      -c /etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml &>/dev/null || true
  fi
  for svc in casaos-gateway casaos-user-service casaos-local-storage casaos-message-bus runtipi crowdsec-firewall-bouncer crowdsec-cloudflare-worker-bouncer; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    systemctl mask "$svc" 2>/dev/null || true
    rm -f "/etc/systemd/system/${svc}.service" "/etc/systemd/system/${svc}" 2>/dev/null || true
  done
  for svc in casaos-gateway casaos-user-service casaos-local-storage casaos-message-bus runtipi crowdsec-firewall-bouncer crowdsec-cloudflare-worker-bouncer; do
    systemctl unmask "$svc" 2>/dev/null || true
  done
  systemctl daemon-reload 2>/dev/null || true

  rm -f /usr/local/bin/crowdsec-firewall-bouncer 2>/dev/null || true
  rm -f /etc/crowdsec/crowdsec-firewall-bouncer.yaml 2>/dev/null || true
  rm -rf /etc/crowdsec 2>/dev/null || true

  # Native crowdsec packages. CRITICAL: a prior run can leave a HALF-CONFIGURED
  # package (CF worker-bouncer postinst failing) -> dpkg broken, apt-get remove
  # itself fails, broken state survives. Repair dpkg FIRST, then PURGE, repair
  # deps, drop the apt repo.
  if [[ "$OS_FAMILY" == "debian" ]]; then
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq crowdsec crowdsec-firewall-bouncer-nftables crowdsec-firewall-bouncer-iptables crowdsec-cloudflare-worker-bouncer 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get install -f -y -qq 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y -qq 2>/dev/null || true
    rm -f /etc/apt/sources.list.d/crowdsec_crowdsec.list 2>/dev/null || true
  else
    local pkg="yum"; command -v dnf &>/dev/null && pkg="dnf"
    $pkg remove -y -q crowdsec crowdsec-firewall-bouncer-nftables crowdsec-firewall-bouncer-iptables crowdsec-cloudflare-worker-bouncer 2>/dev/null || true
  fi

  if command -v snap &>/dev/null; then
    snap disable docker 2>/dev/null || true
    snap remove docker 2>/dev/null || true
  fi

  mkdir -p "$STACK_DIR"; chmod 750 "$STACK_DIR"
  success "Stack directory recreated: $STACK_DIR"
}

system_update() {
  step "System Update"
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  info "Updating packages - this may take a few minutes, please wait..."
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
  info "Installing required packages - please wait..."
  if [[ "$OS_FAMILY" == "debian" ]]; then
    apt-get install -y -qq ca-certificates curl gnupg lsb-release \
      software-properties-common apt-transport-https jq unzip cron logrotate
  else
    local pkg="yum"; command -v dnf &>/dev/null && pkg="dnf"
    $pkg install -y -q ca-certificates curl gnupg2 yum-utils \
      device-mapper-persistent-data lvm2 jq unzip cronie logrotate
  fi
  success "Dependencies installed"
}

install_docker() {
  step "Docker CE"
  if command -v docker &>/dev/null && docker version &>/dev/null; then
    success "Docker already installed: $(docker --version)"; return 0
  fi
  info "Installing Docker CE - this may take a few minutes, please wait..."
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
    printf "\r  ${C_DIM}Verifying Docker... %d/3${C_R}" "$i" >&2
    docker run --rm hello-world &>/dev/null && { printf "\r" >&2; break; }
    [[ $i -eq 3 ]] && { printf "\r" >&2; fatal "Docker verification failed after 3 attempts."; }
    sleep 5
  done
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

get_user_domain() {
  step "Domain Configuration"
  if [[ -f "${DOMAIN_PERSIST_FILE}" ]]; then
    local existing_domain
    existing_domain=$(tr -d '\n' < "${DOMAIN_PERSIST_FILE}" 2>/dev/null || true)
    if [[ -n "$existing_domain" ]]; then
      printf "\n${C_YEL}Previous deployment detected with domain: ${C_B}${existing_domain}${C_R}\n" >&2
      printf "${C_YEL}   Press ${C_B}Y${C_R}${C_YEL} + Enter to REUSE this domain${C_R}\n" >&2
      printf "${C_YEL}   Press ${C_B}N${C_R}${C_YEL} + Enter to enter a NEW domain${C_R}\n\n" >&2
      read -rp "Reuse '${existing_domain}'? [Y/n]: " use_existing
      [[ "$use_existing" =~ ^[Nn]$ ]] || { DOMAIN="$existing_domain"; success "Domain set to: $DOMAIN"; return 0; }
      printf "\n${C_CYN}Switching to new domain entry...${C_R}\n" >&2
    fi
  fi
  printf "\n${C_B}Enter your root domain${C_R} (e.g., example.com): " >&2
  read -r DOMAIN
  [[ -z "$DOMAIN" ]] && fatal "Domain is required."
  DOMAIN=$(echo "$DOMAIN" | sed 's|https\?://||' | sed 's|/.*||' | tr -d ' ')
  # Basic sanity check: domain is interpolated into nginx/Authelia configs.
  [[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] || \
    fatal "Invalid domain: '$DOMAIN'"
  printf '%s' "$DOMAIN" > "${DOMAIN_PERSIST_FILE}" || warn "Could not persist domain to ${DOMAIN_PERSIST_FILE}"
  success "Domain set to: $DOMAIN"
}

setup_cosmos() {
  step "Cosmos (standalone)"
  mkdir -p "${COSMOS_DATA_DIR}"

  cat > "${STACK_DIR}/docker-compose.cosmos.yml" << 'COMPOSE_COSMOS'
services:
  cosmos-server:
    image: azukaar/cosmos-server:latest
    container_name: cosmos-server
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    volumes:
      - ./cosmos-data:/config
    networks:
      - proxy
networks:
  proxy:
    external: true
COMPOSE_COSMOS

  info "Pulling Cosmos image..."
  docker compose -f "${STACK_DIR}/docker-compose.cosmos.yml" pull
  docker compose -f "${STACK_DIR}/docker-compose.cosmos.yml" up -d

  info "Waiting for Cosmos to be ready..."
  for i in $(seq 1 30); do
    printf "\r  ${C_DIM}Waiting for Cosmos... %d/30${C_R}" "$i" >&2
    sleep 2
    if docker ps --format '{{.Names}}' | grep -qx "cosmos-server"; then
      printf "\r" >&2
      success "Cosmos ready"
      break
    fi
    [[ $i -eq 30 ]] && { printf "\r" >&2; warn "Cosmos may still be starting. Check: docker logs cosmos-server"; }
  done
  printf "\r" >&2

}

setup_stack() {
  step "Deploying NPM, Authelia and CrowdSec"
  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<VPS_IP>")
  # Shared key: CrowdSec pre-registers it as a bouncer (BOUNCER_KEY_* env below),
  # and setup_cloudflare_bouncer writes the SAME key into the CF bouncer config.
  CF_BOUNCER_KEY=$(rand_password 48)
  mkdir -p "$NPM_DATA_DIR" "$NPM_LE_DIR" "$NPM_LOGS_DIR" "$CROWDSEC_DIR"

  cat > "${STACK_DIR}/docker-compose.authelia.yml" << 'COMPOSE_AUTHELIA'
services:
  authelia:
    image: authelia/authelia:latest
    container_name: authelia
    hostname: authelia
    restart: always
    security_opt:
      - no-new-privileges:true
    volumes:
      - ./authelia/config:/config
      - ./authelia/secrets:/config/secrets:ro
    environment:
      - AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET_FILE=/config/secrets/jwt_reset
      - AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE=/config/secrets/storage_encryption
      - AUTHELIA_SESSION_SECRET_FILE=/config/secrets/session
      - TZ=UTC
    networks:
      - proxy
networks:
  proxy:
    external: true
COMPOSE_AUTHELIA

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


  cat > "${STACK_DIR}/docker-compose.crowdsec.yml" << COMPOSE_CROWDSEC
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
      # http-cve adds known-CVE exploit-probing detection (Log4j etc). The base
      # http scenarios (probing/sqli/xss/traversal) already ship WITH the
      # nginx-proxy-manager collection, so they are not listed again.
      # http-dos = L7 flood detection; whitelist-good-actors = avoid banning
      # legit crawlers (Google/Bing/etc). All free hub collections, log-based.
      - COLLECTIONS=crowdsecurity/sshd crowdsecurity/nginx-proxy-manager crowdsecurity/linux crowdsecurity/http-cve crowdsecurity/http-dos crowdsecurity/whitelist-good-actors
      # Pre-register the Cloudflare Worker bouncer so it authenticates to LAPI
      # with this exact key (setup_cloudflare_bouncer writes it into the config).
      - BOUNCER_KEY_cloudflarebouncer=${CF_BOUNCER_KEY}
      - TZ=UTC
    networks:
      - proxy


networks:
  proxy:
    external: true
COMPOSE_CROWDSEC


  info "Pulling images..."
  docker compose -f "${STACK_DIR}/docker-compose.npm.yml" pull
  docker compose -f "${STACK_DIR}/docker-compose.crowdsec.yml" pull

  info "Starting NPM..."
  docker compose -f "${STACK_DIR}/docker-compose.npm.yml" up -d
  for i in $(seq 1 30); do
    local has_80=false has_443=false has_81=false
    ss -tlnp 2>/dev/null | grep -q ':80[[:space:]]' && has_80=true
    ss -tlnp 2>/dev/null | grep -q ':443[[:space:]]' && has_443=true
    ss -tlnp 2>/dev/null | grep -q ':81[[:space:]]' && has_81=true
    if $has_80 && $has_443 && $has_81; then
      success "NPM bound all ports: 80, 443, 81"
      break
    fi
    [[ $i -eq 30 ]] && {
      echo "" >&2; echo "  Port 80 bound:  $has_80" >&2; echo "  Port 443 bound: $has_443" >&2; echo "  Port 81 bound:  $has_81" >&2
      ss -tlnp 2>/dev/null | grep -E ':80 |:443 |:81 ' >&2 || true
      fatal "NPM failed to bind required ports. Check: docker logs npm"
    }
    printf "\r  ${C_DIM}Waiting for NPM ports... %d/30${C_R}" "$i" >&2
    sleep 2
  done
  printf "\r" >&2

  info "Deploying Authelia..."
  mkdir -p "$AUTHELIA_DIR" "$AUTHELIA_CONFIG_DIR" "$AUTHELIA_SECRETS_DIR" "$AUTHELIA_SNIPPETS_DIR"
  setup_authelia_secrets
  setup_authelia_config
  setup_authelia_snippets
  setup_authelia_users          # users.yml MUST exist before the container starts
  docker compose -f "${STACK_DIR}/docker-compose.authelia.yml" pull
  docker compose -f "${STACK_DIR}/docker-compose.authelia.yml" up -d
  info "Waiting for Authelia..."
  for i in $(seq 1 30); do
    if docker ps --format '{{.Names}}' | grep -qx "authelia" && \
       docker exec authelia wget -q -O /dev/null http://127.0.0.1:9091/api/health 2>/dev/null; then
      success "Authelia ready"; break
    fi
    printf "${C_DIM}  Waiting for Authelia... (%d/30)${C_R}\r" "$i" >&2
    [[ $i -eq 30 ]] && warn "Authelia not healthy yet. Check: docker logs authelia"
    sleep 2
  done
  printf "\n" >&2

  info "Waiting for NPM admin UI (:81)..."
  for i in $(seq 1 60); do
    printf "\r  ${C_DIM}Waiting for NPM admin UI... %d/60${C_R}" "$i" >&2
    curl -sf --max-time 5 http://127.0.0.1:81/ &>/dev/null && { printf "\r" >&2; success "NPM UI ready"; break; }
    [[ $i -eq 60 ]] && { printf "\r" >&2; warn "NPM UI timed out (2m)."; }
    sleep 2
  done
  printf "\r" >&2

  info "Waiting for NPM log files..."
  for i in $(seq 1 30); do
    printf "\r  ${C_DIM}Waiting for NPM log files... %d/30${C_R}" "$i" >&2
    if ls "${NPM_LOGS_DIR}/"*_access.log "${NPM_LOGS_DIR}/"*_error.log &>/dev/null; then
      printf "\r" >&2
      success "NPM logs present"
      break
    fi
    if [[ $i -eq 30 ]]; then
      printf "\r" >&2
      warn "NPM logs not found. Creating placeholders."
      touch "${NPM_LOGS_DIR}/fallback_http_access.log" \
            "${NPM_LOGS_DIR}/fallback_http_error.log" \
            "${NPM_LOGS_DIR}/default-host_access.log" \
            "${NPM_LOGS_DIR}/default-host_error.log"
    fi
    sleep 2
  done
  printf "\r" >&2

  info "Starting CrowdSec..."
  docker compose -f "${STACK_DIR}/docker-compose.crowdsec.yml" up -d crowdsec
  for i in $(seq 1 30); do
    docker ps --format '{{.Names}}' | grep -qx "crowdsec" && { success "CrowdSec container running"; break; }
    printf "${C_DIM}  Waiting for CrowdSec container... (%d/30)${C_R}\r" "$i" >&2
    [[ $i -eq 30 ]] && warn "CrowdSec container not found"
    sleep 2
  done
  printf "\n" >&2



  success "NPM: http://${ip}:81"
}

# -------------------------------------------------------------------------------
# NPM API automation - secure password & proxy hosts
# -------------------------------------------------------------------------------
NPM_TOKEN=""
NPM_API_BASE="http://127.0.0.1:81/api"

_npm_api() {
  # _npm_api <path> [extra curl args...]
  local path="$1"; shift
  local args=(-s --max-time 60 -H "Content-Type: application/json")
  [[ -n "$NPM_TOKEN" ]] && args+=(-H "Authorization: Bearer ${NPM_TOKEN}")
  curl "${args[@]}" "${NPM_API_BASE}${path}" "$@"
}

npm_change_password() {
  step "Securing NPM admin password"
  local NEW_PASS JSON LOGIN
  NEW_PASS=$(rand_password 24)
  JSON='{"identity":"admin@example.com","secret":"changeme"}'
  LOGIN=$(_npm_api "/tokens" -d "$JSON" 2>/dev/null) || true
  NPM_TOKEN=$(echo "$LOGIN" | jq -r '.token // empty')
  if [[ -z "$NPM_TOKEN" ]]; then
    warn "Could not get NPM token - skipping automated NPM setup"
    return 1
  fi

  # Persist the new password BEFORE applying it, so a flaky re-auth can never
  # leave the account on a random password we did not record (= hard lockout of
  # the NPM admin UI). If the change PUT fails, 'changeme' still works - recoverable.
  printf '%s' "$NEW_PASS" > "${STACK_DIR}/.npm_admin_password"
  chmod 600 "${STACK_DIR}/.npm_admin_password"
  JSON=$(jq -nc --arg s "$NEW_PASS" '{type:"password",current:"changeme",secret:$s}')
  _npm_api "/users/1/auth" -X PUT -d "$JSON" >/dev/null 2>&1 || true
  # Re-authenticate with new password (retry: NPM can briefly 401 right after the change)
  NPM_TOKEN=""
  for _ in 1 2 3; do
    JSON=$(jq -nc --arg s "$NEW_PASS" '{identity:"admin@example.com",secret:$s}')
    LOGIN=$(_npm_api "/tokens" -d "$JSON" 2>/dev/null) || true
    NPM_TOKEN=$(echo "$LOGIN" | jq -r '.token // empty')
    [[ -n "$NPM_TOKEN" ]] && break
    sleep 2
  done
  if [[ -n "$NPM_TOKEN" ]]; then
    success "NPM admin password changed - saved to ${STACK_DIR}/.npm_admin_password (mode 600)"
    return 0
  else
    warn "NPM password change sent but re-auth failed. Saved candidate to ${STACK_DIR}/.npm_admin_password; if it fails, 'changeme' may still be active."
    return 1
  fi
}

npm_create_proxy_host() {
  # Creates host WITHOUT SSL first (NPM rejects ssl_forced with no cert).
  # SSL is attached afterwards by npm_enable_ssl. Prints host ID on stdout.
  local DOMAIN_NAME="$1"
  local FWD_HOST="$2"
  local FWD_PORT="$3"
  local WS="${4:-true}"
  local ADVANCED_CONFIG="${5:-}"

  local JSON
  JSON=$(jq -nc --arg domain "$DOMAIN_NAME" --arg fwd_host "$FWD_HOST" --argjson fwd_port "$FWD_PORT" \
    --argjson ws "$WS" --arg adv "$ADVANCED_CONFIG" \
    '{
      domain_names: [$domain],
      forward_scheme: "http",
      forward_host: $fwd_host,
      forward_port: $fwd_port,
      access_list_id: 0,
      certificate_id: 0,
      ssl_forced: false,
      caching_enabled: false,
      block_exploits: true,
      allow_websocket_upgrade: $ws,
      http2_support: false,
      hsts_enabled: false,
      hsts_subdomains: false,
      advanced_config: $adv
    }')

  local RESP ID
  RESP=$(_npm_api "/nginx/proxy-hosts" -X POST -d "$JSON")
  ID=$(echo "$RESP" | jq -r '.id // empty')
  if [[ -n "$ID" ]]; then
    success "Created proxy host: ${DOMAIN_NAME} -> ${FWD_HOST}:${FWD_PORT}"
    echo "$ID"
  else
    warn "Failed to create proxy host for ${DOMAIN_NAME}: $(echo "$RESP" | jq -r '.error.message // .message // "unknown error"' 2>/dev/null)"
    return 1
  fi
}

npm_enable_ssl() {
  # Correct NPM API flow: 1) create LE certificate, 2) attach it to the host.
  # (The old /nginx/proxy-hosts/{id}/certificates endpoint does not exist.)
  local HOST_ID="$1"
  local DOMAIN_NAME="$2"
  local EMAIL="${3:-admin@${DOMAIN}}"
  local JSON RESP CERT_ID

  JSON=$(jq -nc --arg email "$EMAIL" --arg domain "$DOMAIN_NAME" '{
    provider: "letsencrypt",
    nice_name: $domain,
    domain_names: [$domain],
    meta: { letsencrypt_email: $email, letsencrypt_agree: true, dns_challenge: false }
  }')
  info "Requesting Let's Encrypt certificate for ${DOMAIN_NAME} (can take up to 2 minutes)..."
  RESP=$(_npm_api "/nginx/certificates" --max-time 180 -X POST -d "$JSON") || true
  CERT_ID=$(echo "$RESP" | jq -r '.id // empty')
  if [[ -z "$CERT_ID" ]]; then
    warn "Certificate issuance failed for ${DOMAIN_NAME} (is DNS pointed at this server yet?). Host stays HTTP-only; add SSL in the NPM UI once DNS resolves."
    return 1
  fi

  JSON=$(jq -nc --argjson cert "$CERT_ID" '{
    certificate_id: $cert,
    ssl_forced: true,
    hsts_enabled: true,
    hsts_subdomains: false,
    http2_support: true
  }')
  RESP=$(_npm_api "/nginx/proxy-hosts/${HOST_ID}" -X PUT -d "$JSON") || true
  if [[ -n "$(echo "$RESP" | jq -r '.id // empty')" ]]; then
    success "SSL enabled + forced for ${DOMAIN_NAME} (cert id ${CERT_ID})"
  else
    warn "Could not attach certificate ${CERT_ID} to host ${HOST_ID} - attach it manually in NPM UI"
  fi
}

# -------------------------------------------------------------------------------
# Authelia SSO/MFA setup
# -------------------------------------------------------------------------------
setup_authelia_secrets() {
  step "Authelia Secrets"
  mkdir -p "$AUTHELIA_SECRETS_DIR"
  # Separate secrets for each purpose (the old script reused the session JWT
  # secret for password-reset JWTs).
  rand_secret > "${AUTHELIA_SECRETS_DIR}/jwt_reset"
  rand_secret > "${AUTHELIA_SECRETS_DIR}/storage_encryption"
  rand_secret > "${AUTHELIA_SECRETS_DIR}/session"
  chmod 600 "${AUTHELIA_SECRETS_DIR}/"*
  success "Authelia secrets generated: $AUTHELIA_SECRETS_DIR"
}

setup_authelia_config() {
  step "Authelia Configuration"
  mkdir -p "$AUTHELIA_CONFIG_DIR"
  cat > "${AUTHELIA_CONFIG_DIR}/configuration.yml" << AUTHELIA_CONF
###############################################################
#                       Authelia configuration                #
#       https://www.authelia.com/configuration/               #
###############################################################
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
    # Wildcard catch-all LAST: any other subdomain (incl. cosmos and
    # anything you add later) requires 2FA by default.
    - domain: "*.${DOMAIN}"
      policy: two_factor
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
AUTHELIA_CONF
  success "Authelia configuration created"
}

setup_authelia_snippets() {
  step "Authelia NPM Snippets"
  mkdir -p "$AUTHELIA_SNIPPETS_DIR"

  # FIXED: the old snippet proxied auth_request to authelia:9091/authelia,
  # which is a 404 -> every request to Cosmos would 500. The correct
  # endpoint (Authelia 4.38+) is /api/authz/auth-request, marked internal,
  # with body stripped and the original method/URL forwarded.
  cat > "${AUTHELIA_SNIPPETS_DIR}/authelia-location.conf" << 'SNIPPET'
location /internal/authelia/authz {
    internal;
    proxy_pass http://authelia:9091/api/authz/auth-request;
    proxy_set_header X-Original-Method $request_method;
    proxy_set_header X-Original-URL $scheme://$http_host$request_uri;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header Content-Length "";
    proxy_pass_request_body off;
}
SNIPPET

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

  # Also write to NPM's custom config directory so they're accessible inside the container
  local npm_custom_dir="${NPM_DATA_DIR}/nginx/custom"
  mkdir -p "$npm_custom_dir"
  cp "${AUTHELIA_SNIPPETS_DIR}/authelia-location.conf" "$npm_custom_dir/"
  cp "${AUTHELIA_SNIPPETS_DIR}/authelia-authrequest.conf" "$npm_custom_dir/"
  success "Authelia NPM snippets created"
}

setup_authelia_users() {
  step "Authelia Users"
  # FIXED: users.yml is now created BEFORE the container starts (Authelia
  # crash-loops without it), the password is RANDOM (was the literal string
  # "authelia"), and the bogus hard-coded fallback hash that could never
  # authenticate has been removed - hash generation failure is now fatal.
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

register_cosmos_stacks() {
  step "Registering editable stacks in Cosmos"
  info "Creating combined compose files in Cosmos data directory..."

  # Combine all compose files into one for easy editing
  {
    echo "# Combined stack - NPM + Authelia + CrowdSec"
    echo "# Edit this file and run: docker compose -f ${STACK_DIR}/docker-compose.yml up -d"
    echo ""
    cat "${STACK_DIR}/docker-compose.npm.yml" 2>/dev/null || true
    echo ""
    # Extract the services from authelia compose (remove networks: section to avoid duplicates)
    sed '1,/^services:/b;/^networks:/,$d' "${STACK_DIR}/docker-compose.authelia.yml" 2>/dev/null || true
    echo ""
    sed '1,/^services:/b;/^networks:/,$d' "${STACK_DIR}/docker-compose.crowdsec.yml" 2>/dev/null || true
  } > "${COSMOS_DATA_DIR}/infrastructure.yml" 2>/dev/null || true

  # Also copy individual compose files for reference
  cp "${STACK_DIR}/docker-compose.npm.yml" "${COSMOS_DATA_DIR}/npm.yml" 2>/dev/null || true
  cp "${STACK_DIR}/docker-compose.authelia.yml" "${COSMOS_DATA_DIR}/authelia.yml" 2>/dev/null || true
  cp "${STACK_DIR}/docker-compose.crowdsec.yml" "${COSMOS_DATA_DIR}/crowdsec.yml" 2>/dev/null || true

  success "Compose files available in Cosmos file browser: ${COSMOS_DATA_DIR}"
}

npm_purge_proxy_hosts() {
  # Reconcile NPM to the deploy's intended state: delete any pre-existing proxy
  # hosts before creating ours, so a stale host (e.g. a "crowdsec" host from a
  # previous tool install) can never linger after a redeploy. No-op on a clean box.
  command -v jq &>/dev/null || return 0
  local ids id n=0
  ids=$(_npm_api "/nginx/proxy-hosts" 2>/dev/null | jq -r '.[]?.id // empty' 2>/dev/null) || true
  for id in $ids; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    _npm_api "/nginx/proxy-hosts/${id}" -X DELETE >/dev/null 2>&1 && n=$((n+1)) || true
  done
  [[ "$n" -gt 0 ]] && info "Removed ${n} pre-existing NPM proxy host(s) for a clean slate" || true
  return 0
}

automate_npm() {
  step "Automating NPM setup (proxy hosts + SSL)"

  if ! npm_change_password; then
    warn "Could not change NPM password; manual setup needed (NPM still has DEFAULT credentials - change them NOW at :81)"
    return 0
  fi

  npm_purge_proxy_hosts

  # Cosmos: protected by Authelia auth_request. Both snippets are required:
  # the location block AND the auth_request directives.
  local auth_snippet=$'include /data/nginx/custom/authelia-location.conf;\ninclude /data/nginx/custom/authelia-authrequest.conf;'
  local cosmos_id=""
  cosmos_id=$(npm_create_proxy_host "cosmos.${DOMAIN}" "cosmos-server" 80 true "$auth_snippet") || true
  [[ -n "$cosmos_id" ]] && npm_enable_ssl "$cosmos_id" "cosmos.${DOMAIN}" || true

  # Authelia portal
  local authelia_id=""
  authelia_id=$(npm_create_proxy_host "authelia.${DOMAIN}" "authelia" 9091 true "") || true
  [[ -n "$authelia_id" ]] && npm_enable_ssl "$authelia_id" "authelia.${DOMAIN}" || true


  success "NPM automation completed"
}

# -------------------------------------------------------------------------------
# Firewall, logrotate, CrowdSec setup
# -------------------------------------------------------------------------------
detect_ssh_port() {
  # FIXED: the old detection grepped for ':22 ' specifically, so a custom SSH
  # port was never detected -> UFW reset would lock you out of your own VPS.
  local p=""
  p=$(ss -tlnpH 2>/dev/null | awk '/sshd/ { n=split($4,a,":"); print a[n]; exit }')
  if [[ -z "$p" ]]; then
    p=$(awk '/^[Pp]ort[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)
  fi
  echo "${p:-22}"
}

setup_firewall() {
  step "Firewall"
  info "Configuring firewall - please wait..."
  if [[ "$OS_FAMILY" == "debian" ]]; then setup_firewall_debian
  else setup_firewall_rhel; fi
  warn "Note: Docker-published ports bypass UFW/firewalld INPUT rules by design. Only 80/443/81 are published; CrowdSec bans are enforced in DOCKER-USER as well (see bouncer config)."
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
  else
    echo 'DEFAULT_FORWARD_POLICY="ACCEPT"' > "$ufw_def"
  fi
  success "UFW DEFAULT_FORWARD_POLICY=ACCEPT"
  local ssh_port; ssh_port=$(detect_ssh_port)
  info "Detected SSH port: ${ssh_port}"
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "${ssh_port}/tcp" comment 'SSH'
  ufw limit "${ssh_port}/tcp" 2>/dev/null || true   # rate-limit SSH brute force at the firewall too
  if [[ "$LOCK_HTTP_TO_CLOUDFLARE" == "true" ]]; then
    info "Locking 80/443 to Cloudflare IP ranges (LOCK_HTTP_TO_CLOUDFLARE=true)..."
    local cidr
    while IFS= read -r cidr; do
      [[ -n "$cidr" ]] && ufw allow from "$cidr" to any port 80,443 proto tcp comment 'Cloudflare' >/dev/null 2>&1 || true
    done < <(get_cloudflare_ips)
    success "80/443 restricted to Cloudflare edge"
  else
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
  fi
  ufw allow 81/tcp comment 'NPM Admin'
  ufw --force enable && ufw reload
  ufw status verbose >&2
  success "UFW configured (SSH port ${ssh_port} allowed)"
}

setup_firewall_rhel() {
  info "Configuring firewalld..."
  local pkg="yum"; command -v dnf &>/dev/null && pkg="dnf"
  $pkg install -y -q firewalld
  systemctl start firewalld && systemctl enable firewalld
  local ssh_port; ssh_port=$(detect_ssh_port)
  firewall-cmd --permanent --add-service=ssh
  [[ "$ssh_port" != "22" ]] && firewall-cmd --permanent --add-port="${ssh_port}/tcp"
  if [[ "$LOCK_HTTP_TO_CLOUDFLARE" == "true" ]]; then
    info "Locking 80/443 to Cloudflare IP ranges (LOCK_HTTP_TO_CLOUDFLARE=true)..."
    local cidr fam
    while IFS= read -r cidr; do
      [[ -z "$cidr" ]] && continue
      [[ "$cidr" == *:* ]] && fam="ipv6" || fam="ipv4"
      firewall-cmd --permanent --add-rich-rule="rule family=${fam} source address=${cidr} port port=80 protocol=tcp accept" >/dev/null 2>&1 || true
      firewall-cmd --permanent --add-rich-rule="rule family=${fam} source address=${cidr} port port=443 protocol=tcp accept" >/dev/null 2>&1 || true
    done < <(get_cloudflare_ips)
    success "80/443 restricted to Cloudflare edge"
  else
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
  fi
  firewall-cmd --permanent --add-port=81/tcp
  if ! firewall-cmd --get-zones 2>/dev/null | grep -q '\bdocker\b'; then
    firewall-cmd --permanent --new-zone=docker 2>/dev/null || true
  fi
  firewall-cmd --permanent --zone=docker --add-interface=docker0 2>/dev/null || true
  firewall-cmd --permanent --zone=docker --set-target=ACCEPT 2>/dev/null || true
  firewall-cmd --reload
  firewall-cmd --list-all >&2
  success "Firewalld configured (SSH port ${ssh_port} allowed)"
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
    docker logs crowdsec --tail 20 >&2 2>/dev/null || true
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
  # NOTE: NPM's proxy-host log format is NOT plain nginx. With "type: nginx"
  # every line is read but ZERO lines parse -> no web-based bans ever fire.
  # The crowdsecurity/nginx-proxy-manager collection expects this label:
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
  # A full restart is required for new acquisition files to take effect
  # (SIGHUP does not reliably reload acquisition sources).
  info "Restarting CrowdSec to apply acquisition config..."
  docker restart crowdsec &>/dev/null || true
  for i in $(seq 1 30); do
    docker exec crowdsec cscli metrics &>/dev/null && { success "CrowdSec back up"; break; }
    [[ $i -eq 30 ]] && warn "CrowdSec slow to restart - check: docker logs crowdsec"
    sleep 2
  done

  info "Installing firewall bouncer..."
  local bouncer_version
  bouncer_version=$(curl -sf --max-time 10 "https://api.github.com/repos/crowdsecurity/cs-firewall-bouncer/releases/latest" | jq -r '.tag_name // empty' | sed 's/^v//') || true
  [[ -z "${bouncer_version:-}" ]] && bouncer_version="0.0.34"
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
    # Was fatal -- now degrades gracefully: detection still works, only
    # host-level remediation is missing, and the rest of the stack is fine.
    warn "Firewall bouncer download failed -- bans will not be enforced at the firewall. Install manually later."
    return 0
  fi
  docker exec crowdsec cscli bouncers delete npm-bouncer 2>/dev/null || true
  # FIXED: the old extraction grepped for lowercase hex ([a-f0-9]{32,}), but
  # modern CrowdSec issues base64-style keys with uppercase chars -> the grep
  # matched nothing, the config file was never written, and the bouncer
  # crash-looped on "no such file". '-o raw' prints exactly the key.
  local api_key
  api_key=$(docker exec crowdsec cscli bouncers add npm-bouncer -o raw 2>/dev/null | tr -d '[:space:]' || true)
  if [[ -z "$api_key" ]]; then
    # fallback for very old cscli without -o raw: accept base64/hex charsets
    docker exec crowdsec cscli bouncers delete npm-bouncer 2>/dev/null || true
    api_key=$(docker exec crowdsec cscli bouncers add npm-bouncer 2>/dev/null | grep -oE '[A-Za-z0-9+/=_-]{30,}' | head -1 || true)
  fi
  if [[ -n "$api_key" ]]; then
    mkdir -p /etc/crowdsec
    local fw_mode="iptables"
    command -v nft &>/dev/null && fw_mode="nftables"
    # iptables_chains includes DOCKER-USER so bans also apply to traffic
    # heading into Docker-published ports (80/443/81), which otherwise
    # bypasses INPUT entirely. (Used in iptables mode; ignored by nftables.)
    cat > /etc/crowdsec/crowdsec-firewall-bouncer.yaml << BOUNCER
api_url: http://127.0.0.1:8080
api_key: ${api_key}
mode: ${fw_mode}
deny_action: DROP
update_frequency: 10s
iptables_chains:
  - INPUT
  - FORWARD
  - DOCKER-USER
BOUNCER
    chmod 600 /etc/crowdsec/crowdsec-firewall-bouncer.yaml
    # FIXED: 'enable --now' with all errors swallowed left the service
    # silently inactive. Now: unmask defensively, test the config ourselves
    # (output goes to the log), enable and restart as separate steps, then
    # poll for active state and dump the journal on failure.
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
      # one mid-loop retry in case LAPI wasn't ready on first start
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

# -------------------------------------------------------------------------------
# Cloudflare real visitor IP restoration (NPM)
# Behind Cloudflare, every request arrives FROM a Cloudflare edge IP. Without
# this, NPM logs the CF IP, CrowdSec keys its bans on CF IPs, and you end up
# banning Cloudflare itself. These directives trust the CF ranges and read the
# true client IP from the CF-Connecting-IP header.
# -------------------------------------------------------------------------------
setup_cloudflare_realip() {
  step "Cloudflare real-IP restoration (NPM)"
  local custom_dir="${NPM_DATA_DIR}/nginx/custom"
  mkdir -p "$custom_dir"
  local conf="${custom_dir}/http.conf"   # included inside NPM's http{} block
  {
    echo "# Managed by ${SCRIPT_NAME} - restore real visitor IP behind Cloudflare"
    echo "real_ip_header CF-Connecting-IP;"
    echo "real_ip_recursive on;"
    local cidr
    while IFS= read -r cidr; do
      [[ -n "$cidr" ]] && echo "set_real_ip_from ${cidr};"
    done < <(get_cloudflare_ips)
  } > "$conf"
  success "Wrote ${conf} ($(grep -c set_real_ip_from "$conf" 2>/dev/null || echo 0) CF ranges)"
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx npm; then
    if docker exec npm nginx -t &>/dev/null && docker exec npm nginx -s reload &>/dev/null; then
      success "NPM reloaded with real-IP config"
    else
      docker restart npm &>/dev/null || true
      warn "NPM reloaded via restart (nginx -s reload unavailable)"
    fi
  fi
}

# -------------------------------------------------------------------------------
# CrowdSec Cloudflare Worker bouncer - enforces CrowdSec ban decisions at the
# Cloudflare edge (real client IP, before traffic reaches this VPS). Installed
# as a host package; talks to the dockerized LAPI on 127.0.0.1:8080. Deploys a
# Cloudflare Worker + KV to your account (only if a token is supplied).
# -------------------------------------------------------------------------------
setup_cloudflare_bouncer() {
  step "CrowdSec Cloudflare Worker bouncer"
  local cfg_dir="/etc/crowdsec/bouncers"
  local cfg="${cfg_dir}/crowdsec-cloudflare-worker-bouncer.yaml"
  mkdir -p "$cfg_dir"

  # 1. Token: from env, else prompt. Blank = configure now, deploy later.
  if [[ -z "$CF_API_TOKEN" ]]; then
    printf "\n${C_B}Cloudflare Worker bouncer${C_R} blocks banned IPs at Cloudflare's edge.\n" >&2
    printf "It needs a Cloudflare ${C_B}User${C_R} API token (My Profile > API Tokens, NOT an\n" >&2
    printf "Account token). Supplying it now will deploy a Worker + KV to your account.\n" >&2
    printf "Required perms: Account(Workers KV Storage:Edit, Workers Scripts:Edit,\n" >&2
    printf "  Turnstile:Edit, Account Settings:Read, Account Analytics:Read),\n" >&2
    printf "  User(User Details:Read), Zone(DNS:Read, Workers Routes:Edit, Zone:Read)\n" >&2
    printf "Leave blank to skip the live deploy and finish later.\n" >&2
    read -rsp "Cloudflare API token (hidden, Enter to skip): " CF_API_TOKEN >&2 || true
    printf "\n" >&2
    if [[ -n "$CF_API_TOKEN" ]]; then
      printf "  ${C_GRN}Token received${C_R} (%s chars, ending ...%s)\n" "${#CF_API_TOKEN}" "${CF_API_TOKEN: -4}" >&2
    else
      printf "  ${C_YEL}No token entered -- skipping the live Cloudflare deploy.${C_R}\n" >&2
    fi
  fi

  # 2. Install the bouncer (CrowdSec repo + package manager, graceful fallback).
  local have_bin=false
  # The CF worker-bouncer postinst READS this config and FATALs (breaking dpkg)
  # if it is missing -> pre-create a minimal stub BEFORE install; step 4 below
  # overwrites it with the real config once the CF zone/account are discovered.
  if [[ ! -s "$cfg" ]]; then
    printf '%s\n' 'crowdsec_config:' '  lapi_key: ""' '  lapi_url: http://127.0.0.1:8080/' 'cloudflare_config:' '  accounts: []' 'log_level: info' 'log_media: stdout' > "$cfg" 2>/dev/null || true
    chmod 600 "$cfg" 2>/dev/null || true
  fi
  if command -v crowdsec-cloudflare-worker-bouncer &>/dev/null; then
    have_bin=true
  elif [[ "$OS_FAMILY" == "debian" ]]; then
    info "Adding CrowdSec repository + installing the worker bouncer..."
    curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash >>"$LOG_FILE" 2>&1 || true
    apt-get install -y -qq crowdsec-cloudflare-worker-bouncer >>"$LOG_FILE" 2>&1 || true
    command -v crowdsec-cloudflare-worker-bouncer &>/dev/null && have_bin=true
  else
    info "Adding CrowdSec repository + installing the worker bouncer..."
    curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.rpm.sh | bash >>"$LOG_FILE" 2>&1 || true
    local pkg="yum"; command -v dnf &>/dev/null && pkg="dnf"
    $pkg install -y -q crowdsec-cloudflare-worker-bouncer >>"$LOG_FILE" 2>&1 || true
    command -v crowdsec-cloudflare-worker-bouncer &>/dev/null && have_bin=true
  fi
  $have_bin && success "Worker bouncer binary present" || warn "Worker bouncer package not installed - writing config for manual install"

  # 3. Discover the Cloudflare zone + account for $DOMAIN via the CF API.
  local zone_id="" account_id="" account_name=""
  if [[ -n "$CF_API_TOKEN" && -n "$DOMAIN" ]]; then
    local zjson
    zjson=$(curl -s --max-time 15 -H "Authorization: Bearer ${CF_API_TOKEN}" \
      "https://api.cloudflare.com/client/v4/zones?name=${DOMAIN}" 2>/dev/null || true)
    zone_id=$(echo "$zjson" | jq -r '.result[0].id // empty' 2>/dev/null || true)
    account_id=$(echo "$zjson" | jq -r '.result[0].account.id // empty' 2>/dev/null || true)
    account_name=$(echo "$zjson" | jq -r '.result[0].account.name // empty' 2>/dev/null || true)
    if [[ -n "$zone_id" ]]; then
      success "Found Cloudflare zone for ${DOMAIN} (zone ${zone_id:0:8}...)"
    else
      warn "No Cloudflare zone found for ${DOMAIN} (check token scope / domain). Writing template; finish manually."
    fi
  fi

  # 4. Write the bouncer config (free-plan-safe). Heredoc is unquoted so the
  #    ${...} variables below are filled in at runtime.
  : "${CF_BOUNCER_KEY:=$(rand_password 48)}"
  cat > "$cfg" << CFWB
crowdsec_config:
  lapi_key: ${CF_BOUNCER_KEY}
  lapi_url: http://127.0.0.1:8080/
  update_frequency: 10s
  include_scenarios_containing: []
  exclude_scenarios_containing: []
  # Cloudflare FREE plan: only sync this engine's + manual bans (free KV write
  # cap is ~1K/day). On a paid Workers plan you can remove this to push blocklists.
  only_include_decisions_from: ["cscli", "crowdsec"]
  insecure_skip_verify: false

cloudflare_config:
  accounts:
    - id: ${account_id:-<ACCOUNT_ID>}
      account_name: ${account_name:-<CF_ACCOUNT_EMAIL>}
      token: ${CF_API_TOKEN:-<CLOUDFLARE_USER_API_TOKEN>}
      zones:
        - zone_id: ${zone_id:-<ZONE_ID>}
          routes_to_protect:
            - "*${DOMAIN:-example.com}/*"
          actions: ["${CF_BOUNCER_ACTION}"]
          default_action: ${CF_BOUNCER_ACTION}
          turnstile:
            enabled: false
  worker:
    log_only: false

log_level: info
log_media: stdout

prometheus:
  enabled: true
  listen_addr: 127.0.0.1
  listen_port: "2112"
CFWB
  chmod 600 "$cfg"
  success "Wrote ${cfg}"

  # 5. Deploy: starting the daemon creates the CF Worker + KV + route from config.
  if $have_bin && [[ -n "$zone_id" && -n "$account_id" ]]; then
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable crowdsec-cloudflare-worker-bouncer >>"$LOG_FILE" 2>&1 || true
    systemctl restart crowdsec-cloudflare-worker-bouncer >>"$LOG_FILE" 2>&1 || true
    local ok=false i
    for i in $(seq 1 10); do
      systemctl is-active --quiet crowdsec-cloudflare-worker-bouncer && { ok=true; break; }
      sleep 2
    done
    if $ok; then
      success "Cloudflare Worker bouncer ACTIVE - edge enforcement is live"
      warn "ACTION REQUIRED (no Cloudflare API for this): set the Worker Route to FAIL OPEN -> CF dashboard > ${DOMAIN} > Workers Routes > edit the crowdsec route > Request limit failure mode > Fail open. Without it a worker error shows visitors a CF 1027 page."
    else
      journalctl -u crowdsec-cloudflare-worker-bouncer -n 20 --no-pager >>"$LOG_FILE" 2>&1 || true
      warn "Worker bouncer not active - see ${LOG_FILE}. Debug: journalctl -u crowdsec-cloudflare-worker-bouncer -n 30"
    fi
  else
    systemctl stop crowdsec-cloudflare-worker-bouncer 2>/dev/null || true
    systemctl disable crowdsec-cloudflare-worker-bouncer 2>/dev/null || true
    warn "Cloudflare Worker bouncer configured but NOT deployed (no token/zone, or package missing)."
    info "Finish later: ensure the package is installed, set token + IDs in ${cfg}, then: systemctl enable --now crowdsec-cloudflare-worker-bouncer"
  fi
}

# -------------------------------------------------------------------------------
# CrowdSec Console (https://app.crowdsec.net) enrollment.
# The Console is the cloud-based dashboard for alerts, decisions and metrics.
# -------------------------------------------------------------------------------
setup_crowdsec_console() {
  step "CrowdSec Console enrollment"
  info "Enrolling this CrowdSec instance in the CrowdSec Console (https://app.crowdsec.net)..."

  local console_ready=false
  for i in $(seq 1 30); do
    if docker exec crowdsec cscli metrics &>/dev/null; then
      console_ready=true
      break
    fi
    printf "\r  ${C_DIM}Waiting for CrowdSec LAPI... %d/30${C_R}" "$i" >&2
    sleep 2
  done
  printf "\r" >&2

  if ! $console_ready; then
    warn "CrowdSec LAPI not ready - Console enrollment skipped. Enroll manually later with: docker exec crowdsec cscli console enroll --auto"
    return 0
  fi

  if docker exec crowdsec cscli console enroll --auto &>/dev/null; then
    success "CrowdSec enrolled in Console"
    info "View alerts, decisions and metrics at: https://app.crowdsec.net/"
  else
    warn "CrowdSec Console enrollment failed or already enrolled. Check: docker logs crowdsec"
  fi
}
# -------------------------------------------------------------------------------
# Post-deploy self-verification - the script proves its own work before
# declaring success. Failures here are loud but non-fatal (warn level),
# with exact debug commands printed.
# -------------------------------------------------------------------------------
verify_deployment() {
  step "Post-Deploy Verification"
  local fails=0

  _check() {  # _check <label> <command...>
    local label="$1"; shift
    if "$@" &>/dev/null; then success "VERIFY: ${label}"
    else warn "VERIFY FAILED: ${label}"; fails=$((fails+1)); fi
  }

  # Containers
  local want="npm cosmos-server authelia crowdsec"
  local c
  for c in $want; do
    _check "container '$c' running" bash -c "docker ps --format '{{.Names}}' | grep -qx '$c'"
  done

  # Core service health
  _check "IP forwarding ON (Docker)" bash -c '[[ $(sysctl -n net.ipv4.ip_forward) == 1 ]]'
  _check "NPM API responding"        curl -sf --max-time 5 http://127.0.0.1:81/api/
  _check "NPM default creds REJECTED (password was changed)" bash -c \
    "! curl -s --max-time 5 -X POST http://127.0.0.1:81/api/tokens -H 'Content-Type: application/json' -d '{\"identity\":\"admin@example.com\",\"secret\":\"changeme\"}' | grep -q token"
  _check "Authelia health endpoint OK" bash -c \
    "docker exec authelia wget -q -O- http://127.0.0.1:9091/api/health 2>/dev/null | grep -q OK"
  _check "nginx config valid inside NPM" docker exec npm nginx -t
  _check "Authelia snippets present in NPM custom dir" bash -c \
    "test -f '${NPM_DATA_DIR}/nginx/custom/authelia-location.conf' && test -f '${NPM_DATA_DIR}/nginx/custom/authelia-authrequest.conf'"

  _check "CrowdSec LAPI responding"   docker exec crowdsec cscli metrics
  _check "acquisition label is nginx-proxy-manager" bash -c \
    "docker exec crowdsec cat /etc/crowdsec/acquis.d/npm.yaml 2>/dev/null | grep -q 'type: nginx-proxy-manager'"
  _check "nginx-proxy-manager collection installed" bash -c \
    "docker exec crowdsec cscli collections list 2>/dev/null | grep -q crowdsecurity/nginx-proxy-manager"
  _check "bouncer registered in LAPI" bash -c \
    "docker exec crowdsec cscli bouncers list 2>/dev/null | grep -q npm-bouncer"
  _check "http-cve collection installed" bash -c \
    "docker exec crowdsec cscli collections list 2>/dev/null | grep -q crowdsecurity/http-cve"
  _check "Cloudflare real-IP config present in NPM" bash -c \
    "test -f '${NPM_DATA_DIR}/nginx/custom/http.conf' && grep -q CF-Connecting-IP '${NPM_DATA_DIR}/nginx/custom/http.conf'"
  _check "firewall bouncer service ACTIVE" systemctl is-active --quiet crowdsec-firewall-bouncer
  # Live end-to-end ban test: ban a TEST-NET IP, confirm it lands in the
  # firewall via the bouncer, then remove it. TEST-NET-1 (192.0.2.0/24) is
  # reserved (RFC 5737) and can never belong to a real client.
  if systemctl is-active --quiet crowdsec-firewall-bouncer; then
    info "Running live ban round-trip test (192.0.2.1, reserved test IP)..."
    docker exec crowdsec cscli decisions add --ip 192.0.2.1 --duration 2m --reason "deploy-verify" &>/dev/null || true
    sleep 15  # bouncer pulls every 10s
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

# -------------------------------------------------------------------------------
# Final summary
# -------------------------------------------------------------------------------
print_summary() {
  local elapsed=$(( $(date +%s) - START_TIME ))
  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "YOUR_VPS_IP")
  local ext_ip; ext_ip=$(get_external_ip)
  local fw_cmd; [[ "$OS_FAMILY" == "debian" ]] && fw_cmd="ufw status verbose" || fw_cmd="firewall-cmd --list-all"
  local npm_password authelia_pass
  npm_password=$(_read_cred "${STACK_DIR}/.npm_admin_password")
  authelia_pass=$(_read_cred "${AUTHELIA_DIR}/.default_password")

  printf "\n"
  printf "${C_B}${C_GRN}==============================================================================\n"
  printf "                          DEPLOYMENT COMPLETE\n"
  printf "==============================================================================${C_R}\n"
  printf "${C_B}  ${C_CYN}%s v%s${C_R}\n" "$SCRIPT_NAME" "$SCRIPT_VERSION"
  printf "${C_B}  Elapsed: ${C_CYN}%dm %ds${C_R}\n" $(( elapsed / 60 )) $(( elapsed % 60 ))
  printf "${C_B}==============================================================================${C_R}\n"

  cat << EOF

${C_B}Stack Directory${C_R}    ${STACK_DIR}

${C_B}${C_GRN}-- NPM Proxy Forwarding --------------------------------------${C_R}
cosmos.${DOMAIN}  ->  cosmos-server:80   (Authelia 2FA enforced)
authelia.${DOMAIN}  ->  authelia:9091

${C_B}Nginx Proxy Manager${C_R}
  Admin:   http://${ip}:81
  Login:   admin@example.com
  Password:${C_YEL} ${npm_password}${C_R}
  HTTP:    http://${ip}:80
  HTTPS:   https://${ip}:443
  Ext IP:  ${ext_ip}
  Data:    ${NPM_DATA_DIR}
  SSL:     ${NPM_LE_DIR}
  Logs:    ${NPM_LOGS_DIR}

${C_B}Cosmos${C_R}
  URL:        https://cosmos.${DOMAIN}
  Container:  cosmos-server
  Network:    proxy
  Data:       ${COSMOS_DATA_DIR}
  Auth:       Authelia 2FA in front + Cosmos built-in SSO/MFA (setup wizard on first visit)
  Host Files: READ-ONLY mount under /host (see compose file comment to enable writes)

${C_B}Authelia${C_R}
  URL:       https://authelia.${DOMAIN}
  Container: authelia
  Network:   proxy
  Config:    ${AUTHELIA_CONFIG_DIR}
  Login:     admin / ${authelia_pass}  (change after first login)
  Info:      Verification codes: sudo docker exec authelia cat /config/notifications.txt

${C_B}CrowdSec Console${C_R}
  URL:      https://app.crowdsec.net/
  Note:     This CrowdSec instance is enrolled in the Console (cloud dashboard).
            If enrollment failed, run: docker exec crowdsec cscli console enroll --auto


${C_B}Cloudflare Worker bouncer${C_R}
  Role:     Blocks CrowdSec-banned IPs at Cloudflare's edge (before your VPS).
  Config:   /etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml
  Status:   $(systemctl is-active crowdsec-cloudflare-worker-bouncer 2>/dev/null || echo "not deployed (no token supplied)")
  Action:   $(echo "${CF_BOUNCER_ACTION}") on banned IPs   Plan-safe: only_include_decisions_from=[cscli,crowdsec]


${C_B}Firewall${C_R}  $(if [[ "$OS_FAMILY" == "debian" ]]; then echo "UFW"; else echo "firewalld"; fi)
${C_B}Docker${C_R}    $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo N/A)
${C_B}Containers${C_R}  npm, cosmos-server, authelia, crowdsec
${C_B}Network${C_R}   proxy (bridge)

${C_B}${C_YEL}Done automatically:${C_R}
  - Proxy hosts for Cosmos / Authelia created
  - Let's Encrypt SSL certificates requested and forced (where DNS resolved)
  - NPM admin password changed to a random value (saved mode 600)
  - Authelia admin password randomized (saved mode 600)
  - CrowdSec Console enrollment attempted
  - Authelia 2FA protecting Cosmos
  - CrowdSec bans enforced incl. Docker-published ports (DOCKER-USER chain)
  - CrowdSec http-cve collection installed (CVE-exploit probing detection)
  - Cloudflare real visitor IPs restored in NPM (CF-Connecting-IP header)
  - Cloudflare Worker bouncer deployed for edge IP-ban enforcement (if token supplied)

${C_B}${C_YEL}Cloudflare - finish in the dashboard (no public API exists for these):${C_R}
  1. Worker Route -> FAIL OPEN:  ${DOMAIN} > Workers Routes > the crowdsec route
     > Edit > Request limit failure mode > Fail open   (else worker errors = CF 1027 page)
  2. Managed WAF ruleset (request-inspection / OWASP layer):
     ${DOMAIN} > Security > WAF > Managed rules > enable   (free plan = free ruleset)
  3. If you skipped the API token: add it + zone/account IDs in
     /etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml, then
     systemctl enable --now crowdsec-cloudflare-worker-bouncer
  Test edge ban: docker exec crowdsec cscli decisions add --ip 1.2.3.4 --type ban
                 (then: docker exec crowdsec cscli decisions delete --ip 1.2.3.4)
  Origin lockdown: re-run with LOCK_HTTP_TO_CLOUDFLARE=true to restrict 80/443 to CF ranges

${C_B}${C_YEL}Credential files (root-only, mode 600):${C_R}
  ${STACK_DIR}/.npm_admin_password
  ${AUTHELIA_DIR}/.default_password

${C_B}Troubleshooting:${C_R}
  Logs:    docker logs -f npm    docker logs -f cosmos-server    docker logs -f authelia
  Restart: cd ${STACK_DIR} && docker compose -f docker-compose.npm.yml restart
  FW:      ${fw_cmd}
  Log:     ${LOG_FILE}
EOF
  _log "INFO" "=== Deployment completed in $(( elapsed / 60 ))m $(( elapsed % 60 ))s ==="
}

ensure_ip_forwarding() {
  step "Networking Prerequisites"
  # Docker REQUIRES IP forwarding to route host->container traffic. An older
  # harden.sh run may have persisted net.ipv4.ip_forward=0, which silently breaks
  # ALL published container ports (80/443/81) while leaving SSH working. Force it
  # on, repair any leftover override, and persist so it survives reboot.
  local f
  for f in /etc/sysctl.conf /etc/sysctl.d/*.conf; do
    [[ -f "$f" ]] || continue
    if grep -qE '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*0' "$f"; then
      sed -i -E 's/^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*0/net.ipv4.ip_forward=1/' "$f"
      warn "Reset net.ipv4.ip_forward=0 -> 1 in $f (was breaking container networking)"
    fi
  done
  echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-zzz-docker-forward.conf
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  sysctl --system >/dev/null 2>&1 || true
  local ipf; ipf=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "?")
  if [[ "$ipf" == "1" ]]; then success "IP forwarding enabled (published ports reachable)"
  else warn "IP forwarding still off (=$ipf) - published ports 80/443/81 may be unreachable"; fi
}

main() {
  printf "\n${C_B}${C_CYN}VPS Deployment -- Docker + NPM + Cosmos + Authelia + CrowdSec${C_R}\n" >&2
  printf "${C_DIM}${SCRIPT_NAME} v${SCRIPT_VERSION}${C_R}\n\n" >&2
  preflight_checks
  idempotent_cleanup
  system_update
  install_dependencies
  install_docker
  ensure_ip_forwarding
  setup_docker_network
  get_user_domain
  setup_cosmos
  setup_stack
  setup_firewall
  setup_crowdsec
  setup_cloudflare_realip
  setup_cloudflare_bouncer
  setup_crowdsec_console
  setup_logrotate
  automate_npm
  register_cosmos_stacks
  verify_deployment
  DEPLOY_STATUS="success"
  print_summary
}

main "$@"
