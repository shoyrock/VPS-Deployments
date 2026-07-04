#!/usr/bin/env bash
# Auto-elevate to root if not already running as root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi

# deploy-arcane-authentik.sh -- Docker + NPM + Arcane + Authentik + CrowdSec (hardened)
# One-click VPS deployment. Usage: sudo ./deploy-arcane-authentik.sh
#   Optional env vars:
#     FORCE_CLEANUP=1              skip the destructive-cleanup confirmation
#     CF_API_TOKEN=<token>         Cloudflare USER API token; enables the CrowdSec
#                                  Cloudflare Worker bouncer (edge IP-ban enforcement).
#                                  If unset, the script prompts; blank = configure later.
#     CF_BOUNCER_ACTION=ban        edge action for banned IPs: ban | captcha (default ban)
#     CROWDSEC_ENROLL_KEY=<key>    optional CrowdSec Console enroll key from
#                                  app.crowdsec.net (Security Engines > Enroll). If set,
#                                  the instance auto-enrolls; else enroll manually later.
#     LOCK_HTTP_TO_CLOUDFLARE=true restrict 80/443 to Cloudflare IP ranges in the
#                                  firewall (default false; turn on once all DNS is proxied)
set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="4.8.0-hardened-cloudflare-authentik"
readonly SCRIPT_NAME="deploy-arcane-authentik.sh"
START_TIME=$(date +%s); readonly START_TIME
readonly STACK_DIR="/opt/apps/arcane-stack"   # infra lives UNDER /opt/apps (unified layout)
readonly NPM_DATA_DIR="${STACK_DIR}/data"
readonly NPM_LE_DIR="${STACK_DIR}/letsencrypt"
readonly NPM_LOGS_DIR="${NPM_DATA_DIR}/logs"
readonly CROWDSEC_DIR="${STACK_DIR}/crowdsec"
readonly ARCANE_DATA_DIR="${STACK_DIR}/arcane-data"
readonly AUTHENTIK_DIR="${STACK_DIR}/authentik"
readonly AUTHENTIK_MEDIA_DIR="${AUTHENTIK_DIR}/media"
readonly AUTHENTIK_TEMPLATES_DIR="${AUTHENTIK_DIR}/templates"
readonly AUTHENTIK_BLUEPRINTS_DIR="${AUTHENTIK_DIR}/blueprints"
readonly AUTHENTIK_CERTS_DIR="${AUTHENTIK_DIR}/certs"
readonly AUTHENTIK_SNIPPETS_DIR="${AUTHENTIK_DIR}/snippets"
readonly DOMAIN_PERSIST_FILE="/etc/vps-deploy-domain"
readonly EMAIL_PERSIST_FILE="/etc/vps-deploy-email"
readonly LOG_FILE="/var/log/vps-deploy.log"

DOMAIN=""  # Set at runtime via user prompt
# Let's Encrypt / NPM admin account email. MUST be a real, valid address:
# Let's Encrypt REJECTS placeholder domains like admin@example.com at ACME
# account registration ("invalid email address"), which fails EVERY cert
# request (HTTP-01 and DNS-01 alike). Set LETSENCRYPT_EMAIL=you@domain to skip
# the prompt for unattended runs.
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"

# --- Authentik (IdP) bootstrap (tokens generated at runtime) ------------------
AUTHENTIK_BOOTSTRAP_TOKEN=""    # generated; akadmin API token for Authentik API
AUTHENTIK_BOOTSTRAP_PASSWORD="" # generated; akadmin initial UI password

# --- Cloudflare integration (Worker bouncer + origin lockdown) ---------------
CF_API_TOKEN="${CF_API_TOKEN:-}"                              # CF USER API token (prompted if empty)
CF_BOUNCER_KEY=""                                            # generated; shared LAPI <-> CF bouncer
CF_BOUNCER_ACTION="${CF_BOUNCER_ACTION:-ban}"                # edge action: ban | captcha
LOCK_HTTP_TO_CLOUDFLARE="${LOCK_HTTP_TO_CLOUDFLARE:-false}"  # restrict 80/443 to Cloudflare ranges
NPM_SKIP_SSL="${NPM_SKIP_SSL:-0}"                            # 1 = create proxy hosts HTTP-only (no Let's Encrypt attempt; do SSL manually in the NPM UI later)
EXPOSE_NPM_ADMIN="${EXPOSE_NPM_ADMIN:-1}"                    # 1 = publish the NPM admin UI at npm.<domain> (NPM's OWN login, NO Authentik). 0 = SSH-tunnel only.
CF_IPS_CACHE=""                                             # filled by get_cloudflare_ips()
WILDCARD_CERT_ID=""                                         # ONE *.DOMAIN cert (DNS-01), reused for every proxy host

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
  local authentik_pass npm_pass
  authentik_pass=$(_read_cred "${AUTHENTIK_DIR}/.akadmin_password")
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
  printf '%s\n' "${C_B}------------------------------------------------------------------------------${C_R}"
  printf "${C_B}  ${C_RED}>> Use http:// (NOT https://) — SSL is not configured yet. See the SSL note below.${C_R}\n"
  if [[ "${EXPOSE_NPM_ADMIN:-1}" == "1" && -n "${DOMAIN:-}" ]]; then
    printf "${C_B}  NPM Admin:     http://npm.%s   (turn ON NPM's 2FA — it's internet-facing)${C_R}\n" "$DOMAIN"
  else
    printf "${C_B}  NPM Admin:     SSH tunnel: ssh -L 8181:127.0.0.1:81 ubuntu@%s -> http://localhost:8181${C_R}\n" "$ip"
  fi
  printf "${C_B}  NPM Login:     %s / %s${C_R}\n" "${LETSENCRYPT_EMAIL:-admin@example.com}" "$npm_pass"
  if [[ "$DEPLOY_STATUS" == "success" ]]; then
    printf "${C_B}  Arcane:      http://arcane.%s${C_R}\n" "$DOMAIN"
    printf "${C_B}  Authentik:     http://authentik.%s${C_R}\n" "$DOMAIN"
    printf '%s\n' "${C_B}------------------------------------------------------------------------------${C_R}"
    printf "${C_B}${C_YEL}  Containers (hostname = container name, via NPM proxy network):${C_R}\n"
    printf "${C_B}    npm                  ->  ports 80, 443, 81 (admin)${C_R}\n"
    printf "${C_B}    arcane             ->  port 3552${C_R}\n"
    printf "${C_B}    authentik-server     ->  port 9000 (IdP; localhost-published for bootstrap)${C_R}\n"
    printf "${C_B}    authentik-worker     ->  background tasks${C_R}\n"
    printf "${C_B}    authentik-postgres   ->  Authentik DB${C_R}\n"
    printf "${C_B}    crowdsec             ->  port 8080 (LAPI, localhost only)${C_R}\n"
    printf '%s\n' "${C_B}------------------------------------------------------------------------------${C_R}"
    printf "${C_B}  ${C_YEL}Authentik admin user: akadmin${C_R}\n"
    printf "${C_B}  ${C_YEL}Authentik password:   %s${C_R}\n" "$authentik_pass"
    printf "${C_B}  ${C_RED}Change this password after first login!${C_R}\n"
    printf "\n"
    printf "${C_B}  ${C_YEL}-- First login / MFA (ENFORCED) --${C_R}\n"
    printf "${C_B}  Browse to http://authentik.%s and log in as akadmin.${C_R}\n" "$DOMAIN"
    printf "${C_B}  MFA is ENFORCED: you are REQUIRED to enroll a TOTP authenticator on first\n"
    printf "  login (have your authenticator app ready). Applies to every user.${C_R}\n"
    if [[ -s "${AUTHENTIK_DIR}/.akadmin_recovery_url" ]]; then
      printf "${C_B}  ${C_RED}Recovery URL (use ONLY if you lose the TOTP device) - SAVE IT SECURELY:${C_R}\n"
      printf "${C_B}  %s${C_R}\n" "$(cat "${AUTHENTIK_DIR}/.akadmin_recovery_url" 2>/dev/null)"
    fi
    printf "\n"
    printf "${C_B}  ${C_YEL}-- HTTPS / SSL (read this) --${C_R}\n"
    printf "${C_B}  Proxy hosts are ${C_RED}HTTP-only right now${C_R}${C_B} (no certificate). Your browser defaults\n"
    printf "  to https, which will FAIL with no cert — so use ${C_RED}http://${C_R}${C_B} for every URL above\n"
    printf "  until you add SSL. To enable HTTPS: open NPM admin -> the host -> SSL tab ->\n"
    printf "  'Request a new SSL Certificate' (Let's Encrypt; DNS must point at this server,\n"
    printf "  port 80 reachable). After that the host auto-redirects http -> https.${C_R}\n"
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
  for d in "$STACK_DIR" /opt/*-stack /opt/npm /opt/casaos /var/lib/casaos; do
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
  # NOTE: only the infra dir ($STACK_DIR = /opt/apps/arcane-stack) is removed
  # from under /opt/apps — NEVER /opt/apps itself (that holds your app stacks).
  # /opt/arcane-stack is kept in the list to clean up OLD pre-move deployments.
  for d in "$STACK_DIR" /opt/arcane-stack /opt/npm /opt/casaos /var/lib/casaos /opt/casaos-stack /opt/coolify-stack /opt/cosmos-stack /opt/dockge-stack /opt/dokploy-stack /opt/portainer-stack /opt/runtipi-stack /opt/freedombox-stack /opt/yunohost-stack /opt/netbird-stack; do
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
    # The CF worker-bouncer postinst READS /etc/crowdsec/bouncers/crowdsec-*.yaml
    # and FATALs if it's missing -> dpkg --configure -a fails, apt blocks forever.
    # We just `rm -rf /etc/crowdsec` above, so RECREATE a minimal valid stub so the
    # postinst can parse it and succeed. (Same trick setup_cloudflare_bouncer uses
    # before installing the package.)
    if dpkg-query -W crowdsec-cloudflare-worker-bouncer &>/dev/null; then
      mkdir -p /etc/crowdsec/bouncers 2>/dev/null || true
      printf '%s\n' 'crowdsec_config:' '  lapi_key: ""' '  lapi_url: http://127.0.0.1:8080/' 'cloudflare_config:' '  accounts: []' 'log_level: info' 'log_media: stdout' \
        > /etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml 2>/dev/null || true
    fi
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confold </dev/null 2>/dev/null || true
    # Belt-and-suspenders: if the stub-config trick didn't unstick it, yank the
    # package with dpkg --force-remove-reinstreq --force-all (bypasses the failing
    # postinst that 'apt-get purge' would re-trigger). Then let apt retry below.
    if dpkg-query -W -f='${db:Status-Abbrev}' crowdsec-cloudflare-worker-bouncer 2>/dev/null | grep -qE '[FHU]'; then
      DEBIAN_FRONTEND=noninteractive dpkg --purge --force-remove-reinstreq --force-all crowdsec-cloudflare-worker-bouncer </dev/null 2>/dev/null || true
    fi
    DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confold crowdsec crowdsec-firewall-bouncer-nftables crowdsec-firewall-bouncer-iptables crowdsec-cloudflare-worker-bouncer </dev/null 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get install -f -y -qq -o DPkg::Lock::Timeout=300 </dev/null 2>/dev/null || true
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
    # Fresh Ubuntu/Debian boots auto-run apt-daily, which grabs the dpkg lock — our
    # very next "apt-get install" then exits 100 and the whole deploy aborts at the
    # Dependencies step (seen on a fresh Oracle VPS). Stop ONLY the in-progress
    # apt-daily run to release the lock now, and set a GLOBAL lock timeout so every
    # apt-get in this run WAITS for the lock (up to 5 min) instead of failing. The
    # apt.conf drop-in persists, so install_dependencies / docker / ufw inherit it.
    # IMPORTANT: do NOT stop/disable the apt-daily TIMERS or unattended-upgrades —
    # that would kill scheduled security auto-updates (harden re-enables + verifies).
    systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
    printf 'DPkg::Lock::Timeout "300";\n' > /etc/apt/apt.conf.d/99deploy-lock-timeout
    # Guard: repair dpkg if cleanup left a half-configured package behind.
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confold </dev/null 2>/dev/null || true
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
    # Guard: repair dpkg if cleanup left a half-configured package behind.
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confold </dev/null 2>/dev/null || true
    apt-get install -y -qq ca-certificates curl gnupg lsb-release \
      software-properties-common apt-transport-https jq unzip cron logrotate rsyslog
  else
    local pkg="yum"; command -v dnf &>/dev/null && pkg="dnf"
    $pkg install -y -q ca-certificates curl gnupg2 yum-utils \
      device-mapper-persistent-data lvm2 jq unzip cronie logrotate rsyslog
  fi
  # rsyslog must run so SSH/auth + system events land in /var/log/auth.log and
  # /var/log/syslog. Ubuntu 24.04 (and other modern distros) ship journald-only by
  # default - those files don't exist without rsyslog, leaving CrowdSec's sshd +
  # linux collections blind (the whole reason a host can sit an hour with 0 hits).
  systemctl enable --now rsyslog 2>/dev/null || true
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
  # Basic sanity check: domain is interpolated into nginx/Authentik configs.
  [[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] || \
    fatal "Invalid domain: '$DOMAIN'"
  printf '%s' "$DOMAIN" > "${DOMAIN_PERSIST_FILE}" || warn "Could not persist domain to ${DOMAIN_PERSIST_FILE}"
  success "Domain set to: $DOMAIN"

  # HSTS-preloaded TLDs (Google-owned: .dev/.app/.page/... ) are hardcoded HTTPS-only
  # inside every browser - http:// is rewritten to https:// before the request is even
  # sent, so there is NO http fallback. Tell the user SSL is mandatory here; the deploy
  # auto-issues ONE wildcard cert (needs a Cloudflare token with Zone:DNS:Edit).
  case ".${DOMAIN##*.}" in
    .dev|.app|.page|.foo|.zip|.mov|.new|.day|.boo|.rsvp|.meme|.dad|.phd|.esq|.prof|.how|.nexus|.channel|.search|.ing|.gle|.prod)
      warn "'.${DOMAIN##*.}' is an HSTS-preloaded TLD: browsers FORCE https:// (no http fallback)."
      warn "  So HTTPS is REQUIRED. This deploy will auto-issue a wildcard cert *.${DOMAIN} via"
      warn "  Cloudflare DNS-01 - have a Cloudflare API token with Zone:DNS:Edit ready when prompted."
      ;;
  esac
}

# Validate an email for Let's Encrypt: must look like a real address AND must NOT
# use a reserved/placeholder domain (example.com/net/org, localhost, .invalid,
# .test, .local) — LE's ACME server rejects those at account registration.
_valid_le_email() {
  local e="$1"
  [[ "$e" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || return 1
  local dom="${e##*@}"; dom="${dom,,}"
  case "$dom" in
    example.com|example.net|example.org|localhost|*.invalid|*.test|*.local|*.example) return 1 ;;
  esac
  return 0
}

get_letsencrypt_email() {
  # A REAL email is mandatory: Let's Encrypt rejects placeholder addresses at ACME
  # account registration, which is why cert issuance was failing with an
  # "Internal Error" in the NPM UI (default account email was admin@example.com).
  # Precedence: LETSENCRYPT_EMAIL env > persisted file > interactive prompt.
  if [[ -n "$LETSENCRYPT_EMAIL" ]] && _valid_le_email "$LETSENCRYPT_EMAIL"; then
    printf '%s' "$LETSENCRYPT_EMAIL" > "${EMAIL_PERSIST_FILE}" 2>/dev/null || true
    success "Let's Encrypt email: $LETSENCRYPT_EMAIL"
    return 0
  fi
  if [[ -z "$LETSENCRYPT_EMAIL" && -f "${EMAIL_PERSIST_FILE}" ]]; then
    local saved; saved=$(tr -d '\n' < "${EMAIL_PERSIST_FILE}" 2>/dev/null || true)
    if _valid_le_email "$saved"; then
      LETSENCRYPT_EMAIL="$saved"; success "Let's Encrypt email: $LETSENCRYPT_EMAIL (reused)"; return 0
    fi
  fi
  # Non-interactive with no valid env/file: fail loudly rather than ship a broken
  # (cert-less) deploy — one-shot means SSL must work on this run.
  if [[ ! -t 0 ]]; then
    fatal "LETSENCRYPT_EMAIL is unset or invalid and no TTY to prompt. Re-run with LETSENCRYPT_EMAIL=you@yourdomain.com"
  fi
  while true; do
    printf "\n${C_B}Enter a real email for Let's Encrypt${C_R} (cert notices; NOT example.com): " >&2
    read -r LETSENCRYPT_EMAIL
    LETSENCRYPT_EMAIL=$(echo "$LETSENCRYPT_EMAIL" | tr -d ' ')
    if _valid_le_email "$LETSENCRYPT_EMAIL"; then break; fi
    warn "Invalid or placeholder email (example.com is rejected by Let's Encrypt). Try again."
  done
  printf '%s' "$LETSENCRYPT_EMAIL" > "${EMAIL_PERSIST_FILE}" 2>/dev/null || true
  success "Let's Encrypt email: $LETSENCRYPT_EMAIL"
}

setup_arcane() {
  step "Arcane (standalone)"
  mkdir -p "${ARCANE_DATA_DIR}"

  # SECURITY: the host filesystem is mounted READ-ONLY (/:/host:ro).
  # The previous read-write mount meant any Arcane compromise = instant,
  # silent root on the host. Note that the docker.sock mount is still
  # root-equivalent by nature (required for a Docker manager), but Authentik
  # 2FA gates all access and the :ro mount removes the easiest abuse path.
  # If you genuinely need write access to host files from the Arcane UI,
  # change "/:/host:ro" to "/:/host" below and re-run:
  #   docker compose -p arcane -f /opt/apps/arcane-stack/docker-compose.arcane.yml up -d --force-recreate
  #
  # /opt/apps mount (identical path, RW): EVERYTHING lives under /opt/apps now -
  # the infra stacks at ${STACK_DIR} (= /opt/apps/arcane-stack) and host-deployed
  # APP stacks at /opt/apps/<app>/. Their compose-project labels point at those
  # HOST paths; Arcane's HostPath resolver can only reach them WRITABLY if
  # /opt/apps is bind-mounted at the IDENTICAL path. Without it the stacks show
  # UNTAGGED (see-but-not-edit via the read-only /host mount) and can't be adopted.
  # With it, every stack under /opt/apps is editable + adoptable. docker.sock
  # already makes Arcane root-equivalent, so this opens no new attack path.

  # Arcane secrets: 32-byte ENCRYPTION_KEY + JWT_SECRET (both REQUIRED by Arcane).
  # Written to a locked-down env file so they never sit in the world-readable
  # compose YAML. Regenerated only if not already provided via the environment.
  ARCANE_ENCRYPTION_KEY="${ARCANE_ENCRYPTION_KEY:-$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
  ARCANE_JWT_SECRET="${ARCANE_JWT_SECRET:-$(rand_secret)}"
  ( umask 077; cat > "${STACK_DIR}/.arcane.env" << EOF
ENVIRONMENT=production
GIN_MODE=release
PORT=3552
APP_URL=https://arcane.${DOMAIN}
ENCRYPTION_KEY=${ARCANE_ENCRYPTION_KEY}
JWT_SECRET=${ARCANE_JWT_SECRET}
EOF
  )
  chmod 600 "${STACK_DIR}/.arcane.env" 2>/dev/null || true

  cat > "${STACK_DIR}/docker-compose.arcane.yml" << 'COMPOSE_ARCANE'
services:
  arcane:
    image: ghcr.io/getarcaneapp/manager:latest
    container_name: arcane
    hostname: arcane
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    env_file:
      - .arcane.env
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /opt/apps:/opt/apps
      - ./arcane-data:/app/data
      - /:/host:ro
    networks:
      - proxy
networks:
  proxy:
    external: true
COMPOSE_ARCANE

  info "Pulling Arcane image..."
  docker compose -p arcane -f "${STACK_DIR}/docker-compose.arcane.yml" pull
  docker compose -p arcane -f "${STACK_DIR}/docker-compose.arcane.yml" up -d --force-recreate

  info "Waiting for Arcane to be ready..."
  for i in $(seq 1 30); do
    printf "\r  ${C_DIM}Waiting for Arcane... %d/30${C_R}" "$i" >&2
    sleep 2
    if docker ps --format '{{.Names}}' | grep -qx "arcane"; then
        printf "\r" >&2
        success "Arcane ready"
        break
    fi
    [[ $i -eq 30 ]] && { printf "\r" >&2; warn "Arcane may still be starting. Check: docker logs arcane"; }
  done
  printf "\r" >&2
}

setup_stack() {
  step "Deploying NPM, Authentik and CrowdSec"
  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<VPS_IP>")
  # Shared key: CrowdSec pre-registers it as a bouncer (BOUNCER_KEY_* env below),
  # and setup_cloudflare_bouncer writes the SAME key into the config.
  CF_BOUNCER_KEY=$(rand_password 48)
  # Per-deploy Authentik bootstrap secrets (akadmin API token + initial password).
  AUTHENTIK_BOOTSTRAP_TOKEN=$(rand_password 48)
  AUTHENTIK_BOOTSTRAP_PASSWORD=$(rand_password 24)
  mkdir -p "$NPM_DATA_DIR" "$NPM_LE_DIR" "$NPM_LOGS_DIR" "$CROWDSEC_DIR" \
           "$AUTHENTIK_DIR" "$AUTHENTIK_MEDIA_DIR" "$AUTHENTIK_TEMPLATES_DIR" \
           "$AUTHENTIK_BLUEPRINTS_DIR" "$AUTHENTIK_CERTS_DIR" "$AUTHENTIK_SNIPPETS_DIR"

  cat > "${STACK_DIR}/docker-compose.authentik.yml" << 'COMPOSE_AUTHENTIK'
services:
  authentik-postgres:
    image: postgres:16-alpine
    container_name: authentik-postgres
    hostname: authentik-postgres
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -d authentik -U authentik"]
      interval: 10s
      timeout: 5s
      retries: 5
    env_file: ./authentik/authentik.env
    volumes:
      - ./authentik/postgres:/var/lib/postgresql/data
    networks:
      - proxy
  # NOTE: authentik 2025.x+ removed the external Redis dependency (task queue moved
  # to a PostgreSQL backend; cache is embedded). authentik's own official compose
  # ships only postgresql + server + worker, so there is NO redis container here.
  authentik-server:
    image: ghcr.io/goauthentik/server:2026.5.3
    container_name: authentik-server
    hostname: authentik-server
    restart: unless-stopped
    command: server
    env_file: ./authentik/authentik.env
    ports:
      - "127.0.0.1:9000:9000"
    volumes:
      - ./authentik/media:/media
      - ./authentik/templates:/templates
      - ./authentik/blueprints:/blueprints/custom
      - ./authentik/certs:/certs
    depends_on:
      authentik-postgres:
        condition: service_healthy
    networks:
      - proxy
  authentik-worker:
    image: ghcr.io/goauthentik/server:2026.5.3
    container_name: authentik-worker
    hostname: authentik-worker
    restart: unless-stopped
    command: worker
    env_file: ./authentik/authentik.env
    user: root
    volumes:
      # docker.sock intentionally NOT mounted. The worker only needs it for the Docker
      # OUTPOST controller, which this stack does not use (embedded outpost runs inside
      # authentik-server). Dropping it removes root-equivalent host access from the
      # worker -- one less thing an attacker can pivot through.
      - ./authentik/media:/media
      - ./authentik/templates:/templates
      - ./authentik/blueprints:/blueprints/custom
      - ./authentik/certs:/certs
    depends_on:
      authentik-postgres:
        condition: service_healthy
    networks:
      - proxy
networks:
  proxy:
    external: true
COMPOSE_AUTHENTIK

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
      # Admin UI bound to LOCALHOST only: it's reached via the npm.<domain> proxy
      # host (created below) + SSH tunnel, so 81 is never on 0.0.0.0 / never needs
      # to be opened in the cloud firewall. The deploy's own API calls use 127.0.0.1:81.
      - 127.0.0.1:81:81
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
      # All free community-hub collections, scoped to what this VPS actually
      # has an acquisition source for (SSH/auth.log, syslog, NPM/nginx web logs):
      #   sshd                  - SSH brute force + CVEs (auth.log)
      #   linux                 - host/system scenarios (syslog)
      #   nginx-proxy-manager   - NPM access/error log scenarios (web)
      #   base-http-scenarios   - generic web attacks: scanning, probing, path
      #                           traversal, bad user-agents, crawlers (web)
      #   http-cve              - known HTTP CVE exploit attempts (web)
      #   http-dos              - HTTP denial-of-service (web)
      #   whitelist-good-actors - cuts false positives (search-engine/CDN IPs)
      # NOT enabled (no acquisition source / needs extra wiring): iptables
      # (no nft/iptables log feed), appsec-* (needs the AppSec/WAF engine + a
      # bouncer that forwards requests), postfix/mariadb/etc (no such service).
      - COLLECTIONS=crowdsecurity/sshd crowdsecurity/linux crowdsecurity/nginx-proxy-manager crowdsecurity/base-http-scenarios crowdsecurity/http-cve crowdsecurity/http-dos crowdsecurity/whitelist-good-actors
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
  docker compose -p npm -f "${STACK_DIR}/docker-compose.npm.yml" pull
  docker compose -p crowdsec -f "${STACK_DIR}/docker-compose.crowdsec.yml" pull

  info "Starting NPM..."
  docker compose -p npm -f "${STACK_DIR}/docker-compose.npm.yml" up -d
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

  info "Deploying Authentik (postgres + server + worker)..."
  gen_authentik_files
  setup_authentik_snippets      # write nginx forward-auth snippets into NPM custom dir
  docker compose -p authentik -f "${STACK_DIR}/docker-compose.authentik.yml" pull
  docker compose -p authentik -f "${STACK_DIR}/docker-compose.authentik.yml" up -d
  info "Waiting for Authentik server (first boot runs migrations - up to ~3 min)..."
  # Probe from the HOST against the published API port (127.0.0.1:9000). The
  # goauthentik image ships NO curl, so 'docker exec ... curl' always failed in
  # older scripts; probe from the host and fall back to the container healthcheck.
  local ak_ok=false
  for i in $(seq 1 75); do
    if curl -sf --max-time 5 -o /dev/null http://127.0.0.1:9000/-/health/ready/ 2>/dev/null \
       || [[ "$(docker inspect -f '{{.State.Health.Status}}' authentik-server 2>/dev/null)" == "healthy" ]]; then
      ak_ok=true; break
    fi
    printf "\r  ${C_DIM}Waiting for Authentik... %d/75${C_R}" "$i" >&2
    sleep 4
  done
  printf "\r" >&2
  $ak_ok && success "Authentik ready" || warn "Authentik not healthy yet. Check: docker logs authentik-server"

  # Bootstrap the IdP via the admin API: create the Proxy provider + Application
  # + embedded outpost that gates Arcane behind Authentik forward-auth (nginx
  # auth_request). Degrades gracefully with manual instructions on any failure.
  bootstrap_authentik

  # Enforce TOTP MFA SEPARATELY from the provider/outpost bootstrap above, so an
  # early return there (provider/app/outpost hiccup) can never skip MFA. Fail-safe.
  enforce_authentik_mfa

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
  docker compose -p crowdsec -f "${STACK_DIR}/docker-compose.crowdsec.yml" up -d crowdsec
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

  # Hard guard: creating the NPM admin with an empty/placeholder email produces an
  # account we can't log into (and LE can't use) -> automation silently skips and
  # NO proxy hosts get created (the "Congratulations / host not set up" page). The
  # email must be resolved by get_letsencrypt_email() before we get here.
  _valid_le_email "$LETSENCRYPT_EMAIL" || fatal "LETSENCRYPT_EMAIL is unset/invalid ('$LETSENCRYPT_EMAIL'). Cannot create the NPM admin. Set LETSENCRYPT_EMAIL=you@yourdomain.com and re-run."

  # NPM 2.15+ ships with NO default user: GET /api/ reports "setup":false and the
  # FIRST admin is created via an UNAUTHENTICATED POST /api/users (the old
  # admin@example.com/changeme login can NEVER work on these versions -> was the
  # cause of "Invalid email or password" + no proxy hosts). Detect that and create
  # the admin directly with our random password. Older NPM falls through to the
  # legacy default-login path below.
  # Read the flag RAW: jq '.setup // empty' would return empty when setup IS false
  # (jq's // treats boolean false as absent) - the exact case we must catch. Poll a
  # few times so a not-yet-ready NPM API doesn't fall through to the legacy
  # (changeme) path, which can NEVER work on NPM 2.15+.
  local _setup="" _st
  for _st in 1 2 3 4 5 6 7 8; do
    _setup=$(_npm_api "/" 2>/dev/null | jq -r '.setup' 2>/dev/null || echo "")
    [[ "$_setup" == "true" || "$_setup" == "false" ]] && break
    sleep 3
  done
  if [[ "$_setup" == "false" ]]; then
    printf '%s' "$NEW_PASS" > "${STACK_DIR}/.npm_admin_password"
    chmod 600 "${STACK_DIR}/.npm_admin_password"
    NPM_TOKEN=""
    local _cu _t
    # Create the first admin with the REAL Let's Encrypt email so NPM's own cert
    # requests (and any issued from the UI) register a valid ACME account. Using
    # admin@example.com here is what made every cert fail ("invalid email address").
    _cu=$(jq -nc --arg pw "$NEW_PASS" --arg email "$LETSENCRYPT_EMAIL" '{name:"Administrator",nickname:"Admin",email:$email,roles:["admin"],is_disabled:false,auth:{type:"password",secret:$pw}}')
    for _t in 1 2 3 4 5; do
      _npm_api "/users" -d "$_cu" >/dev/null 2>&1 || true
      LOGIN=$(_npm_api "/tokens" -d "$(jq -nc --arg id "$LETSENCRYPT_EMAIL" --arg s "$NEW_PASS" '{identity:$id,secret:$s}')" 2>/dev/null) || true
      NPM_TOKEN=$(echo "$LOGIN" | jq -r '.token // empty' 2>/dev/null)
      [[ -n "$NPM_TOKEN" ]] && break
      sleep 3
    done
    if [[ -n "$NPM_TOKEN" ]]; then
      success "NPM first admin created (${LETSENCRYPT_EMAIL}) - password saved to ${STACK_DIR}/.npm_admin_password (mode 600)"
      return 0
    fi
    warn "NPM setup-mode first-user creation failed; falling back to the legacy default-login path."
  fi

  # NPM's API can briefly reject logins right after a container/daemon restart -
  # and the firewall step runs `systemctl restart docker` just before this. So
  # retry the initial default-credential login instead of giving up on the first
  # transient failure (the old single-shot was the #1 reason automated NPM setup
  # silently skipped, leaving DEFAULT creds + no proxy hosts).
  JSON='{"identity":"admin@example.com","secret":"changeme"}'
  NPM_TOKEN=""
  local _try
  for _try in $(seq 1 8); do
    LOGIN=$(_npm_api "/tokens" -d "$JSON" 2>/dev/null) || true
    NPM_TOKEN=$(echo "$LOGIN" | jq -r '.token // empty' 2>/dev/null)
    [[ -n "$NPM_TOKEN" ]] && break
    printf "\r  ${C_DIM}Waiting for NPM API to accept default login... %d/8${C_R}" "$_try" >&2
    sleep 5
  done
  printf "\r" >&2
  if [[ -z "$NPM_TOKEN" ]]; then
    # REDEPLOY over PERSISTED NPM data: not setup-mode (admin exists) and not on
    # 'changeme' (a prior run already secured it). Recover by logging in with the
    # password THIS script saved last time, trying the real email and the legacy
    # placeholder. If it works we already own the account and can proceed.
    local _saved=""
    [[ -f "${STACK_DIR}/.npm_admin_password" ]] && _saved=$(tr -d '\n' < "${STACK_DIR}/.npm_admin_password" 2>/dev/null || true)
    if [[ -n "$_saved" ]]; then
      local _id
      for _id in "$LETSENCRYPT_EMAIL" "admin@example.com"; do
        LOGIN=$(_npm_api "/tokens" -d "$(jq -nc --arg id "$_id" --arg s "$_saved" '{identity:$id,secret:$s}')" 2>/dev/null) || true
        NPM_TOKEN=$(echo "$LOGIN" | jq -r '.token // empty' 2>/dev/null)
        [[ -n "$NPM_TOKEN" ]] && break
      done
    fi
    if [[ -n "$NPM_TOKEN" ]]; then
      # Ensure the existing account's email is the real one (older runs used the
      # placeholder) so cert issuance works, and re-affirm the saved password.
      _npm_api "/users/1" -X PUT -d "$(jq -nc --arg email "$LETSENCRYPT_EMAIL" '{name:"Administrator",nickname:"Admin",email:$email,roles:["admin"],is_disabled:false}')" >/dev/null 2>&1 || true
      success "Reused existing NPM admin via saved password (${LETSENCRYPT_EMAIL})"
      return 0
    fi
    # Log the raw rejection so the cause is diagnosable (wrong default creds, NPM
    # not ready, API shape change) instead of a blind "skipping".
    _log "WARN" "NPM /tokens login response: $(printf '%s' "$LOGIN" | tr -d '\n' | cut -c1-300)"
    warn "Could not get NPM token (setup-mode, 'changeme', and saved-password all failed). Raw response in ${LOG_FILE}. Skipping automated NPM setup - change the password manually at :81, or wipe NPM data and re-run."
    return 1
  fi

  # Persist the new password BEFORE applying it, so a flaky re-auth can never
  # leave the account on a random password we did not record (= hard lockout of
  # the NPM admin UI). If the change PUT fails, 'changeme' still works - recoverable.
  printf '%s' "$NEW_PASS" > "${STACK_DIR}/.npm_admin_password"
  chmod 600 "${STACK_DIR}/.npm_admin_password"
  JSON=$(jq -nc --arg s "$NEW_PASS" '{type:"password",current:"changeme",secret:$s}')
  _npm_api "/users/1/auth" -X PUT -d "$JSON" >/dev/null 2>&1 || true
  # Replace the placeholder account email (admin@example.com) with the REAL one so
  # Let's Encrypt account registration succeeds. Uses the token from the changeme
  # login, which stays valid across the password change. After this the login
  # identity is $LETSENCRYPT_EMAIL, so re-auth below uses it.
  JSON=$(jq -nc --arg email "$LETSENCRYPT_EMAIL" '{name:"Administrator",nickname:"Admin",email:$email,roles:["admin"],is_disabled:false}')
  _npm_api "/users/1" -X PUT -d "$JSON" >/dev/null 2>&1 || true
  # Re-authenticate with new password (retry: NPM can briefly 401 right after the change)
  NPM_TOKEN=""
  for _ in 1 2 3; do
    JSON=$(jq -nc --arg id "$LETSENCRYPT_EMAIL" --arg s "$NEW_PASS" '{identity:$id,secret:$s}')
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
  RESP=$(_npm_api "/nginx/proxy-hosts" -X POST -d "$JSON") || true
  ID=$(echo "$RESP" | jq -r '.id // empty')
  if [[ -n "$ID" ]]; then
    success "Created proxy host: ${DOMAIN_NAME} -> ${FWD_HOST}:${FWD_PORT}"
    echo "$ID"
  else
    warn "Failed to create proxy host for ${DOMAIN_NAME}: $(echo "$RESP" | jq -r '.error.message // .message // "unknown error"' 2>/dev/null)"
    return 1
  fi
}

npm_ensure_wildcard_cert() {
  # Issue (or REUSE) ONE wildcard certificate *.DOMAIN via Cloudflare DNS-01 and
  # cache its id in WILDCARD_CERT_ID. Rationale:
  #  - ONE request covers EVERY subdomain (arcane, authentik, npm, crowdsec + any
  #    added later) -> smallest possible Let's Encrypt rate-limit footprint.
  #  - Wildcards can ONLY be validated by DNS-01 (LE rule) - which is also the only
  #    method that works behind the Authentik auth gate AND on HSTS-preloaded TLDs
  #    like .dev/.app/.page (where browsers FORCE https, so SSL is mandatory).
  #  - On re-runs we REUSE an existing matching cert, so repeated deploys can never
  #    trip the duplicate-certificate limit.
  WILDCARD_CERT_ID=""
  [[ "${NPM_SKIP_SSL:-0}" == "1" ]] && return 0
  local certs existing
  certs=$(_npm_api "/nginx/certificates" 2>/dev/null || true)
  existing=$(echo "$certs" | jq -r --arg d "*.${DOMAIN}" \
    '[.[]? | select(.provider=="letsencrypt") | select(((.domain_names // []) | index($d)) != null) | .id] | max // empty' 2>/dev/null || true)
  if [[ -n "$existing" && "$existing" != "null" ]]; then
    WILDCARD_CERT_ID="$existing"
    success "Reusing existing wildcard certificate *.${DOMAIN} (cert id ${WILDCARD_CERT_ID}) - no new Let's Encrypt request"
    return 0
  fi
  if [[ -z "${CF_API_TOKEN:-}" ]]; then
    warn "No Cloudflare token -> cannot auto-issue the wildcard (*.${DOMAIN} REQUIRES DNS-01)."
    warn "  Hosts stay HTTP-only. On HSTS-preloaded TLDs (.dev/.app/.page) browsers FORCE https,"
    warn "  so either add a DNS-challenge cert in the NPM UI, or re-run with CF_API_TOKEN set."
    return 1
  fi
  # NOTE: NPM takes the LE account email from the logged-in NPM USER (set to
  # $LETSENCRYPT_EMAIL in npm_change_password), NOT the payload. The cert "meta"
  # schema is STRICT (additionalProperties:false): only dns_challenge / dns_provider
  # / dns_provider_credentials / propagation_seconds are allowed.
  local json resp
  json=$(jq -nc --arg d "$DOMAIN" --arg tok "$CF_API_TOKEN" '{
    provider: "letsencrypt",
    nice_name: ("*." + $d),
    domain_names: [("*." + $d), $d],
    meta: {
      dns_challenge: true,
      dns_provider: "cloudflare",
      dns_provider_credentials: ("dns_cloudflare_api_token = " + $tok),
      propagation_seconds: 30
    }
  }')
  info "Requesting ONE wildcard certificate for *.${DOMAIN} (+ ${DOMAIN}) via Cloudflare DNS-01 (up to ~2 min)..."
  resp=$(_npm_api "/nginx/certificates" --max-time 200 -X POST -d "$json") || true
  WILDCARD_CERT_ID=$(echo "$resp" | jq -r '.id // empty')
  if [[ -z "$WILDCARD_CERT_ID" ]]; then
    _log "WARN" "wildcard cert response: $(printf '%s' "$resp" | tr -d '\n' | cut -c1-400)"
    warn "Wildcard cert issuance FAILED. Check the CF token has Zone:DNS:Edit on ${DOMAIN}. Raw response in ${LOG_FILE}. Hosts stay HTTP-only."
    return 1
  fi
  success "Wildcard certificate issued: *.${DOMAIN} (cert id ${WILDCARD_CERT_ID}) - covers every subdomain"
  return 0
}

npm_enable_ssl() {
  # Attach the SHARED wildcard certificate (from npm_ensure_wildcard_cert) to a
  # proxy host - one *.DOMAIN cert serves every host, no per-host LE request. GET the
  # full host config, merge SSL fields, PUT the whole object back (NPM's PUT replaces
  # the resource, so all fields must be resent or forward_host is lost).
  local HOST_ID="$1"
  local DOMAIN_NAME="$2"
  local CERT_ID="${3:-$WILDCARD_CERT_ID}"
  local JSON RESP HOST_JSON
  if [[ -z "$CERT_ID" ]]; then
    warn "No wildcard certificate available - ${DOMAIN_NAME} stays HTTP-only (supply a Cloudflare token with Zone:DNS:Edit to auto-issue *.${DOMAIN})."
    return 1
  fi

  HOST_JSON=$(_npm_api "/nginx/proxy-hosts/${HOST_ID}") || true
  if [[ -z "$HOST_JSON" ]]; then
    warn "Could not fetch host ${HOST_ID} config to attach SSL — attach manually in NPM UI"
    return 1
  fi
  JSON=$(echo "$HOST_JSON" | jq -c --argjson cert "$CERT_ID" '{
    domain_names: .domain_names,
    forward_scheme: .forward_scheme,
    forward_host: .forward_host,
    forward_port: .forward_port,
    access_list_id: (.access_list_id // 0),
    certificate_id: $cert,
    ssl_forced: true,
    caching_enabled: (.caching_enabled // false),
    block_exploits: (.block_exploits // true),
    allow_websocket_upgrade: (.allow_websocket_upgrade // true),
    http2_support: true,
    hsts_enabled: true,
    hsts_subdomains: false,
    advanced_config: (.advanced_config // "")
  }')
  RESP=$(_npm_api "/nginx/proxy-hosts/${HOST_ID}" -X PUT -d "$JSON") || true
  if [[ -n "$(echo "$RESP" | jq -r '.id // empty')" ]]; then
    success "SSL enabled + forced for ${DOMAIN_NAME} (cert id ${CERT_ID})"
  else
    warn "Could not attach certificate ${CERT_ID} to host ${HOST_ID} - attach it manually in NPM UI"
  fi
}

# -------------------------------------------------------------------------------
# Authentik (IdP) - env file, admin API bootstrap, NPM forward-auth snippets
# -------------------------------------------------------------------------------
gen_authentik_files() {
  step "Authentik Environment"
  local ak_secret pg_pass
  ak_secret=$(rand_secret); pg_pass=$(rand_password 32)
  # Unquoted heredoc: the bootstrap token/password + generated secrets are
  # interpolated at runtime. The env file is read by all four Authentik
  # containers (server, worker, postgres) via env_file in the compose.
  cat > "${AUTHENTIK_DIR}/authentik.env" << AK_ENV
AUTHENTIK_SECRET_KEY=${ak_secret}
AUTHENTIK_ERROR_REPORTING__ENABLED=false
AUTHENTIK_POSTGRESQL__HOST=authentik-postgres
AUTHENTIK_POSTGRESQL__USER=authentik
AUTHENTIK_POSTGRESQL__NAME=authentik
AUTHENTIK_POSTGRESQL__PASSWORD=${pg_pass}
AUTHENTIK_EMAIL__FROM=admin@${DOMAIN}
AUTHENTIK_BOOTSTRAP_PASSWORD=${AUTHENTIK_BOOTSTRAP_PASSWORD}
AUTHENTIK_BOOTSTRAP_TOKEN=${AUTHENTIK_BOOTSTRAP_TOKEN}
AUTHENTIK_BOOTSTRAP_EMAIL=admin@${DOMAIN}
POSTGRES_USER=authentik
POSTGRES_DB=authentik
POSTGRES_PASSWORD=${pg_pass}
AK_ENV
  chmod 600 "${AUTHENTIK_DIR}/authentik.env"
  # Persist the akadmin initial password for the summary + _on_exit (mode 600).
  printf '%s' "$AUTHENTIK_BOOTSTRAP_PASSWORD" > "${AUTHENTIK_DIR}/.akadmin_password"
  chmod 600 "${AUTHENTIK_DIR}/.akadmin_password"
  success "Authentik env written: ${AUTHENTIK_DIR}/authentik.env"
}

# Authentik admin API via the bootstrap token (server published on 127.0.0.1:9000).
AK_API_BASE="http://127.0.0.1:9000/api/v3"
_ak_api() {
  local path="$1"; shift
  curl -s --max-time 30 \
    -H "Authorization: Bearer ${AUTHENTIK_BOOTSTRAP_TOKEN}" \
    -H "Content-Type: application/json" \
    "${AK_API_BASE}${path}" "$@"
}

bootstrap_authentik() {
  step "Bootstrapping Authentik (IdP) - provider + outpost for Arcane"

  # 1. Health: first boot runs DB migrations (~2-3 min). Re-check here in case
  #    setup_stack's wait was on the boundary.
  local ok=false i
  for i in $(seq 1 45); do
    if curl -sf --max-time 5 -o /dev/null http://127.0.0.1:9000/-/health/ready/ 2>/dev/null; then
      ok=true; break
    fi
    printf "\r  ${C_DIM}Waiting for Authentik API... %d/45${C_R}" "$i" >&2
    sleep 4
  done; printf "\r" >&2
  if ! $ok; then
    warn "Authentik API not ready. Create the Arcane provider/app/outpost manually once it's up:"
    warn "  https://authentik.${DOMAIN} -> Admin Interface -> Providers > Create > Proxy"
    return 0
  fi
  success "Authentik API reachable"

  # 1b. The health endpoint above needs NO auth, so it cannot detect a bad/missing
  #     bootstrap token - which is exactly what makes every subsequent API call
  #     return 403 and the flow lookup come back empty ("Could not resolve flow").
  #     Probe an AUTHENTICATED endpoint and report the HTTP code so the real cause
  #     (403 = token problem, 404 = path/version) is obvious instead of a vague warn.
  # The akadmin user + bootstrap API token are created during Authentik's startup
  # bootstrap, which can lag several seconds BEHIND the health endpoint reporting
  # ready - so the token 403s for a short window even though the server is "up".
  # Every prior run probed exactly once, ~1s after ready, got 403, and bailed
  # ("Could not resolve flow"). RETRY the authenticated probe until it succeeds,
  # then fall back with the exact HTTP code (403=token, 404=path/version).
  local ak_auth_code="" i
  for i in $(seq 1 24); do
    ak_auth_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
      -H "Authorization: Bearer ${AUTHENTIK_BOOTSTRAP_TOKEN}" \
      "${AK_API_BASE}/core/users/me/" 2>/dev/null || echo "000")
    [[ "$ak_auth_code" == "200" ]] && break
    printf "\r  ${C_DIM}Waiting for Authentik bootstrap token... %d/24 (HTTP %s)${C_R}" "$i" "$ak_auth_code" >&2
    sleep 5
  done
  printf "\r" >&2
  _log "INFO" "Authentik token auth probe (/core/users/me/) -> HTTP ${ak_auth_code}"
  if [[ "$ak_auth_code" != "200" ]]; then
    warn "Authentik bootstrap token did NOT authenticate (HTTP ${ak_auth_code} after ~2m) - cannot"
    warn "  create the Arcane provider/app/outpost via API, so Arcane has NO 2FA gate yet."
    warn "  akadmin UI login still works: https://authentik.${DOMAIN}"
    warn "  (akadmin / see ${AUTHENTIK_DIR}/.akadmin_password). Create the Proxy provider +"
    warn "  attach it to the embedded outpost manually, or re-run."
    return 0
  fi
  success "Authentik bootstrap token authenticated (HTTP 200)"

  # 2. Resolve the authorization flow PK (FK target for the provider). Try the
  #    implicit- then explicit-consent defaults, then ANY authorization-designation
  #    flow, so a renamed/blueprint-customized default still resolves.
  # RETRY: Authentik's default flows are created by its BLUEPRINT system, which
  # finishes applying a little AFTER the /-/health/ready/ endpoint goes green (more
  # noticeably on 2025.x/2026.x). A single query here raced ahead of the blueprints
  # and came back empty -> the provider was never created -> the embedded outpost
  # stayed empty -> forward-auth returned HTTP 500. Poll for up to ~2 min until the
  # authorization flow exists (this doubles as the real "blueprints applied" signal).
  local flow_pk="" slug _fa
  for _fa in $(seq 1 24); do
    for slug in default-provider-authorization-implicit-consent default-provider-authorization-explicit-consent; do
      flow_pk=$(_ak_api "/flows/instances/${slug}/" 2>/dev/null | jq -r '.pk // empty' 2>/dev/null || true)
      [[ -n "$flow_pk" ]] && break
      flow_pk=$(_ak_api "/flows/instances/?slug=${slug}" 2>/dev/null | jq -r '.results[0].pk // empty' 2>/dev/null || true)
      [[ -n "$flow_pk" ]] && break
    done
    [[ -z "$flow_pk" ]] && flow_pk=$(_ak_api "/flows/instances/?designation=authorization" 2>/dev/null \
             | jq -r '.results[0].pk // empty' 2>/dev/null || true)
    [[ -n "$flow_pk" ]] && break
    sleep 5
  done
  if [[ -z "$flow_pk" ]]; then
    warn "Could not resolve Authentik authorization flow via API (blueprints not applied after ~2 min). Create the Arcane provider manually."
    return 0
  fi

  # Authentik 2024.x makes invalidation_flow REQUIRED for proxy providers; without
  # it the POST 400s ("invalidation_flow: This field is required.") and forward-auth
  # silently never gets set up. Resolve the default invalidation flow (slug varies
  # by version -> fall back to designation=invalidation).
  local inval_pk=""
  inval_pk=$(_ak_api "/flows/instances/default-provider-invalidation-flow/" 2>/dev/null | jq -r '.pk // empty' 2>/dev/null || true)
  [[ -z "$inval_pk" ]] && inval_pk=$(_ak_api "/flows/instances/default-invalidation-flow/" 2>/dev/null | jq -r '.pk // empty' 2>/dev/null || true)
  [[ -z "$inval_pk" ]] && inval_pk=$(_ak_api "/flows/instances/?designation=invalidation" 2>/dev/null | jq -r '.results[0].pk // empty' 2>/dev/null || true)

  # 3. Create a Proxy provider (forward_single = nginx auth_request, single app).
  #    Include invalidation_flow only when resolved (older Authentik doesn't need it).
  local prov_json prov_pk
  prov_json=$(jq -nc \
    --arg name "arcane" \
    --arg flow "$flow_pk" \
    --arg inval "$inval_pk" \
    --arg internal "http://arcane:3552" \
    --arg external "https://arcane.${DOMAIN}" \
    '{name:$name, authorization_flow:$flow, internal_host:$internal, external_host:$external, mode:"forward_single"}
     + (if $inval != "" then {invalidation_flow:$inval} else {} end)')
  prov_pk=$(_ak_api "/providers/proxy/" -X POST -d "$prov_json" 2>/dev/null \
           | jq -r '.pk // empty' 2>/dev/null || true)
  if [[ -z "$prov_pk" ]]; then
    # Maybe it already exists from a previous run: look it up by name.
    prov_pk=$(_ak_api "/providers/proxy/?name=arcane" 2>/dev/null \
             | jq -r '.results[0].pk // empty' 2>/dev/null || true)
  fi
  if [[ -z "$prov_pk" ]]; then
    warn "Could not create Authentik Proxy provider. Create it in the UI:"
    warn "  Providers > Create > Proxy: name=arcane, mode=Forward single (nginx),"
    warn "  internal_host=http://arcane:3552, external_host=https://arcane.${DOMAIN}"
    return 0
  fi
  success "Authentik Proxy provider 'arcane' created (pk ${prov_pk})"

  # 4. Create the Application bound to that provider.
  local app_json
  app_json=$(jq -nc --arg name "Arcane" --arg slug "arcane" --argjson prov "$prov_pk" \
    '{name:$name, slug:$slug, provider:$prov}')
  _ak_api "/core/applications/" -X POST -d "$app_json" >/dev/null 2>&1 || true
  if _ak_api "/core/applications/arcane/" 2>/dev/null | jq -e '.pk // empty' >/dev/null 2>/dev/null; then
    success "Authentik Application 'arcane' created"
  else
    warn "Could not create Authentik Application 'arcane'. Create it in the UI (slug=arcane, provider=arcane)."
    return 0
  fi

  # 5. Attach the arcane provider to the BUILT-IN embedded outpost.
  #    CRITICAL: only the managed embedded outpost (managed ==
  #    "goauthentik.io/outposts/embedded") actually runs INSIDE authentik-server
  #    and serves /outpost.goauthentik.io/ (the auth_request endpoint the NPM
  #    snippet proxies to). Creating a brand-new standalone outpost would leave it
  #    with NO running instance (no docker/k8s service connection) -> the
  #    forward-auth subrequest 502s and Arcane's 2FA gate silently never works.
  #    So: find the embedded outpost and MERGE the arcane provider into it.
  #    (Outpost pk is a UUID string; provider pk is an integer.)
  local outpost_pk outpost_list existing_providers merged_providers existing_config merged_config
  outpost_list=$(_ak_api "/outposts/instances/?page_size=100" 2>/dev/null || true)
  outpost_pk=$(echo "$outpost_list" \
    | jq -r '.results[]? | select(.managed=="goauthentik.io/outposts/embedded") | .pk' 2>/dev/null | head -1)
  # Fallback: first proxy-type outpost, in case the managed flag differs by version.
  [[ -z "$outpost_pk" ]] && outpost_pk=$(echo "$outpost_list" \
    | jq -r '.results[]? | select(.type=="proxy") | .pk' 2>/dev/null | head -1)
  if [[ -z "$outpost_pk" ]]; then
    warn "Could not find the embedded Authentik outpost. Attach the provider in the UI:"
    warn "  Outposts > 'authentik Embedded Outpost' > Edit > add the 'arcane' provider."
    return 0
  fi
  # Merge - do NOT clobber providers already attached to the embedded outpost.
  existing_providers=$(echo "$outpost_list" \
    | jq -c --arg pk "$outpost_pk" '.results[]? | select(.pk==$pk) | .providers' 2>/dev/null || true)
  [[ -z "$existing_providers" || "$existing_providers" == "null" ]] && existing_providers="[]"
  merged_providers=$(jq -nc --argjson cur "$existing_providers" --argjson p "$prov_pk" \
    '($cur + [$p]) | unique' 2>/dev/null || echo "[$prov_pk]")
  # ALSO set the outpost's authentik_host. The embedded outpost ships with an EMPTY
  # authentik_host, which makes Authentik show "authentik domain is not configured.
  # Authentication will not work." and breaks redirect URLs. Merge it into the
  # existing config so the other config keys (log_level, naming template, ...) survive.
  existing_config=$(echo "$outpost_list" \
    | jq -c --arg pk "$outpost_pk" '.results[]? | select(.pk==$pk) | .config' 2>/dev/null || true)
  [[ -z "$existing_config" || "$existing_config" == "null" ]] && existing_config="{}"
  merged_config=$(jq -nc --argjson cfg "$existing_config" --arg h "https://authentik.${DOMAIN}" \
    '$cfg + {authentik_host:$h, authentik_host_insecure:false}' 2>/dev/null \
    || printf '{"authentik_host":"https://authentik.%s","authentik_host_insecure":false}' "$DOMAIN")
  if _ak_api "/outposts/instances/${outpost_pk}/" -X PATCH \
       -d "$(jq -nc --argjson p "$merged_providers" --argjson c "$merged_config" '{providers:$p, config:$c}')" 2>/dev/null \
       | jq -e '.pk // empty' >/dev/null 2>&1; then
    success "Arcane provider attached + authentik_host set on embedded outpost (pk ${outpost_pk})"
  else
    warn "Could not update the embedded outpost - do it in the UI:"
    warn "  Outposts > 'authentik Embedded Outpost' > Edit > add provider 'arcane' AND"
    warn "  set authentik_host: https://authentik.${DOMAIN}"
    return 0
  fi

  # 6. Wait for the embedded outpost to come up.
  local healthy=false
  for i in $(seq 1 30); do
    if _ak_api "/outposts/instances/${outpost_pk}/health/" 2>/dev/null \
       | jq -e '.[0].version // empty' >/dev/null 2>/dev/null; then
      healthy=true; break
    fi
    printf "\r  ${C_DIM}Waiting for Authentik outpost... %d/30${C_R}" "$i" >&2
    sleep 3
  done; printf "\r" >&2
  $healthy && success "Authentik outpost healthy - Arcane forward-auth is live" \
            || warn "Outpost not healthy yet. It may still be starting - check: docker logs authentik-server"
}

enforce_authentik_mfa() {
  # Force TOTP MFA for ALL Authentik users (incl. akadmin) on next login by
  # flipping the default authentication flow's Authenticator Validation stage from
  # not_configured_action=skip (MFA optional) to =configure WITH the TOTP setup
  # stage attached -> users without a device are forced to enroll inline (no
  # lockout). Stage PKs are resolved by their stable slug. Fully fail-safe: any
  # failure leaves MFA OPTIONAL and warns, never a half-broken login flow.
  local vpk tpk got rec
  vpk=$(_ak_api "/stages/authenticator/validate/" 2>/dev/null | jq -r '.results[]? | select(.name=="default-authentication-mfa-validation") | .pk' 2>/dev/null | head -1)
  tpk=$(_ak_api "/stages/authenticator/totp/" 2>/dev/null | jq -r '.results[]? | select(.name=="default-authenticator-totp-setup") | .pk' 2>/dev/null | head -1)
  if [[ -z "$vpk" || -z "$tpk" ]]; then
    warn "Could not resolve Authentik MFA stages - MFA left OPTIONAL. Enforce later in the UI:"
    warn "  Flows & Stages > Stages > default-authentication-mfa-validation > 'Not configured action' = Configure + add the TOTP setup stage."
    return 0
  fi
  _ak_api "/stages/authenticator/validate/${vpk}/" -X PATCH \
    -d "$(jq -nc --arg t "$tpk" '{not_configured_action:"configure", configuration_stages:[$t]}')" >/dev/null 2>&1 || true
  got=$(_ak_api "/stages/authenticator/validate/${vpk}/" 2>/dev/null | jq -r '.not_configured_action // empty' 2>/dev/null)
  if [[ "$got" != "configure" ]]; then
    warn "Authentik MFA enforcement did not apply - MFA left OPTIONAL. Set it in the UI (see hint above)."
    return 0
  fi
  success "Authentik MFA ENFORCED - every user (incl. akadmin) must enroll TOTP on next login"
  # Lockout escape hatch: a one-time akadmin recovery URL (valid ~1y) in case the
  # TOTP device is ever lost. Saved mode-600 + surfaced in the final summary.
  rec=$(docker exec authentik-server ak create_recovery_key 1 akadmin 2>/dev/null | grep -oE '/recovery/use-token/[^ "]+' | head -1)
  if [[ -n "$rec" ]]; then
    printf 'https://authentik.%s%s\n' "$DOMAIN" "$rec" > "${AUTHENTIK_DIR}/.akadmin_recovery_url"
    chmod 600 "${AUTHENTIK_DIR}/.akadmin_recovery_url" 2>/dev/null || true
    info "akadmin recovery URL saved to ${AUTHENTIK_DIR}/.akadmin_recovery_url (use if the TOTP device is lost)"
  fi
  # authentik-worker has NO docker.sock mounted (embedded outpost needs no Docker
  # controller). Authentik's default blueprint still creates a "Local Docker
  # connection" service connection that then FAILS its health-check task every cycle
  # (noisy DockerException spam in the worker). Delete it so logs stay clean — the
  # embedded outpost (the forward-auth provider) is unaffected.
  local scpk
  for scpk in $(_ak_api "/outposts/service_connections/docker/" 2>/dev/null | jq -r '.results[]?.pk' 2>/dev/null); do
    _ak_api "/outposts/service_connections/docker/${scpk}/" -X DELETE >/dev/null 2>&1 || true
  done
}

setup_authentik_snippets() {
  step "Authentik NPM Snippets (forward-auth)"
  mkdir -p "$AUTHENTIK_SNIPPETS_DIR"

  # Authentik nginx forward-auth: the /outpost.goauthentik.io/ paths are served
  # by authentik-server (embedded outpost). The auth_request subrequest hits the
  # nginx auth endpoint; on 401 the browser is redirected to the outpost's start
  # URL, which bounces through Authentik login and back to the original URL.
  cat > "${AUTHENTIK_SNIPPETS_DIR}/authentik-location.conf" << 'SNIPPET'
location /outpost.goauthentik.io/ {
    proxy_pass http://authentik-server:9000/outpost.goauthentik.io/;
    proxy_set_header Host $host;
    proxy_set_header X-Original-URL $scheme://$http_host$request_uri;
    add_header Set-Cookie $auth_cookie;
    auth_request_set $auth_cookie $upstream_http_set_cookie;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
}
location = /outpost.goauthentik.io/auth/nginx {
    internal;
    proxy_pass http://authentik-server:9000/outpost.goauthentik.io/auth/nginx;
    proxy_set_header Host $host;
    proxy_set_header X-Original-URL $scheme://$http_host$request_uri;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
}
# Authentik 2024.x: the /auth/nginx 401 NO LONGER returns a Location header, so the
# old "error_page 401 =302 $upstream_http_location" produced a blank redirect (dead
# end). Build the redirect to the outpost start URL ourselves (rd = original request).
location @goauthentik_proxy_signin {
    internal;
    add_header Set-Cookie $auth_cookie;
    return 302 /outpost.goauthentik.io/start?rd=$request_uri;
    auth_request_set $auth_cookie $upstream_http_set_cookie;
}
SNIPPET

  cat > "${AUTHENTIK_SNIPPETS_DIR}/authentik-authrequest.conf" << 'SNIPPET'
auth_request /outpost.goauthentik.io/auth/nginx;
error_page 401 = @goauthentik_proxy_signin;
auth_request_set $auth_cookie $upstream_http_set_cookie;
add_header Set-Cookie $auth_cookie;
auth_request_set $authentik_username $upstream_http_x_authentik_username;
auth_request_set $authentik_groups   $upstream_http_x_authentik_groups;
auth_request_set $authentik_email    $upstream_http_x_authentik_email;
auth_request_set $authentik_name     $upstream_http_x_authentik_name;
proxy_set_header X-authentik-username $authentik_username;
proxy_set_header X-authentik-groups   $authentik_groups;
proxy_set_header X-authentik-email    $authentik_email;
proxy_set_header X-authentik-name     $authentik_name;
SNIPPET

  # Copy to NPM's custom config directory so they're accessible inside the container
  local npm_custom_dir="${NPM_DATA_DIR}/nginx/custom"
  mkdir -p "$npm_custom_dir"
  cp "${AUTHENTIK_SNIPPETS_DIR}/authentik-location.conf" "$npm_custom_dir/"
  cp "${AUTHENTIK_SNIPPETS_DIR}/authentik-authrequest.conf" "$npm_custom_dir/"
  success "Authentik NPM snippets created"
}

register_arcane_stacks() {
  step "Registering editable stacks in Arcane"
  info "Creating combined compose files in Arcane data directory..."

  # Combine all compose files into one for easy editing
  {
    echo "# Combined stack - NPM + Authentik + CrowdSec"
    echo "# Edit this file and run: docker compose -f ${STACK_DIR}/docker-compose.yml up -d"
    echo ""
    cat "${STACK_DIR}/docker-compose.npm.yml" 2>/dev/null || true
    echo ""
    # Extract the services from authentik compose (remove networks: section to avoid duplicates)
    sed '1,/^services:/b;/^networks:/,$d' "${STACK_DIR}/docker-compose.authentik.yml" 2>/dev/null || true
    echo ""
    sed '1,/^services:/b;/^networks:/,$d' "${STACK_DIR}/docker-compose.crowdsec.yml" 2>/dev/null || true
  } > "${ARCANE_DATA_DIR}/infrastructure.yml" 2>/dev/null || true

  # Also copy individual compose files for reference
  cp "${STACK_DIR}/docker-compose.npm.yml" "${ARCANE_DATA_DIR}/npm.yml" 2>/dev/null || true
  cp "${STACK_DIR}/docker-compose.authentik.yml" "${ARCANE_DATA_DIR}/authentik.yml" 2>/dev/null || true
  cp "${STACK_DIR}/docker-compose.crowdsec.yml" "${ARCANE_DATA_DIR}/crowdsec.yml" 2>/dev/null || true

  success "Compose files available in Arcane file browser: ${ARCANE_DATA_DIR}"
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

  # Issue/reuse ONE wildcard cert up front; every host below attaches this same cert.
  npm_ensure_wildcard_cert || true

  # Arcane: protected by Authentik forward-auth (nginx auth_request). Both
  # snippets are required: the location block (outpost proxy + auth subrequest)
  # AND the auth_request directives.
  #
  # The long proxy_*_timeout directives keep Arcane's container-terminal
  # WebSocket alive. The handshake succeeds (you see the shell banner), but
  # NPM's default proxy_read_timeout is 60s, so an interactive shell that sits
  # idle - or any long-running exec - gets killed: "Connection error.
  # Disconnected." 86400s (24h) keeps the terminal open. websocket upgrade
  # headers are already added by allow_websocket_upgrade:true on the host.
  local auth_snippet=$'proxy_read_timeout 86400s;\nproxy_send_timeout 86400s;\ninclude /data/nginx/custom/authentik-location.conf;\ninclude /data/nginx/custom/authentik-authrequest.conf;'
  local arcane_id=""
  arcane_id=$(npm_create_proxy_host "arcane.${DOMAIN}" "arcane" 3552 true "$auth_snippet") || true
  [[ -n "$arcane_id" && "${NPM_SKIP_SSL:-0}" != "1" ]] && npm_enable_ssl "$arcane_id" "arcane.${DOMAIN}" || true

  # Authentik admin portal
  local authentik_id=""
  authentik_id=$(npm_create_proxy_host "authentik.${DOMAIN}" "authentik-server" 9000 true "") || true
  [[ -n "$authentik_id" && "${NPM_SKIP_SSL:-0}" != "1" ]] && npm_enable_ssl "$authentik_id" "authentik.${DOMAIN}" || true

  # NPM admin panel at npm.<domain> with NPM's OWN login - DELIBERATELY no Authentik
  # forward-auth. NPM is the recovery/control plane (it owns all routing + certs), so
  # it must NOT depend on Authentik (a single point of failure): if Authentik ever
  # breaks you can still log into NPM and fix routing. Port 81 stays bound to
  # 127.0.0.1; this proxies to it internally (forward 127.0.0.1:81), so 81 never has
  # to be opened. Disable with EXPOSE_NPM_ADMIN=0 (then it's SSH-tunnel-only).
  if [[ "${EXPOSE_NPM_ADMIN:-1}" == "1" ]]; then
    local npm_id=""
    npm_id=$(npm_create_proxy_host "npm.${DOMAIN}" "127.0.0.1" 81 true "") || true
    [[ -n "$npm_id" && "${NPM_SKIP_SSL:-0}" != "1" ]] && npm_enable_ssl "$npm_id" "npm.${DOMAIN}" || true
    [[ -n "$npm_id" ]] && warn "NPM admin is now at https://npm.${DOMAIN} (NPM's own login). ENABLE NPM's built-in 2FA in the UI (Users > Edit > 2FA) — this login is internet-facing."
  fi

  [[ "${NPM_SKIP_SSL:-0}" == "1" ]] && info "NPM_SKIP_SSL=1 — proxy hosts left HTTP-only; enable SSL later in the NPM UI (or re-run without the flag once DNS resolves)."


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
  # UFW reset flushes iptables rules; Docker's rules (published ports) are
  # temporarily dropped. Restart Docker to rebuild its iptables chains.
  systemctl restart docker 2>/dev/null || true
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
        docker exec npm nginx -s reload 2>/dev/null || true
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

  # SSH + system log acquisition. CRITICAL: the sshd + linux collections are
  # useless without a log source. The old script acquired ONLY NPM web logs, so
  # SSH brute force and host attacks were INVISIBLE to CrowdSec. /var/log is
  # mounted into the container - point CrowdSec at auth.log/secure (sshd) and
  # syslog/messages (linux), parsed as syslog. (RHEL uses secure/messages.)
  local sys_acquis="${CROWDSEC_DIR}/config/acquis.d/syslog.yaml"
  cat > "$sys_acquis" << 'SYS_ACQUIS'
filenames:
  - /var/log/auth.log
  - /var/log/syslog
  - /var/log/secure
  - /var/log/messages
labels:
  type: syslog
SYS_ACQUIS
  if docker exec crowdsec cat /etc/crowdsec/acquis.d/syslog.yaml &>/dev/null; then
    success "SSH + system log acquisition configured (auth.log/syslog)"
  else
    docker exec -i crowdsec sh -c "mkdir -p /etc/crowdsec/acquis.d && cat > /etc/crowdsec/acquis.d/syslog.yaml" << 'EOF' || true
filenames:
  - /var/log/auth.log
  - /var/log/syslog
  - /var/log/secure
  - /var/log/messages
labels:
  type: syslog
EOF
    warn "SSH/system acquisition written (via docker exec)"
  fi
  # Ensure the log files exist NOW so CrowdSec begins tailing them on restart
  # (rsyslog only creates them on the first matching event; an absent file is not
  # watched until the next restart).
  touch /var/log/auth.log /var/log/syslog 2>/dev/null || true

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
      [[ $i -eq 5 ]] && { systemctl restart crowdsec-firewall-bouncer >>"$LOG_FILE" 2>&1 || warn "Mid-loop bouncer restart failed — continuing"; }
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
  local conf="${custom_dir}/http.conf"
  # NPM's default /etc/nginx/nginx.conf already defines real_ip_header X-Real-IP
  # and real_ip_recursive on inside the http{} block. Writing them again in
  # http.conf (included inside http{}) causes nginx: [emerg] "real_ip_header"
  # directive is duplicate -> nginx rejects config, port 81 RSTs connections.
  # Fix: write ONLY set_real_ip_from lines here (never duplicate), and patch
  # the main nginx.conf inside the container to swap X-Real-IP -> CF-Connecting-IP.
  {
    echo "# Managed by ${SCRIPT_NAME} - Cloudflare IP ranges"
    local cidr
    while IFS= read -r cidr; do
      [[ -n "$cidr" ]] && echo "set_real_ip_from ${cidr};"
    done < <(get_cloudflare_ips)
  } > "$conf"
  success "Wrote ${conf} ($(grep -c set_real_ip_from "$conf" 2>/dev/null || echo 0) CF ranges)"
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx npm; then
    # Patch NPM's built-in nginx.conf: swap X-Real-IP -> CF-Connecting-IP
    docker exec npm sed -i \
      's/real_ip_header X-Real-IP;/real_ip_header CF-Connecting-IP;/' \
      /etc/nginx/nginx.conf 2>/dev/null || true
    if docker exec npm nginx -t &>/dev/null && docker exec npm nginx -s reload &>/dev/null; then
      success "NPM reloaded with real-IP config (real_ip_header -> CF-Connecting-IP)"
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

  # When the worker can't run (no Analytics Engine, crash-loop, or no token), its
  # apt package is often left HALF-CONFIGURED (dpkg state 'iF') because the
  # postinst FATALs without AE. A half-configured package makes `apt-get` and
  # unattended-upgrades error out - so over a months-long unattended run, SECURITY
  # UPDATES SILENTLY STOP. This purges it to a clean dpkg state (the firewall
  # bouncer, the real enforcement, is a different package and is untouched). The
  # user can re-run the deploy after enabling AE to add edge enforcement.
  _worker_pkg_clean() {
    command -v dpkg >/dev/null 2>&1 || return 0
    dpkg-query -W crowdsec-cloudflare-worker-bouncer >/dev/null 2>&1 || return 0
    DEBIAN_FRONTEND=noninteractive dpkg --purge --force-all crowdsec-cloudflare-worker-bouncer </dev/null >>"$LOG_FILE" 2>&1 \
      || DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq -o DPkg::Lock::Timeout=300 crowdsec-cloudflare-worker-bouncer </dev/null >>"$LOG_FILE" 2>&1 || true
    info "Worker bouncer package removed to keep dpkg/apt clean for unattended updates (re-run deploy after enabling Analytics Engine to add it)."
  }

  # 1. Token: from env, else prompt. Blank = configure now, deploy later.
  if [[ -z "$CF_API_TOKEN" ]]; then
    printf "\n${C_B}Cloudflare Worker bouncer${C_R} blocks banned IPs at Cloudflare's edge.\n" >&2
    printf "It needs a Cloudflare ${C_B}User${C_R} API token (My Profile > API Tokens, NOT an\n" >&2
    printf "Account token). Supplying it now will deploy a Worker + KV to your account.\n" >&2
    printf "${C_B}Required perms${C_R} (CrowdSec's bouncer set PLUS DNS:Edit for auto-SSL -\n" >&2
    printf "do not drop any): Account(Workers KV Storage:Edit, Workers\n" >&2
    printf "  Scripts:Edit, Turnstile:Edit, Account Settings:Read, Account Analytics:Read),\n" >&2
    printf "  User(User Details:Read), Zone(${C_B}DNS:Edit${C_R}, Workers Routes:Edit, Zone:Read)\n" >&2
    printf "  ${C_B}NOTE:${C_R} Zone ${C_B}DNS:Edit${C_R} (not just DNS:Read) is REQUIRED - this same token\n" >&2
    printf "  lets NPM auto-issue SSL certs via Cloudflare DNS-01 (writes an ACME TXT\n" >&2
    printf "  record). With only DNS:Read, cert issuance fails with a Cloudflare 403.\n" >&2
    printf "${C_B}Minimize by SCOPE${C_R} (not by removing perms): under 'Account Resources'\n" >&2
    printf "  pick ${C_B}Include > <your account>${C_R} only, and under 'Zone Resources' pick\n" >&2
    printf "  ${C_B}Include > Specific zone > ${DOMAIN}${C_R} only - never 'All accounts/zones'.\n" >&2
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
  # Require BOTH the binary AND the systemd unit. A prior cleanup can purge the
  # package (removing the unit) while a leftover binary lingers on $PATH -> the old
  # `command -v` short-circuit skipped reinstall, then `systemctl enable` failed
  # with "Unit file ... does not exist". So if the unit is gone, fall through and
  # (re)install.
  local wb_unit_present=false
  { [[ -f /etc/systemd/system/crowdsec-cloudflare-worker-bouncer.service ]] \
    || [[ -f /lib/systemd/system/crowdsec-cloudflare-worker-bouncer.service ]] \
    || [[ -f /usr/lib/systemd/system/crowdsec-cloudflare-worker-bouncer.service ]]; } && wb_unit_present=true
  if command -v crowdsec-cloudflare-worker-bouncer &>/dev/null && $wb_unit_present; then
    have_bin=true
  elif [[ "$OS_FAMILY" == "debian" ]]; then
    info "Adding CrowdSec repository + installing the worker bouncer..."
    curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash >>"$LOG_FILE" 2>&1 || true
    # Stop the package postinst from AUTO-STARTING the service. On accounts without
    # Workers Analytics Engine the daemon FATALs immediately, and dpkg then prints a
    # "Job for ... failed" error + exits non-zero (console noise + a half-configured
    # package). A policy-rc.d returning 101 makes the postinst's service start a
    # clean no-op; WE start it, controlled + quietly, in step 5.
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d 2>/dev/null && chmod +x /usr/sbin/policy-rc.d 2>/dev/null || true
    # CRITICAL: the package ships its own conffile; our pre-created stub (above)
    # makes dpkg treat it as locally modified, so the postinst conffile handler
    # shows an interactive "(Y/I/N/O/D/Z)?" prompt. DEBIAN_FRONTEND=noninteractive
    # alone does NOT suppress conffile prompts -> the script HANGS forever with no
    # TTY to answer. Force-keep our version and never prompt.
    DEBIAN_FRONTEND=noninteractive timeout 300 apt-get install -y -qq \
      -o Dpkg::Lock::Timeout=300 \
      -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef \
      crowdsec-cloudflare-worker-bouncer </dev/null >>"$LOG_FILE" 2>&1 || true
    rm -f /usr/sbin/policy-rc.d 2>/dev/null || true
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
    # The worker-bouncer config validator FATALs on account_name chars outside
    # [A-Za-z0-9 ._-()&+@:,]. Cloudflare account names routinely contain an
    # apostrophe ("Bob's Account") -> the bouncer postinst crashes, which leaves
    # dpkg half-configured and makes EVERY later apt-get install exit 1 (silently
    # breaking AIDE etc. in harden.sh). Strip the disallowed chars here.
    account_name=$(printf '%s' "$account_name" | tr -cd 'A-Za-z0-9 ._()&+@:,-')
    if [[ -n "$zone_id" ]]; then
      success "Found Cloudflare zone for ${DOMAIN} (zone ${zone_id:0:8}...)"
    else
      warn "No Cloudflare zone found for ${DOMAIN} (check token scope / domain). Writing template; finish manually."
    fi
  fi

  # 4. Write the bouncer config (free-plan-safe). Heredoc is unquoted so the
  #    ${...} variables below are filled in at runtime.
  : "${CF_BOUNCER_KEY:=$(rand_password 48)}"
  # The worker-bouncer config validator FATALs ("turnstile must be enabled ... to
  # support captcha action") when actions=[captcha] but turnstile.enabled=false,
  # which would crash-loop the service. captcha REQUIRES Turnstile, so enable it
  # only for the captcha action. Reject any other value early.
  case "$CF_BOUNCER_ACTION" in
    ban|captcha) ;;
    *) warn "Invalid CF_BOUNCER_ACTION='${CF_BOUNCER_ACTION}' (expected ban|captcha); using 'ban'."; CF_BOUNCER_ACTION="ban" ;;
  esac
  local cf_turnstile="false"
  [[ "$CF_BOUNCER_ACTION" == "captcha" ]] && cf_turnstile="true"
  # Unique Cloudflare resource names per DOMAIN so multiple VPS under ONE Cloudflare
  # account never clobber each other's Worker/KV. The bouncer's defaults
  # (crowdsec-cloudflare-worker-bouncer / CROWDSECCFBOUNCERNS) are shared globals -
  # its own config comments say to change script_name / kv_namespace_name /
  # decisions_sync_script_name "when sharing a Cloudflare account with another
  # bouncer instance". Derive DNS-safe, deterministic names from the domain.
  local wsafe wsafe_up
  wsafe=$(printf '%s' "${DOMAIN:-crowdsec}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/-\{1,\}/-/g; s/^-//; s/-$//')
  [[ -n "$wsafe" ]] || wsafe="crowdsec"
  wsafe_up=$(printf '%s' "$wsafe" | tr 'a-z-' 'A-Z_')
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
            enabled: ${cf_turnstile}
            mode: managed
  worker:
    log_only: false
    # Per-domain names so two VPS on one CF account don't overwrite each other:
    script_name: crowdsec-${wsafe}
    kv_namespace_name: CROWDSEC_${wsafe_up}
    decisions_sync_script_name: crowdsec-sync-${wsafe}

log_level: info
log_media: stdout

prometheus:
  enabled: true
  listen_addr: 127.0.0.1
  listen_port: "2112"
CFWB
  chmod 600 "$cfg"
  success "Wrote ${cfg}"

  # 5. Deploy. The CF Worker bouncer HARD-REQUIRES Workers Analytics Engine, which
  #    Cloudflare only enables from the dashboard (no API). Most accounts have it
  #    OFF, so instead of enabling a service that would crash-loop and spew errors,
  #    we do ONE controlled foreground run: the bouncer itself is the authority on
  #    whether this account can deploy the Worker. AE off -> it FATALs in ~3s and we
  #    skip QUIETLY (edge enforcement is OPTIONAL; the host firewall bouncer already
  #    enforces every ban). AE on -> the run deploys the Worker and we enable the
  #    persistent service.
  if $have_bin && [[ -n "$zone_id" && -n "$account_id" ]]; then
    systemctl daemon-reload 2>/dev/null || true
    systemctl stop crowdsec-cloudflare-worker-bouncer 2>/dev/null || true
    local wbbin probe
    wbbin=$(command -v crowdsec-cloudflare-worker-bouncer 2>/dev/null || echo /usr/bin/crowdsec-cloudflare-worker-bouncer)
    # AE off -> exits fast; AE on -> deploys the Worker then keeps running until the
    # timeout stops it (exit 124, no fatal in output).
    probe=$(timeout 30 "$wbbin" -c "$cfg" 2>&1 || true)
    printf '%s\n' "$probe" >>"$LOG_FILE" 2>/dev/null || true
    if printf '%s' "$probe" | grep -qi 'Analytics Engine'; then
      info "Cloudflare Worker (edge) bouncer skipped - this Cloudflare account has Workers"
      info "  Analytics Engine disabled (a hard requirement of the worker bouncer; Cloudflare"
      info "  has no API to enable it). Host-level CrowdSec banning is ACTIVE and enforcing."
      info "  Want edge enforcement too? Enable it FREE: CF dashboard > Workers & Pages >"
      info "  Analytics Engine, then re-run this deploy with CF_API_TOKEN set."
      systemctl disable crowdsec-cloudflare-worker-bouncer 2>/dev/null || true
      _worker_pkg_clean
    elif printf '%s' "$probe" | grep -qiE 'level=fatal|panic:|unable to deploy'; then
      info "Cloudflare Worker (edge) bouncer skipped - deploy check did not succeed (details"
      info "  in ${LOG_FILE}). Host-level CrowdSec banning is ACTIVE and enforcing all bans."
      systemctl disable crowdsec-cloudflare-worker-bouncer 2>/dev/null || true
      _worker_pkg_clean
    else
      # Deploy check passed (Worker created) -> enable the persistent service.
      systemctl enable crowdsec-cloudflare-worker-bouncer >>"$LOG_FILE" 2>&1 || true
      systemctl restart crowdsec-cloudflare-worker-bouncer >>"$LOG_FILE" 2>&1 || true
      sleep 5
      if systemctl is-active --quiet crowdsec-cloudflare-worker-bouncer; then
        success "Cloudflare Worker bouncer ACTIVE - edge enforcement is live"
        warn "ACTION (no Cloudflare API for this): set the Worker Route to FAIL OPEN -> CF dashboard > ${DOMAIN} > Workers Routes > edit the crowdsec route > Request limit failure mode > Fail open. Without it a worker error shows visitors a CF 1027 page."
      else
        info "Cloudflare Worker bouncer installed but not active yet (see ${LOG_FILE}). Host-level CrowdSec banning is ACTIVE."
      fi
    fi
  else
    systemctl disable crowdsec-cloudflare-worker-bouncer 2>/dev/null || true
    _worker_pkg_clean
    info "Cloudflare Worker (edge) bouncer skipped (no token/zone supplied). The host firewall bouncer still enforces all bans."
    info "Add it later: enable Analytics Engine, then re-run the deploy with CF_API_TOKEN set."
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
    warn "CrowdSec LAPI not ready - Console enrollment skipped. Enroll later: docker exec crowdsec cscli console enroll <YOUR_ENROLL_KEY>"
    return 0
  fi

  # Console enrollment REQUIRES a per-account enroll key from https://app.crowdsec.net
  # (Security Engines > Enroll your instance). There is NO key-less auto-enroll -
  # the old `cscli console enroll --auto` (no key) ALWAYS failed, which is why
  # auto-enroll never worked; only the manual key flow does. Provide the key via
  # CROWDSEC_ENROLL_KEY to enroll automatically; otherwise print the manual steps.
  local enroll_key="${CROWDSEC_ENROLL_KEY:-}"
  if [[ -z "$enroll_key" ]]; then
    info "Console enrollment skipped (optional). To enroll your instance:"
    info "  1) https://app.crowdsec.net  >  Security Engines  >  Enroll your instance  (copy the key, starts 'cs...')"
    info "  2) docker exec crowdsec cscli console enroll <KEY>"
    info "  3) Back in the Console, click Accept to approve this engine."
    info "  (or re-run this deploy with CROWDSEC_ENROLL_KEY=<KEY> to do it automatically.)"
    return 0
  fi

  if docker exec crowdsec cscli console enroll "$enroll_key" &>/dev/null; then
    success "CrowdSec enrolled in Console - click Accept at https://app.crowdsec.net to approve it"
  else
    warn "Console enrollment failed (already enrolled, or bad/expired key). Check: docker logs crowdsec"
    warn "  Retry: docker exec crowdsec cscli console enroll <KEY>"
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

  # Containers. NOTE: must be an array - the global IFS=$'\n\t' has no space, so a
  # space-separated string would NOT word-split here (every check would run once
  # against the whole string and fail).
  local want=(npm arcane authentik-server authentik-worker authentik-postgres crowdsec)
  [[ "${INSTALL_CROWDSEC_WEBUI:-1}" == "1" ]] && want+=(crowdsec-web-ui)
  local c
  for c in "${want[@]}"; do
    _check "container '$c' running" bash -c "docker ps --format '{{.Names}}' | grep -qx '$c'"
  done

  # Core service health
  _check "IP forwarding ON (Docker)" bash -c '[[ $(sysctl -n net.ipv4.ip_forward) == 1 ]]'
  _check "NPM API responding"        curl -sf --max-time 5 http://127.0.0.1:81/api/
  _check "NPM default creds REJECTED (password was changed)" bash -c \
    "! curl -s --max-time 5 -X POST http://127.0.0.1:81/api/tokens -H 'Content-Type: application/json' -d '{\"identity\":\"admin@example.com\",\"secret\":\"changeme\"}' | grep -q token"
  _check "Authentik health endpoint OK" curl -sf --max-time 5 http://127.0.0.1:9000/-/health/ready/
  _check "nginx config valid inside NPM" docker exec npm nginx -t
  _check "Authentik snippets present in NPM custom dir" bash -c \
    "test -f '${NPM_DATA_DIR}/nginx/custom/authentik-location.conf' && test -f '${NPM_DATA_DIR}/nginx/custom/authentik-authrequest.conf'"

  _check "CrowdSec LAPI responding"   docker exec crowdsec cscli metrics
  _check "acquisition label is nginx-proxy-manager" bash -c \
    "docker exec crowdsec cat /etc/crowdsec/acquis.d/npm.yaml 2>/dev/null | grep -q 'type: nginx-proxy-manager'"
  _check "nginx-proxy-manager collection installed" bash -c \
    "docker exec crowdsec cscli collections list 2>/dev/null | grep -q crowdsecurity/nginx-proxy-manager"
  _check "bouncer registered in LAPI" bash -c \
    "docker exec crowdsec cscli bouncers list 2>/dev/null | grep -q npm-bouncer"
  _check "http-cve collection installed" bash -c \
    "docker exec crowdsec cscli collections list 2>/dev/null | grep -q crowdsecurity/http-cve"
  # http.conf holds ONLY set_real_ip_from lines; the CF-Connecting-IP swap is
  # patched into the container's /etc/nginx/nginx.conf (NOT http.conf). Check both
  # where they actually live, else this is a guaranteed false negative.
  _check "Cloudflare real-IP config present in NPM" bash -c \
    "test -f '${NPM_DATA_DIR}/nginx/custom/http.conf' && grep -q set_real_ip_from '${NPM_DATA_DIR}/nginx/custom/http.conf' && docker exec npm grep -q CF-Connecting-IP /etc/nginx/nginx.conf"
  _check "firewall bouncer service ACTIVE" systemctl is-active --quiet crowdsec-firewall-bouncer
  # Live end-to-end ban test: ban a TEST-NET IP, confirm it lands in the
  # firewall via the bouncer, then remove it. TEST-NET-1 (192.0.2.0/24) is
  # reserved (RFC 5737) and can never belong to a real client.
  if systemctl is-active --quiet crowdsec-firewall-bouncer; then
    info "Running live ban round-trip test (192.0.2.1, reserved test IP)..."
    docker exec crowdsec cscli decisions add --ip 192.0.2.1 --duration 2m --reason "deploy-verify" &>/dev/null || true
    # POLL, don't sleep-once: the bouncer pulls every 10s, and when it is also
    # syncing large community blocklists (tens of thousands of decisions) a single
    # fixed wait can land between pulls and falsely report "not enforced". Retry
    # up to ~36s.
    local banned=false _bi
    for _bi in $(seq 1 12); do
      if { command -v nft &>/dev/null && nft list ruleset 2>/dev/null | grep -q '192\.0\.2\.1'; } \
         || iptables -S 2>/dev/null | grep -q '192\.0\.2\.1' \
         || ipset list 2>/dev/null | grep -q '192\.0\.2\.1'; then banned=true; break; fi
      sleep 3
    done
    docker exec crowdsec cscli decisions delete --ip 192.0.2.1 &>/dev/null || true
    if $banned; then success "VERIFY: end-to-end ban enforcement works"
    else warn "VERIFY FAILED: test ban did not appear in firewall rules"; fails=$((fails+1)); fi
  fi

  # DETECTION (not just enforcement): the sshd/linux collections need a log source.
  _check "SSH/system log acquisition configured" bash -c \
    "docker exec crowdsec cat /etc/crowdsec/acquis.d/syslog.yaml 2>/dev/null | grep -q 'type: syslog'"
  _check "sshd collection installed" bash -c \
    "docker exec crowdsec cscli collections list 2>/dev/null | grep -q crowdsecurity/sshd"

  # Live DETECTION test: synthesize an SSH brute-force burst in auth.log and
  # confirm CrowdSec PARSES it into a decision. Proves acquisition -> parser ->
  # scenario, which the ban test above does NOT. Source is TEST-NET-2
  # (198.51.100.66, RFC 5737) so it can never be a real client.
  if [[ -f /var/log/auth.log ]]; then
    info "Running live SSH brute-force DETECTION test (198.51.100.66, reserved test IP)..."
    local _tip="198.51.100.66" _hn _k
    _hn=$(hostname -s 2>/dev/null || echo host)
    for _k in $(seq 1 12); do
      printf '%s %s sshd[%d]: Failed password for invalid user verifyuser from %s port %d ssh2\n' \
        "$(date '+%b %e %H:%M:%S')" "$_hn" "$((1000+_k))" "$_tip" "$((20000+_k))" >> /var/log/auth.log
    done
    local _seen=false _w
    for _w in $(seq 1 12); do
      if docker exec crowdsec cscli decisions list -o raw 2>/dev/null | grep -q "$_tip" \
         || docker exec crowdsec cscli alerts list -o raw 2>/dev/null | grep -q "$_tip"; then _seen=true; break; fi
      sleep 3
    done
    docker exec crowdsec cscli decisions delete --ip "$_tip" &>/dev/null || true
    if $_seen; then success "VERIFY: CrowdSec DETECTION works (ssh-bf parsed from auth.log -> decision)"
    else warn "VERIFY FAILED: synthetic ssh-bf not detected. Debug: docker exec crowdsec cscli metrics (check Acquisition + Scenarios)"; fails=$((fails+1)); fi
  else
    warn "VERIFY FAILED: /var/log/auth.log missing - SSH detection inactive. Is rsyslog running? (systemctl status rsyslog)"; fails=$((fails+1))
  fi

  if [[ $fails -eq 0 ]]; then
    success "All verification checks passed"
  else
    warn "${fails} verification check(s) failed - review warnings above and ${LOG_FILE}"
  fi
}

# -------------------------------------------------------------------------------
# Install the standalone health + security verifier onto the host so it can be
# re-run any time (this is the same set of checks, runnable on demand):
#   sudo bash /opt/apps/arcane-stack/verify-stack.sh
# -------------------------------------------------------------------------------
install_verify_script() {
  step "Installing verifier (verify-stack.sh)"
  # Persist the app name so the GENERIC verify-stack.sh knows which manager this
  # stack runs (dockhand/arcane/...). Derived from STACK_DIR (/opt/apps/<app>-stack).
  { _appname="$(basename "${STACK_DIR%-stack}")"; printf '%s' "$_appname" > /etc/vps-deploy-app; } 2>/dev/null || true
  cat > "${STACK_DIR}/verify-stack.sh" << 'VERIFY_EOF'
#!/usr/bin/env bash
# verify-stack.sh -- health + SECURITY audit for the Arcane + Authentik + NPM +
# CrowdSec stack. Installed by deploy-arcane-authentik.sh. Run as root:
#   sudo bash /opt/apps/arcane-stack/verify-stack.sh
# Read-only except self-cleaning CrowdSec ban + ssh-bf detection tests (reserved IPs).
set -uo pipefail
C_R='\033[0m'; C_B='\033[1m'; C_G='\033[0;32m'; C_Y='\033[0;33m'; C_RED='\033[0;31m'; C_C='\033[0;36m'
[[ -t 1 ]] || { C_R=; C_B=; C_G=; C_Y=; C_RED=; C_C=; }
P=0; W=0; F=0
pass(){ printf "${C_G}[PASS]${C_R} %s\n" "$*"; P=$((P+1)); }
warn(){ printf "${C_Y}[WARN]${C_R} %s\n" "$*"; W=$((W+1)); }
fail(){ printf "${C_RED}[FAIL]${C_R} %s\n" "$*"; F=$((F+1)); }
hdr(){  printf "\n${C_B}${C_C}== %s ==${C_R}\n" "$*"; }
[[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "docker not found"; exit 1; }
STACK_DIR="/opt/apps/arcane-stack"; AUTHENTIK_DIR="${STACK_DIR}/authentik"
DOMAIN="$(tr -d '\n' < /etc/vps-deploy-domain 2>/dev/null || true)"
printf "${C_B}Arcane stack health + security audit${C_R}  domain=${DOMAIN:-<unknown>}\n"
hdr "Containers"
for c in npm arcane authentik-server authentik-worker authentik-postgres crowdsec; do
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$c"; then pass "container $c running"; else fail "container $c NOT running"; fi
done
# CrowdSec Web UI is optional/removable: only check when its compose file exists.
if [[ -f "${STACK_DIR}/docker-compose.crowdsec-webui.yml" ]]; then
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx crowdsec-web-ui && pass "container crowdsec-web-ui running" || warn "container crowdsec-web-ui NOT running (removed? see README to reinstall)"
fi
hdr "Service health"
curl -sf --max-time 5 http://127.0.0.1:81/api/ >/dev/null 2>&1 && pass "NPM API up (:81)" || fail "NPM API down (:81)"
curl -sf --max-time 5 http://127.0.0.1:9000/-/health/ready/ >/dev/null 2>&1 && pass "Authentik health OK (:9000)" || fail "Authentik health FAIL"
docker exec npm nginx -t >/dev/null 2>&1 && pass "NPM nginx config valid" || fail "NPM nginx config INVALID"
docker exec crowdsec cscli lapi status >/dev/null 2>&1 && pass "CrowdSec LAPI responding" || fail "CrowdSec LAPI down"
[[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == "1" ]] && pass "IP forwarding on" || warn "IP forwarding off"
hdr "CrowdSec enforcement"
docker exec crowdsec cscli collections list 2>/dev/null | grep -q nginx-proxy-manager && pass "NPM collection installed" || warn "NPM collection missing"
docker exec crowdsec cscli bouncers list 2>/dev/null | grep -q npm-bouncer && pass "firewall bouncer registered" || warn "firewall bouncer not registered"
if systemctl is-active --quiet crowdsec-firewall-bouncer; then
  pass "firewall bouncer service active"
  docker exec crowdsec cscli decisions add --ip 192.0.2.1 --duration 2m --reason verify-stack >/dev/null 2>&1
  # POLL up to ~36s (bouncer pulls every 10s; heavier when syncing community blocklists)
  banned=no
  for _ in $(seq 1 12); do
    if { command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q '192\.0\.2\.1'; } \
       || iptables -S 2>/dev/null | grep -q '192\.0\.2\.1' \
       || ipset list 2>/dev/null | grep -q '192\.0\.2\.1'; then banned=yes; break; fi
    sleep 3
  done
  docker exec crowdsec cscli decisions delete --ip 192.0.2.1 >/dev/null 2>&1
  [[ $banned == yes ]] && pass "live ban enforced (round-trip OK)" || fail "live ban NOT enforced"
else fail "firewall bouncer service NOT active"; fi
if systemctl list-unit-files 2>/dev/null | grep crowdsec-cloudflare-worker-bouncer >/dev/null 2>&1; then
  if systemctl is-active --quiet crowdsec-cloudflare-worker-bouncer; then pass "CF worker bouncer active (edge)"
  else warn "CF worker bouncer installed but not active (enable Cloudflare Analytics Engine? journalctl -u crowdsec-cloudflare-worker-bouncer -n 40)"; fi
fi
hdr "CrowdSec detection (logs -> scenarios)"
docker exec crowdsec sh -c 'cat /etc/crowdsec/acquis.d/syslog.yaml 2>/dev/null' | grep -q 'type: syslog' && pass "SSH/system log acquisition configured" || fail "SSH/system acquisition MISSING - SSH/host attacks are INVISIBLE to CrowdSec"
docker exec crowdsec cscli collections list 2>/dev/null | grep -q crowdsecurity/sshd && pass "sshd collection installed" || warn "sshd collection missing"
[ -f /var/log/auth.log ] && pass "/var/log/auth.log present (rsyslog writing SSH logs)" || fail "/var/log/auth.log MISSING - SSH detection inactive (is rsyslog running?)"
if [ -f /var/log/auth.log ]; then
  tip="198.51.100.66"; hn="$(hostname -s 2>/dev/null || echo host)"
  for k in $(seq 1 12); do printf '%s %s sshd[%d]: Failed password for invalid user verifyuser from %s port %d ssh2\n' "$(date '+%b %e %H:%M:%S')" "$hn" "$((1000+k))" "$tip" "$((20000+k))" >> /var/log/auth.log; done
  seen=no; for w in $(seq 1 12); do docker exec crowdsec cscli decisions list -o raw 2>/dev/null | grep -q "$tip" && { seen=yes; break; }; docker exec crowdsec cscli alerts list -o raw 2>/dev/null | grep -q "$tip" && { seen=yes; break; }; sleep 3; done
  docker exec crowdsec cscli decisions delete --ip "$tip" >/dev/null 2>&1
  [ "$seen" = yes ] && pass "live ssh-bf DETECTION works (auth.log parsed -> decision)" || fail "synthetic ssh-bf NOT detected (docker exec crowdsec cscli metrics)"
fi
hdr "Security posture"
if curl -s --max-time 5 -X POST http://127.0.0.1:81/api/tokens -H 'Content-Type: application/json' -d '{"identity":"admin@example.com","secret":"changeme"}' 2>/dev/null | grep -q '"token"'; then
  fail "NPM DEFAULT password STILL ACTIVE (admin@example.com/changeme) -- change NOW at :81"; else pass "NPM default creds rejected"; fi
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then pass "UFW active"
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q running; then pass "firewalld active"
else fail "no active host firewall"; fi
binds="$(ss -tlnH 2>/dev/null | awk '{print $4}')"
echo "$binds" | grep -qE '0\.0\.0\.0:8080$|\[::\]:8080$|\*:8080$' && fail "CrowdSec LAPI :8080 EXPOSED on all interfaces" || pass "CrowdSec LAPI :8080 not world-listening"
echo "$binds" | grep -qE '0\.0\.0\.0:9000$|\[::\]:9000$|\*:9000$' && fail "Authentik :9000 EXPOSED on all interfaces" || pass "Authentik :9000 not world-listening"
echo "$binds" | grep -qE '0\.0\.0\.0:81$|\[::\]:81$|\*:81$' && warn "NPM admin :81 on all interfaces -- restrict to LAN/VPN" || pass "NPM admin :81 not world-open"
mnt="$(docker inspect -f '{{range .Mounts}}{{.Destination}}={{.RW}}{{"\n"}}{{end}}' arcane 2>/dev/null | grep '^/host=')"
if [ -n "$mnt" ]; then echo "$mnt" | grep -q '=false$' && pass "Arcane host fs READ-ONLY (/host:ro)" || fail "Arcane host fs READ-WRITE -- compromise = root on host"
else warn "Arcane /host mount not found"; fi
docker inspect -f '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' arcane 2>/dev/null | grep -q '/var/run/docker.sock' && warn "Arcane has docker.sock (root-equivalent, by design) -- the auth gate is your ONLY protection" || true
gate="$(docker exec npm sh -c "grep -lsi 'authentik' /data/nginx/proxy_host/*.conf 2>/dev/null | xargs -r grep -lsi 'arcane' 2>/dev/null" 2>/dev/null || true)"
[ -n "$gate" ] && pass "Authentik forward-auth gate present on arcane host" || fail "arcane host has NO Authentik gate -- root UI unprotected at edge"
for f in "${STACK_DIR}/.npm_admin_password" "${AUTHENTIK_DIR}/.akadmin_password" /etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml; do
  [ -f "$f" ] || continue; m="$(stat -c '%a' "$f" 2>/dev/null || echo '?')"
  [ "$m" = 600 ] && pass "perms 600 on $(basename "$f")" || warn "perms $m on $f (want 600)"; done
hdr "Summary"
printf "${C_G}PASS:%d${C_R}   ${C_Y}WARN:%d${C_R}   ${C_RED}FAIL:%d${C_R}\n" "$P" "$W" "$F"
if [ $F -gt 0 ]; then printf "${C_RED}${C_B}NOT fully secured -- resolve FAIL items.${C_R}\n"; exit 1
elif [ $W -gt 0 ]; then printf "${C_Y}${C_B}Functional, review WARNings.${C_R}\n"; exit 0
else printf "${C_G}${C_B}All checks passed.${C_R}\n"; exit 0; fi
VERIFY_EOF
  chmod 755 "${STACK_DIR}/verify-stack.sh"
  success "Verifier installed: ${STACK_DIR}/verify-stack.sh  (re-run: sudo bash ${STACK_DIR}/verify-stack.sh)"
}

# -------------------------------------------------------------------------------
# Final summary
# -------------------------------------------------------------------------------
print_summary() {
  local elapsed=$(( $(date +%s) - START_TIME ))
  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "YOUR_VPS_IP")
  local ext_ip; ext_ip=$(get_external_ip)
  local fw_cmd; [[ "$OS_FAMILY" == "debian" ]] && fw_cmd="ufw status verbose" || fw_cmd="firewall-cmd --list-all"
  local npm_password authentik_pass
  npm_password=$(_read_cred "${STACK_DIR}/.npm_admin_password")
  authentik_pass=$(_read_cred "${AUTHENTIK_DIR}/.akadmin_password")

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
arcane.${DOMAIN}  ->  arcane:3552   (Authentik 2FA enforced)
authentik.${DOMAIN} ->  authentik-server:9000

${C_B}Nginx Proxy Manager${C_R}
  Admin:   http://${ip}:81
  Login:   ${LETSENCRYPT_EMAIL:-admin@example.com}
  Password:${C_YEL} ${npm_password}${C_R}
  HTTP:    http://${ip}:80
  HTTPS:   https://${ip}:443
  Ext IP:  ${ext_ip}
  Data:    ${NPM_DATA_DIR}
  SSL:     ${NPM_LE_DIR}
  Logs:    ${NPM_LOGS_DIR}

${C_B}Arcane${C_R}
  URL:        https://arcane.${DOMAIN}
  Container:  arcane
  Network:    proxy
  Data:       ${ARCANE_DATA_DIR}
  Auth:       Authentik 2FA in front (forward-auth via embedded proxy outpost) + Arcane built-in SSO/MFA (setup wizard on first visit)
  Host Files: READ-ONLY mount under /host (see compose file comment to enable writes)

${C_B}Authentik${C_R}
  URL:        https://authentik.${DOMAIN}
  Admin:      akadmin / ${authentik_pass}  (change after first login)
  Containers: authentik-server, authentik-worker, authentik-postgres
  Network:    proxy
  Config:     ${AUTHENTIK_DIR}/authentik.env (mode 600)
  Data:       ${AUTHENTIK_DIR}/{media,templates,blueprints,certs,postgres}
  Bootstrap:  Proxy provider 'arcane' + embedded outpost created via admin API

${C_B}CrowdSec Console${C_R} (optional cloud dashboard)
  URL:      https://app.crowdsec.net/
  Enroll:   1) app.crowdsec.net > Security Engines > Enroll your instance (copy key)
            2) docker exec crowdsec cscli console enroll <KEY>
            3) click Accept in the Console to approve this engine
            (or re-run with CROWDSEC_ENROLL_KEY=<KEY> to enroll automatically)

${C_B}Cloudflare Worker bouncer${C_R}
  Role:     Blocks CrowdSec-banned IPs at Cloudflare's edge (before your VPS).
  Config:   /etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml
  Status:   $(systemctl is-active crowdsec-cloudflare-worker-bouncer 2>/dev/null || echo "not deployed (no token supplied)")
  Action:   $(echo "${CF_BOUNCER_ACTION}") on banned IPs   Plan-safe: only_include_decisions_from=[cscli,crowdsec]


${C_B}Firewall${C_R}  $(if [[ "$OS_FAMILY" == "debian" ]]; then echo "UFW"; else echo "firewalld"; fi)
${C_B}Docker${C_R}    $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo N/A)
${C_B}Containers${C_R}  npm, arcane, authentik-server/worker/postgres, crowdsec
${C_B}Network${C_R}   proxy (bridge)

${C_B}${C_YEL}Done automatically:${C_R}
  - Proxy hosts for Arcane / Authentik created
  - Let's Encrypt SSL certificates requested and forced (where DNS resolved)
  - NPM admin password changed to a random value (saved mode 600)
  - Authentik akadmin password randomized (saved mode 600)
  - CrowdSec Console enrolled (only if CROWDSEC_ENROLL_KEY was provided; else manual)
  - Authentik 2FA protecting Arcane (nginx forward-auth + embedded proxy outpost)
  - CrowdSec bans enforced incl. Docker-published ports (DOCKER-USER chain)
  - CrowdSec DETECTION wired for SSH + system logs (rsyslog + auth.log/syslog acquisition)
  - CrowdSec http-cve collection installed (CVE-exploit probing detection)
  - Cloudflare real visitor IPs restored in NPM (CF-Connecting-IP header)
  - Cloudflare Worker bouncer deployed for edge IP-ban enforcement (if token supplied)
  - Host filesystem mounted into Arcane READ-ONLY

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
  ${AUTHENTIK_DIR}/.akadmin_password

${C_B}Troubleshooting:${C_R}
  Verify:  sudo bash ${STACK_DIR}/verify-stack.sh   (re-runnable health + security audit)
  Logs:    docker logs -f npm    docker logs -f arcane    docker logs -f authentik-server
  Restart: docker compose -p npm -f ${STACK_DIR}/docker-compose.npm.yml restart   (per-stack project: -p npm|crowdsec|authentik|arcane)
  FW:      ${fw_cmd}
  CrowdSec: docker exec crowdsec cscli metrics   docker exec crowdsec cscli alerts list
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

# -------------------------------------------------------------------------------
# CrowdSec Web UI (TheDuffman85/crowdsec-web-ui) — installed BY DEFAULT.
# Dashboard for the CrowdSec LAPI: view/manage decisions (bans), alerts, metrics.
# It authenticates to the LAPI as a registered MACHINE (watcher) — not a bouncer —
# over the shared `proxy` network (crowdsec:8080). No published host ports; it is
# reached through NPM at crowdsec.<domain>.
#
# CLEAN REMOVAL (nothing else depends on it):
#   docker compose -p crowdsec-webui -f <STACK_DIR>/docker-compose.crowdsec-webui.yml down
#   docker exec crowdsec cscli machines delete crowdsec-web-ui
#   rm -rf <STACK_DIR>/crowdsec-webui <STACK_DIR>/docker-compose.crowdsec-webui.yml
#   ...then delete the crowdsec.<domain> proxy host in the NPM UI. Done.
# Skip the install entirely with INSTALL_CROWDSEC_WEBUI=0.
# -------------------------------------------------------------------------------
setup_crowdsec_webui() {
  step "CrowdSec Web UI (dashboard)"
  if [[ "${INSTALL_CROWDSEC_WEBUI:-1}" != "1" ]]; then
    info "INSTALL_CROWDSEC_WEBUI=0 — skipping CrowdSec Web UI"
    return 0
  fi
  if ! docker ps --format '{{.Names}}' | grep -qx "crowdsec"; then
    warn "CrowdSec container not running — skipping Web UI (re-run the deploy, or install manually later)"
    return 0
  fi
  local ui_dir="${STACK_DIR}/crowdsec-webui"
  mkdir -p "${ui_dir}/data"

  # Register the UI as a LAPI *machine* (watcher) — NOT a bouncer key. A fresh
  # password is generated on every deploy; -f /dev/null stops cscli from
  # overwriting the agent's own credentials file inside the container.
  local ui_pass
  ui_pass=$(rand_password 32)
  docker exec crowdsec cscli machines delete crowdsec-web-ui &>/dev/null || true
  if ! docker exec crowdsec cscli machines add crowdsec-web-ui --password "${ui_pass}" -f /dev/null &>/dev/null; then
    warn "Could not register the Web UI machine with the CrowdSec LAPI — skipping."
    warn "  Manual fix: docker exec crowdsec cscli machines add crowdsec-web-ui --password '<pw>' -f /dev/null"
    warn "  then put that password in ${ui_dir}/webui.env and re-run: docker compose -p crowdsec-webui -f ${STACK_DIR}/docker-compose.crowdsec-webui.yml up -d"
    return 0
  fi

  # AUTH_ENABLED=true = the UI's own login (created on your FIRST visit — do it
  # before an attacker does). Set to false ONLY if the proxy host is gated by the
  # identity provider and you accept single-layer auth.
  cat > "${ui_dir}/webui.env" << WEBUI_ENV
CROWDSEC_URL=http://crowdsec:8080
CROWDSEC_USER=crowdsec-web-ui
CROWDSEC_PASSWORD=${ui_pass}
CROWDSEC_PROMETHEUS_URL=http://crowdsec:6060/metrics
AUTH_ENABLED=true
DB_DIR=/app/data
WEBUI_ENV
  chmod 600 "${ui_dir}/webui.env"

  cat > "${STACK_DIR}/docker-compose.crowdsec-webui.yml" << 'COMPOSE_WEBUI'
services:
  crowdsec-web-ui:
    image: ghcr.io/theduffman85/crowdsec-web-ui:latest
    container_name: crowdsec-web-ui
    hostname: crowdsec-web-ui
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    env_file:
      - ./crowdsec-webui/webui.env
    volumes:
      - ./crowdsec-webui/data:/app/data
    networks:
      - proxy
networks:
  proxy:
    external: true
COMPOSE_WEBUI

  info "Pulling CrowdSec Web UI image..."
  docker compose -p crowdsec-webui -f "${STACK_DIR}/docker-compose.crowdsec-webui.yml" pull >>"${LOG_FILE}" 2>&1 || true
  if ! docker compose -p crowdsec-webui -f "${STACK_DIR}/docker-compose.crowdsec-webui.yml" up -d >>"${LOG_FILE}" 2>&1; then
    warn "CrowdSec Web UI failed to start — check: docker logs crowdsec-web-ui"
    return 0
  fi
  local i
  for i in $(seq 1 15); do
    docker ps --format '{{.Names}}' | grep -qx "crowdsec-web-ui" && break
    sleep 2
  done
  if docker ps --format '{{.Names}}' | grep -qx "crowdsec-web-ui"; then
    success "CrowdSec Web UI running (crowdsec-web-ui:3000 on the proxy network)"
  else
    warn "CrowdSec Web UI container not up yet — check: docker logs crowdsec-web-ui"
  fi

  # Proxy host crowdsec.<domain>. Needs the NPM token from automate_npm. When the
  # Authelia snippets exist they gate the host (the *.<domain> wildcard policy
  # covers every subdomain automatically); on Authentik stacks the host relies on
  # the UI's own login instead — gate it behind Authentik later like any other
  # app (provider + application + the two authentik include lines) if you want.
  if [[ -n "${NPM_TOKEN:-}" ]]; then
    local ui_snippet=""
    if [[ -f "${NPM_DATA_DIR}/nginx/custom/authelia-authrequest.conf" ]]; then
      ui_snippet=$'include /data/nginx/custom/authelia-location.conf;\ninclude /data/nginx/custom/authelia-authrequest.conf;'
    fi
    local ui_id=""
    ui_id=$(npm_create_proxy_host "crowdsec.${DOMAIN}" "crowdsec-web-ui" 3000 true "$ui_snippet") || true
    [[ -n "$ui_id" && "${NPM_SKIP_SSL:-0}" != "1" ]] && npm_enable_ssl "$ui_id" "crowdsec.${DOMAIN}" || true
    [[ -n "$ui_id" ]] && info "CrowdSec dashboard: crowdsec.${DOMAIN} — FIRST VISIT creates the UI admin account, do it now"
  else
    info "NPM automation unavailable — add the proxy host manually: crowdsec.${DOMAIN} -> crowdsec-web-ui:3000 (scheme http)"
  fi
  return 0
}

main() {
  printf "\n${C_B}${C_CYN}VPS Deployment -- Docker + NPM + Arcane + Authentik + CrowdSec${C_R}\n" >&2
  printf "${C_DIM}${SCRIPT_NAME} v${SCRIPT_VERSION}${C_R}\n\n" >&2
  preflight_checks
  idempotent_cleanup
  system_update
  install_dependencies
  install_docker
  ensure_ip_forwarding
  setup_docker_network
  get_user_domain
  get_letsencrypt_email   # MUST run on both new-domain AND domain-reuse paths;
                          # keep it here (not inside get_user_domain, whose reuse
                          # branch returns early) so LETSENCRYPT_EMAIL is always set
                          # before NPM admin creation + cert issuance.
  setup_arcane
  setup_stack
  setup_firewall
  setup_crowdsec
  setup_cloudflare_realip
  setup_cloudflare_bouncer
  setup_crowdsec_console
  setup_logrotate
  automate_npm
  setup_crowdsec_webui
  register_arcane_stacks
  install_verify_script
  verify_deployment
  DEPLOY_STATUS="success"
  print_summary
}

main "$@"
