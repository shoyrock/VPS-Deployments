#!/usr/bin/env bash
# Auto-elevate to root if not already running as root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi

# deploy-netbird.sh -- Docker + Traefik edge + Authentik (IdP)
#                      + NetBird (self-hosted control plane + reverse proxy) + Dockhand
#                      + CrowdSec.
#
# This is the deploy-dockhand.sh stack with the proxy/auth layer swapped:
#     NPM        -> Traefik (single TLS edge on 80/443, Let's Encrypt)
#     Authelia   -> Authentik (IdP, exposed via NetBird reverse proxy)
#     (added)    -> NetBird self-hosted COMBINED server (netbirdio/netbird-server:
#                   mgmt+signal+relay+STUN) + dashboard, behind the Traefik edge,
#                   using NetBird's OWN EMBEDDED IdP (at /oauth2). Admin user is
#                   auto-created via the setup API. Config + Traefik labels are
#                   taken verbatim from NetBird's official installer.
#     (added)    -> netbird-proxy (netbirdio/reverse-proxy): the app ingress engine.
#                   Traefik passes ALL unmatched HTTPS through TLS passthrough to
#                   this container; it terminates per-service TLS (ACME) and forwards
#                   to targets via Direct Upstream (same-host Docker containers).
#
# Topology: one Traefik (ours, named to match NetBird's labels) owns 80/443:
#     netbird.<domain>             -> netbird-server (gRPC h2c) + dashboard (Traefik direct)
#     *.<domain>                   -> netbird-proxy (TLS passthrough; per-service ACME)
#         dockhand.<domain>            -> dockhand:3000
#         authentik.<domain>           -> authentik-server:9000
#   NetBird STUN stays host-published: 3478/udp. Relay rides Traefik on /relay.
#   Reverse proxy services are auto-created via the NetBird management REST API.
#
# One-click VPS deployment. Usage: sudo ./deploy-netbird.sh
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

readonly SCRIPT_VERSION="4.7.1-netbird-proxy"
readonly SCRIPT_NAME="deploy-netbird.sh"
START_TIME=$(date +%s); readonly START_TIME
readonly STACK_DIR="/opt/netbird-stack"
readonly CROWDSEC_DIR="${STACK_DIR}/crowdsec"
readonly DOCKHAND_DATA_DIR="${STACK_DIR}/dockhand-data"
# Traefik edge (single TLS terminator on 80/443)
readonly TRAEFIK_DIR="${STACK_DIR}/traefik"
readonly TRAEFIK_DYNAMIC_DIR="${TRAEFIK_DIR}/dynamic"
readonly TRAEFIK_LE_DIR="${TRAEFIK_DIR}/letsencrypt"
readonly TRAEFIK_LOG_DIR="${TRAEFIK_DIR}/logs"
# Authentik (IdP, exposed via NetBird reverse proxy)
readonly AUTHENTIK_DIR="${STACK_DIR}/authentik"
readonly AUTHENTIK_MEDIA_DIR="${AUTHENTIK_DIR}/media"
readonly AUTHENTIK_TEMPLATES_DIR="${AUTHENTIK_DIR}/templates"
readonly AUTHENTIK_BLUEPRINTS_DIR="${AUTHENTIK_DIR}/blueprints"
readonly AUTHENTIK_CERTS_DIR="${AUTHENTIK_DIR}/certs"
# NetBird self-hosted control plane
readonly NETBIRD_DIR="${STACK_DIR}/netbird"
readonly NETBIRD_MGMT_DIR="${NETBIRD_DIR}/management"
readonly NETBIRD_SIGNAL_DIR="${NETBIRD_DIR}/signal"
readonly DOMAIN_PERSIST_FILE="/etc/vps-deploy-domain"
readonly LOG_FILE="/var/log/vps-deploy.log"
# 'proxy' network: fixed subnet so Traefik gets a known IP. The NetBird reverse
# proxy trusts PROXY-protocol headers only from this IP (NB_PROXY_TRUSTED_PROXIES).
# Values match NetBird's official getting-started.sh (v0.72).
readonly PROXY_NET_SUBNET="172.30.0.0/24"
readonly PROXY_NET_GATEWAY="172.30.0.1"
readonly TRAEFIK_STATIC_IP="172.30.0.10"

# --- Authentik / NetBird OIDC client identifiers (constant; secrets generated) ---
readonly OIDC_NETBIRD_CLIENT_ID="netbird"          # Authentik app slug + client id
readonly OIDC_NETBIRD_AUDIENCE="netbird"           # JWT audience NetBird validates
AUTHENTIK_BOOTSTRAP_TOKEN=""                       # generated; admin API token for Authentik API
AUTHENTIK_BOOTSTRAP_PASSWORD=""                    # generated; akadmin initial password
NETBIRD_OIDC_CLIENT_SECRET=""                      # read back from Authentik after bootstrap
NETBIRD_DATAREPLICA_SECRET=""                      # relay/turn shared secret (generated)
NB_PROXY_TOKEN=""                                  # netbird-server-issued token for netbird-proxy
NB_PROXY_CROWDSEC_KEY=""                            # crowdsec bouncer key for netbird-proxy
NB_PAT=""                                           # Personal Access Token from setup API (REST API auth)
NB_ADMIN_EMAIL=""                                   # NetBird admin email (created via setup API)
NB_ADMIN_PASSWORD=""                                # NetBird admin password (randomly generated)

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
  local ak_pass nb_pass
  ak_pass=$(_read_cred "${AUTHENTIK_DIR}/.akadmin_password")
  nb_pass=$(_read_cred "${NETBIRD_DIR}/.admin_password")

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
  if [[ "$DEPLOY_STATUS" == "success" ]]; then
    printf "${C_B}  NetBird (control plane): https://netbird.%s${C_R}\n" "$DOMAIN"
    printf "${C_B}  Authentik:      https://authentik.%s${C_R}\n" "$DOMAIN"
    printf "${C_B}  Dockhand:       https://dockhand.%s${C_R}\n" "$DOMAIN"
    printf "${C_B}  NetBird:        https://netbird.%s${C_R}\n" "$DOMAIN"
    printf "${C_B}------------------------------------------------------------------------------${C_R}\n"
    printf "${C_B}${C_YEL}  Containers on the proxy network:${C_R}\n"
    printf "${C_B}    traefik              ->  ports 80, 443 (TLS edge; passes apps to netbird-proxy)${C_R}\n"
    printf "${C_B}    authentik-server     ->  port 9000 (IdP; exposed via netbird-proxy)${C_R}\n"
    printf "${C_B}    netbird-server       ->  combined mgmt/signal/relay + gRPC (NetBird labels)${C_R}\n"
    printf "${C_B}    netbird-dashboard    ->  port 80 (UI behind Traefik)${C_R}\n"
    printf "${C_B}    netbird-proxy        ->  reverse-proxy engine (TLS passthrough, 8443 + 51820/udp)${C_R}\n"
    printf "${C_B}    dockhand             ->  port 3000 (exposed via Traefik)${C_R}\n"
    printf "${C_B}    crowdsec             ->  port 8080 (LAPI, localhost only)${C_R}\n"
    printf "${C_B}------------------------------------------------------------------------------${C_R}\n"
    printf "${C_B}  ${C_YEL}Authentik admin user: akadmin${C_R}\n"
    printf "${C_B}  ${C_YEL}Authentik password:   %s${C_R}\n" "$ak_pass"
    printf "${C_B}  ${C_RED}Change this password after first login!${C_R}\n"
    printf "\n"
    printf "${C_B}  ${C_YEL}NetBird admin user:   %s${C_R}\n" "${NB_ADMIN_EMAIL:-admin@${DOMAIN}}"
    printf "${C_B}  ${C_YEL}NetBird password:     %s${C_R}\n" "$nb_pass"
    printf "${C_B}  ${C_RED}Change this password after first login!${C_R}\n"
    printf "\n"
    printf "${C_B}  All credentials are stored (mode 600) under: %s${C_R}\n" "$STACK_DIR"
    printf "\n"
    printf "${C_B}  NetBird reverse proxy is ready for future remote services.${C_R}\n"
    printf "${C_B}  To expose a service on another machine: install NetBird client there,${C_R}\n"
    printf "${C_B}  then add it via dashboard -> Reverse Proxy -> Services.${C_R}\n"
    printf "${C_B}  netbird.%s stays on Traefik directly (proxy control plane + dashboard).${C_R}\n" "$DOMAIN"
    printf "${C_B}  DNS: point *.%s -> %s for reverse proxy TLS to issue.${C_R}\n" "$DOMAIN" "$ext_ip"
  fi
  printf "${C_B}  Ports: 80 (HTTP), 443 (HTTPS); NetBird STUN: 3478/udp; proxy WireGuard: 51820/udp${C_R}\n"
  printf "${C_B}  Log: %s${C_R}\n" "$LOG_FILE"
  printf "${C_B}==============================================================================${C_R}\n\n"
  if [[ "$DEPLOY_STATUS" == "success" ]]; then
    printf "${C_B}${C_GRN}Your VPS is ready!${C_R} DNS: ${C_CYN}netbird.%s -> %s${C_R} and ${C_CYN}*.%s -> %s${C_R}\n\n" "$DOMAIN" "$ext_ip" "$DOMAIN" "$ext_ip"
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
    # --force-confold + </dev/null: a half-configured CF bouncer leaves a conffile
    # conflict; without these, 'dpkg --configure -a' itself prompts and HANGS,
    # holding the dpkg lock (the failure mode this whole stack just hit).
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confold </dev/null 2>/dev/null || true
    # Belt-and-suspenders: if the stub-config trick didn't unstick it (postinst
    # still failing on service start, etc.), yank the package directly with
    # dpkg --force-remove-reinstreq --force-all, which bypasses the apt layer
    # that would re-trigger the failing postinst. Then let apt retry below.
    if dpkg-query -W -f='${db:Status-Abbrev}' crowdsec-cloudflare-worker-bouncer 2>/dev/null | grep -qE '[FHU]'; then
      DEBIAN_FRONTEND=noninteractive dpkg --purge --force-remove-reinstreq --force-all crowdsec-cloudflare-worker-bouncer </dev/null 2>/dev/null || true
    fi
    DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confold crowdsec crowdsec-firewall-bouncer-nftables crowdsec-firewall-bouncer-iptables crowdsec-cloudflare-worker-bouncer </dev/null 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get install -f -y -qq -o DPkg::Lock::Timeout=300 </dev/null 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y -qq -o DPkg::Lock::Timeout=300 </dev/null 2>/dev/null || true
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
    # Guard: repair dpkg if cleanup left a half-configured package behind.
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confold </dev/null 2>/dev/null || true
    apt-get update -qq -o DPkg::Lock::Timeout=300 && apt-get upgrade -y -qq -o DPkg::Lock::Timeout=300 && apt-get autoremove -y -qq -o DPkg::Lock::Timeout=300 && apt-get autoclean -qq
  else
    if command -v dnf &>/dev/null; then dnf update -y -q && dnf autoremove -y -q 2>/dev/null || true
    else yum update -y -q; fi
  fi
  success "System updated"
}

install_dependencies() {
  step "Dependencies"
  export DEBIAN_FRONTEND=noninteractive
  info "Installing required packages - please wait..."
  if [[ "$OS_FAMILY" == "debian" ]]; then
    # Guard: repair dpkg if cleanup left a half-configured package behind.
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confold </dev/null 2>/dev/null || true
    # Lock::Timeout=300: wait out apt-daily/unattended-upgrades on a fresh boot
    # instead of instantly failing (this single apt-get would otherwise trip set -e).
    apt-get install -y -qq -o DPkg::Lock::Timeout=300 ca-certificates curl gnupg lsb-release \
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
  # Needs a FIXED subnet so Traefik can take TRAEFIK_STATIC_IP (the NetBird proxy
  # trusts PROXY-protocol only from that IP). If 'proxy' exists with a different
  # subnet, recreate it (safe: idempotent_cleanup already removed all containers).
  if docker network ls --format '{{.Name}}' | grep -qx "proxy"; then
    local cur_subnet
    cur_subnet=$(docker network inspect proxy --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true)
    if [[ "$cur_subnet" != "$PROXY_NET_SUBNET" ]]; then
      warn "'proxy' network has subnet '${cur_subnet:-none}'; recreating as ${PROXY_NET_SUBNET}"
      docker network rm proxy >/dev/null 2>&1 || warn "Could not remove old 'proxy' network (containers attached?); Traefik static IP may fail."
    fi
  fi
  if ! docker network ls --format '{{.Name}}' | grep -qx "proxy"; then
    # No subnet-less fallback: Traefik pins TRAEFIK_STATIC_IP, which REQUIRES this
    # subnet. A subnet-less 'proxy' would make Traefik fail later with a cryptic
    # error, so fail here with a clear message instead.
    docker network create --subnet "$PROXY_NET_SUBNET" --gateway "$PROXY_NET_GATEWAY" proxy 2>/dev/null \
      || fatal "Could not create 'proxy' network on ${PROXY_NET_SUBNET} (subnet may collide with an existing route/network). Free that range or edit PROXY_NET_SUBNET/GATEWAY/TRAEFIK_STATIC_IP at the top of this script, then re-run."
  fi
  docker network ls --format '{{.Name}}' | grep -qx "proxy" || fatal "Failed to create 'proxy' network"
  success "Network 'proxy' ready (${PROXY_NET_SUBNET})"
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

setup_dockhand() {
  step "Dockhand (standalone)"
  mkdir -p "${DOCKHAND_DATA_DIR}"

  # SECURITY: the host filesystem is mounted READ-ONLY (/:/host:ro).
  # The docker.sock mount is root-equivalent by nature (required for a Docker
  # manager). Dockhand has NO direct ingress (traefik.enable=false); it is reached
  # only via the NetBird reverse proxy, so set auth (SSO/password/PIN) ON the
  # NetBird proxy service that exposes it. The :ro mount removes the easiest abuse
  # path. To allow host writes from the Dockhand UI, change "/:/host:ro" to
  # "/:/host" and re-run:
  #   docker compose -f ${STACK_DIR}/docker-compose.dockhand.yml up -d --force-recreate
  cat > "${STACK_DIR}/docker-compose.dockhand.yml" << COMPOSE_DOCKHAND
services:
  dockhand:
    image: fnsys/dockhand:latest
    container_name: dockhand
    hostname: dockhand
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./dockhand-data:/app/data
      - /:/host:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.dockhand.rule=Host(\`dockhand.${DOMAIN}\`)"
      - "traefik.http.routers.dockhand.entrypoints=websecure"
      - "traefik.http.routers.dockhand.tls.certresolver=letsencrypt"
      - "traefik.http.services.dockhand.loadbalancer.server.port=3000"
    networks:
      - proxy
networks:
  proxy:
    external: true
COMPOSE_DOCKHAND

  info "Pulling Dockhand image..."
  docker compose -f "${STACK_DIR}/docker-compose.dockhand.yml" pull
  docker compose -f "${STACK_DIR}/docker-compose.dockhand.yml" up -d --force-recreate

  info "Waiting for Dockhand to be ready..."
  for i in $(seq 1 30); do
    printf "\r  ${C_DIM}Waiting for Dockhand... %d/30${C_R}" "$i" >&2
    sleep 2
    if docker ps --format '{{.Names}}' | grep -qx "dockhand"; then
        printf "\r" >&2
        success "Dockhand ready"
        break
    fi
    [[ $i -eq 30 ]] && { printf "\r" >&2; warn "Dockhand may still be starting. Check: docker logs dockhand"; }
  done
  printf "\r" >&2
}

setup_stack() {
  step "Deploying Traefik edge, Authentik (IdP), NetBird and CrowdSec"
  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<VPS_IP>")
  # Shared key: CrowdSec pre-registers it as a bouncer (BOUNCER_KEY_* env in the
  # crowdsec compose), and setup_cloudflare_bouncer writes the SAME key into the
  # CF bouncer config.
  CF_BOUNCER_KEY=$(rand_password 48)
  # Per-deploy secrets for the new stack.
  AUTHENTIK_BOOTSTRAP_TOKEN=$(rand_password 48)       # akadmin API token
  AUTHENTIK_BOOTSTRAP_PASSWORD=$(rand_password 24)    # akadmin initial UI password
  NETBIRD_DATAREPLICA_SECRET=$(rand_secret)           # NetBird relay authSecret (config.yaml)
  NB_PROXY_CROWDSEC_KEY=$(rand_password 48)            # crowdsec bouncer key for netbird-proxy

  mkdir -p "$TRAEFIK_DIR" "$TRAEFIK_DYNAMIC_DIR" "$TRAEFIK_LE_DIR" "$TRAEFIK_LOG_DIR" \
           "$AUTHENTIK_DIR" "$AUTHENTIK_MEDIA_DIR" "$AUTHENTIK_TEMPLATES_DIR" \
           "$AUTHENTIK_BLUEPRINTS_DIR" "$AUTHENTIK_CERTS_DIR" \
           "$NETBIRD_DIR" "$NETBIRD_MGMT_DIR" "$NETBIRD_SIGNAL_DIR" "$CROWDSEC_DIR"
  # acme.json must be 0600 or Traefik refuses to use it.
  touch "${TRAEFIK_LE_DIR}/acme.json" && chmod 600 "${TRAEFIK_LE_DIR}/acme.json"

  local le_email="admin@${DOMAIN}"
  gen_traefik_files "$le_email"
  gen_authentik_files
  gen_netbird_files "$ip"
  gen_crowdsec_compose
  gen_netbird_proxy_files

  # --- Traefik edge (owns 80/443) ------------------------------------------
  info "Pulling + starting Traefik edge (80/443, Let's Encrypt)..."
  docker compose -f "${STACK_DIR}/docker-compose.traefik.yml" pull || true
  docker compose -f "${STACK_DIR}/docker-compose.traefik.yml" up -d
  for i in $(seq 1 30); do
    if ss -tlnp 2>/dev/null | grep -qE ':80[[:space:]]' && ss -tlnp 2>/dev/null | grep -qE ':443[[:space:]]'; then
      success "Traefik bound 80 + 443"; break
    fi
    [[ $i -eq 30 ]] && { ss -tlnp 2>/dev/null | grep -E ':80 |:443 ' >&2 || true; fatal "Traefik failed to bind 80/443. Check: docker logs traefik"; }
    printf "\r  ${C_DIM}Waiting for Traefik ports... %d/30${C_R}" "$i" >&2; sleep 2
  done; printf "\r" >&2

  # --- Authentik (IdP, exposed via NetBird reverse proxy) -------------------
  info "Pulling + starting Authentik (postgres + redis + server + worker)..."
  docker compose -f "${STACK_DIR}/docker-compose.authentik.yml" pull || true
  docker compose -f "${STACK_DIR}/docker-compose.authentik.yml" up -d
  info "Waiting for Authentik server (first boot runs migrations — up to ~3 min)..."
  # Probe from the HOST against the published API port (127.0.0.1:9000). The old
  # check ran 'docker exec authentik-server curl ...', but the goauthentik image
  # ships NO curl -> the exec always failed and the wait ran its full timeout even
  # when Authentik was healthy. Fall back to the container's own healthcheck status.
  local ak_ok=false
  for i in $(seq 1 75); do
    if curl -sf --max-time 5 -o /dev/null http://127.0.0.1:9000/-/health/ready/ 2>/dev/null \
       || [[ "$(docker inspect -f '{{.State.Health.Status}}' authentik-server 2>/dev/null)" == "healthy" ]]; then
      ak_ok=true; break
    fi
    printf "\r  ${C_DIM}Waiting for Authentik... %d/75${C_R}" "$i" >&2; sleep 4
  done; printf "\r" >&2
  $ak_ok && success "Authentik ready" || warn "Authentik not healthy yet. Check: docker logs authentik-server"

  # Apply the Authentik health check before NetBird.
  bootstrap_authentik

  # --- NetBird (combined server, behind the Traefik edge) ------------------
  # The netbird-server + dashboard carry NetBird's OFFICIAL Traefik labels, so the
  # gRPC h2c routing is upstream-maintained. If the dashboard can't reach the API,
  # check: https://docs.netbird.io/selfhosted/external-reverse-proxy
  info "Pulling + starting NetBird (combined server + dashboard)..."
  docker compose -f "${STACK_DIR}/docker-compose.netbird.yml" pull || true
  docker compose -f "${STACK_DIR}/docker-compose.netbird.yml" up -d
  for i in $(seq 1 30); do
    docker ps --format '{{.Names}}' | grep -qx "netbird-server" && { success "NetBird containers up"; break; }
    printf "\r  ${C_DIM}Waiting for NetBird... %d/30${C_R}" "$i" >&2
    [[ $i -eq 30 ]] && warn "netbird-server not detected. Check: docker logs netbird-server"
    sleep 2
  done; printf "\r" >&2

  # --- Bootstrap NetBird admin user + get PAT (needed for REST API) ----------
  bootstrap_netbird_admin

  # --- CrowdSec -------------------------------------------------------------
  info "Starting CrowdSec..."
  docker compose -f "${STACK_DIR}/docker-compose.crowdsec.yml" up -d crowdsec
  for i in $(seq 1 30); do
    docker ps --format '{{.Names}}' | grep -qx "crowdsec" && { success "CrowdSec container running"; break; }
    printf "\r  ${C_DIM}Waiting for CrowdSec container... %d/30${C_R}" "$i" >&2
    [[ $i -eq 30 ]] && warn "CrowdSec container not found"
    sleep 2
  done; printf "\r" >&2

  # --- NetBird reverse proxy (needs netbird-server + crowdsec already up) ----
  start_netbird_proxy

  success "Edge up — https://netbird.${DOMAIN} | https://authentik.${DOMAIN} | https://dockhand.${DOMAIN}"
  success "NetBird reverse proxy ready for future remote services (Reverse Proxy -> Services in dashboard)."
}

# -------------------------------------------------------------------------------
# Traefik edge + Authentik (IdP) + NetBird config generators
# -------------------------------------------------------------------------------

# ---- Traefik ------------------------------------------------------------------
gen_traefik_files() {
  local le_email="$1"
  # Single Traefik edge. Entrypoint + resolver names (websecure / letsencrypt) and
  # the gRPC stream-timeout flags are taken from NetBird's official installer, so
  # NetBird's own container labels (netbird-grpc / netbird-backend / *-h2c) route
  # correctly WITHOUT any hand-written routers. Also fronts Authentik + Dockhand.
  cat > "${STACK_DIR}/docker-compose.traefik.yml" << COMPOSE_TRAEFIK
services:
  traefik:
    image: traefik:v3.6
    container_name: traefik
    hostname: traefik
    restart: always
    security_opt:
      - no-new-privileges:true
    ports:
      - 0.0.0.0:80:80
      - 0.0.0.0:443:443
    command:
      - "--global.sendAnonymousUsage=false"
      - "--log.level=INFO"
      - "--accesslog=true"
      - "--accesslog.filepath=/logs/access.log"
      - "--accesslog.format=json"
      - "--api.dashboard=false"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.docker.network=proxy"
      - "--providers.file.directory=/dynamic"
      - "--providers.file.watch=true"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
      - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
      - "--entrypoints.websecure.address=:443"
      # Let ACME TLS-ALPN-01 challenges for domains we DON'T manage (the NetBird
      # reverse proxy's app subdomains) bypass our resolver and reach the TCP
      # passthrough router -> netbird-proxy. Without this, acme.tlschallenge
      # intercepts those handshakes and the proxy's per-service certs never issue.
      - "--entrypoints.websecure.allowACMEByPass=true"
      # gRPC streams (NetBird mgmt/signal/relay) must never time out.
      - "--entrypoints.websecure.transport.respondingTimeouts.readTimeout=0"
      - "--entrypoints.websecure.transport.respondingTimeouts.writeTimeout=0"
      - "--entrypoints.websecure.transport.respondingTimeouts.idleTimeout=0"
      - "--serverstransport.forwardingtimeouts.responseheadertimeout=0s"
      - "--serverstransport.forwardingtimeouts.idleconntimeout=0s"
      - "--certificatesresolvers.letsencrypt.acme.email=${le_email}"
      - "--certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json"
      # Use HTTP-01 challenge (port 80) for Traefik's own certs (netbird.${DOMAIN}).
      # TLS-ALPN-01 would conflict with allowACMEByPass=true + the TCP passthrough
      # router (HostSNI(*)) which intercepts the ALPN handshake before Traefik's
      # ACME handler can respond. HTTP-01 uses port 80 which Traefik fully controls.
      # netbird-proxy still uses TLS-ALPN-01 for its per-service certs (passed
      # through by allowACMEByPass to the TCP passthrough router).
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge=true"
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik/dynamic:/dynamic:ro
      - ./traefik/letsencrypt:/letsencrypt
      - ./traefik/logs:/logs
    networks:
      proxy:
        ipv4_address: ${TRAEFIK_STATIC_IP}
networks:
  proxy:
    external: true
COMPOSE_TRAEFIK

  # Forward-auth middleware -> Authentik embedded outpost (standard integration).
  # NetBird routing is NOT here -- the netbird-server/dashboard containers carry
  # NetBird's official Traefik labels (see gen_netbird_files), so the h2c/gRPC
  # routing is upstream-maintained, not reinvented.
  cat > "${TRAEFIK_DYNAMIC_DIR}/authentik.yml" << 'DYN_AK'
http:
  middlewares:
    authentik:
      forwardAuth:
        address: http://authentik-server:9000/outpost.goauthentik.io/auth/traefik
        trustForwardHeader: true
        authResponseHeaders:
          - X-authentik-username
          - X-authentik-groups
          - X-authentik-email
          - X-authentik-name
          - X-authentik-uid
          - X-authentik-jwt
          - X-authentik-meta-jwks
          - X-authentik-meta-outpost
          - X-authentik-meta-provider
          - X-authentik-meta-app
          - X-authentik-meta-version
DYN_AK

  # PROXY-protocol v2 transport for the TCP passthrough route to netbird-proxy.
  # The proxy-tls service references this (serverstransport=pp-v2@file) so Traefik
  # hands the real client IP to the proxy backend. Pairs with NB_PROXY_PROXY_PROTOCOL
  # + NB_PROXY_TRUSTED_PROXIES=${TRAEFIK_STATIC_IP} in netbird/proxy.env.
  cat > "${TRAEFIK_DYNAMIC_DIR}/pp-v2.yml" << 'DYN_PP'
tcp:
  serversTransports:
    pp-v2:
      proxyProtocol:
        version: 2
DYN_PP
  success "Traefik edge written (NetBird-compatible: websecure/letsencrypt, gRPC timeouts off, ACME bypass + PROXY-protocol for netbird-proxy)"
}

# ---- Authentik ----------------------------------------------------------------
gen_authentik_files() {
  local ak_secret pg_pass
  ak_secret=$(rand_secret); pg_pass=$(rand_password 32)
  cat > "${AUTHENTIK_DIR}/authentik.env" << AK_ENV
AUTHENTIK_SECRET_KEY=${ak_secret}
AUTHENTIK_ERROR_REPORTING__ENABLED=false
AUTHENTIK_POSTGRESQL__HOST=authentik-postgres
AUTHENTIK_POSTGRESQL__USER=authentik
AUTHENTIK_POSTGRESQL__NAME=authentik
AUTHENTIK_POSTGRESQL__PASSWORD=${pg_pass}
AUTHENTIK_REDIS__HOST=authentik-redis
AUTHENTIK_EMAIL__FROM=admin@${DOMAIN}
AUTHENTIK_BOOTSTRAP_PASSWORD=${AUTHENTIK_BOOTSTRAP_PASSWORD}
AUTHENTIK_BOOTSTRAP_TOKEN=${AUTHENTIK_BOOTSTRAP_TOKEN}
AUTHENTIK_BOOTSTRAP_EMAIL=admin@${DOMAIN}
POSTGRES_USER=authentik
POSTGRES_DB=authentik
POSTGRES_PASSWORD=${pg_pass}
AK_ENV
  chmod 600 "${AUTHENTIK_DIR}/authentik.env"
  printf '%s' "$AUTHENTIK_BOOTSTRAP_PASSWORD" > "${AUTHENTIK_DIR}/.akadmin_password"
  chmod 600 "${AUTHENTIK_DIR}/.akadmin_password"

  cat > "${STACK_DIR}/docker-compose.authentik.yml" << COMPOSE_AK
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
  authentik-redis:
    image: redis:7-alpine
    container_name: authentik-redis
    hostname: authentik-redis
    restart: unless-stopped
    command: --save 60 1 --loglevel warning
    volumes:
      - ./authentik/redis:/data
    networks:
      - proxy
  authentik-server:
    image: ghcr.io/goauthentik/server:2024.12
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
      authentik-redis:
        condition: service_started
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.authentik.rule=Host(\`authentik.${DOMAIN}\`)"
      - "traefik.http.routers.authentik.entrypoints=websecure"
      - "traefik.http.routers.authentik.tls.certresolver=letsencrypt"
      - "traefik.http.services.authentik.loadbalancer.server.port=9000"
    networks:
      - proxy
  authentik-worker:
    image: ghcr.io/goauthentik/server:2024.12
    container_name: authentik-worker
    hostname: authentik-worker
    restart: unless-stopped
    command: worker
    env_file: ./authentik/authentik.env
    user: root
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./authentik/media:/media
      - ./authentik/templates:/templates
      - ./authentik/blueprints:/blueprints/custom
      - ./authentik/certs:/certs
    depends_on:
      authentik-postgres:
        condition: service_healthy
      authentik-redis:
        condition: service_started
    networks:
      - proxy
networks:
  proxy:
    external: true
COMPOSE_AK

  # Authentik is deployed as a general-purpose IdP. It is exposed via the NetBird
  # reverse proxy (authentik.${DOMAIN}), NOT via Traefik forward-auth.
  # App auth for dockhand and other services is handled by the NetBird reverse
  # proxy's own auth (SSO/password/PIN) configured per-service in the dashboard.
  # No forward-auth blueprint is needed since nothing routes through Traefik
  # anymore -- all app ingress goes through netbird-proxy.
  success "Authentik compose written (exposed via NetBird reverse proxy)"
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
  step "Bootstrapping Authentik (health check)"
  # Authentik is exposed via the NetBird reverse proxy, not via Traefik forward-auth.
  # No blueprint to apply -- just verify Authentik is healthy and ready to serve
  # login pages when the NetBird proxy forwards traffic to it.
  local ok=false i
  for i in $(seq 1 45); do
    if curl -sf --max-time 5 -o /dev/null http://127.0.0.1:9000/-/health/ready/ 2>/dev/null; then ok=true; break; fi
    printf "\r  ${C_DIM}Waiting for Authentik to be ready... %d/45${C_R}" "$i" >&2
    sleep 4
  done; printf "\r" >&2
  if $ok; then
    success "Authentik ready (will be exposed via NetBird reverse proxy)"
  else
    warn "Authentik not healthy yet. Check: docker logs authentik-server"
    warn "  Initial login (once proxied): akadmin / ${AUTHENTIK_DIR}/.akadmin_password"
  fi
}

# ---- NetBird ------------------------------------------------------------------
gen_netbird_files() {
  local _ip="${1:-}"   # unused (combined server has built-in STUN/relay)
  local relay_secret="$NETBIRD_DATAREPLICA_SECRET" enc_key
  enc_key=$(openssl rand -base64 32)
  mkdir -p "${NETBIRD_DIR}/data"

  # config.yaml -- VERBATIM from NetBird's official installer render_combined_yaml()
  # (combined netbird-server, EMBEDDED IdP at /oauth2, sqlite store). No external
  # OIDC: NetBird logs in via its own built-in IdP. Authentik is exposed via the
  # NetBird reverse proxy (authentik.${DOMAIN}) as a general-purpose IdP.
  cat > "${NETBIRD_DIR}/config.yaml" << NBCFG
server:
  listenAddress: ":80"
  exposedAddress: "https://netbird.${DOMAIN}:443"
  stunPorts:
    - 3478
  metricsPort: 9090
  healthcheckAddress: ":9000"
  logLevel: "info"
  logFile: "console"

  authSecret: "${relay_secret}"
  dataDir: "/var/lib/netbird"

  auth:
    issuer: "https://netbird.${DOMAIN}/oauth2"
    signKeyRefreshEnabled: true
    dashboardRedirectURIs:
      - "https://netbird.${DOMAIN}/nb-auth"
      - "https://netbird.${DOMAIN}/nb-silent-auth"
    cliRedirectURIs:
      - "http://localhost:53000/"

  reverseProxy:
    trustedHTTPProxies:
      - "172.16.0.0/12"
      - "10.0.0.0/8"
      - "192.168.0.0/16"

  store:
    engine: "sqlite"
    encryptionKey: "${enc_key}"
NBCFG

  # dashboard.env -- VERBATIM from the installer render_dashboard_env(): points the
  # dashboard at NetBird's embedded IdP (/oauth2), client id netbird-dashboard.
  cat > "${NETBIRD_DIR}/dashboard.env" << NBDASH
NETBIRD_MGMT_API_ENDPOINT=https://netbird.${DOMAIN}
NETBIRD_MGMT_GRPC_API_ENDPOINT=https://netbird.${DOMAIN}
AUTH_AUDIENCE=netbird-dashboard
AUTH_CLIENT_ID=netbird-dashboard
AUTH_CLIENT_SECRET=
AUTH_AUTHORITY=https://netbird.${DOMAIN}/oauth2
USE_AUTH0=false
AUTH_SUPPORTED_SCOPES=openid profile email groups
AUTH_REDIRECT_URI=/nb-auth
AUTH_SILENT_REDIRECT_URI=/nb-silent-auth
NBDASH

  # Combined netbird-server + dashboard. Traefik labels are VERBATIM from NetBird's
  # installer (netbird-grpc / netbird-backend / netbird-server-h2c, dashboard) so the
  # gRPC h2c routing is upstream-maintained. STUN published on 3478/udp; relay rides
  # Traefik on /relay (no extra host port). One Traefik (ours) routes all of it.
  cat > "${STACK_DIR}/docker-compose.netbird.yml" << COMPOSE_NB
services:
  netbird-server:
    image: netbirdio/netbird-server:latest
    container_name: netbird-server
    hostname: netbird-server
    restart: unless-stopped
    ports:
      - 0.0.0.0:3478:3478/udp
    volumes:
      - ./netbird/data:/var/lib/netbird
      - ./netbird/config.yaml:/etc/netbird/config.yaml
    command: ["--config", "/etc/netbird/config.yaml"]
    environment:
      - NB_SETUP_PAT_ENABLED=true
    labels:
      - traefik.enable=true
      - "traefik.http.routers.netbird-grpc.rule=Host(\`netbird.${DOMAIN}\`) && (PathPrefix(\`/signalexchange.SignalExchange/\`) || PathPrefix(\`/management.ManagementService/\`) || PathPrefix(\`/management.ProxyService/\`))"
      - traefik.http.routers.netbird-grpc.entrypoints=websecure
      - traefik.http.routers.netbird-grpc.tls=true
      - traefik.http.routers.netbird-grpc.tls.certresolver=letsencrypt
      - traefik.http.routers.netbird-grpc.service=netbird-server-h2c
      - traefik.http.routers.netbird-grpc.priority=100
      - "traefik.http.routers.netbird-backend.rule=Host(\`netbird.${DOMAIN}\`) && (PathPrefix(\`/relay\`) || PathPrefix(\`/ws-proxy/\`) || PathPrefix(\`/api\`) || PathPrefix(\`/oauth2\`))"
      - traefik.http.routers.netbird-backend.entrypoints=websecure
      - traefik.http.routers.netbird-backend.tls=true
      - traefik.http.routers.netbird-backend.tls.certresolver=letsencrypt
      - traefik.http.routers.netbird-backend.service=netbird-server
      - traefik.http.routers.netbird-backend.priority=100
      - traefik.http.services.netbird-server.loadbalancer.server.port=80
      - traefik.http.services.netbird-server-h2c.loadbalancer.server.port=80
      - traefik.http.services.netbird-server-h2c.loadbalancer.server.scheme=h2c
    networks:
      - proxy
  netbird-dashboard:
    image: netbirdio/dashboard:latest
    container_name: netbird-dashboard
    hostname: netbird-dashboard
    restart: unless-stopped
    env_file:
      - ./netbird/dashboard.env
    labels:
      - traefik.enable=true
      - "traefik.http.routers.netbird-dashboard.rule=Host(\`netbird.${DOMAIN}\`)"
      - traefik.http.routers.netbird-dashboard.entrypoints=websecure
      - traefik.http.routers.netbird-dashboard.tls=true
      - traefik.http.routers.netbird-dashboard.tls.certresolver=letsencrypt
      - traefik.http.routers.netbird-dashboard.service=dashboard
      - traefik.http.routers.netbird-dashboard.priority=1
      - traefik.http.services.dashboard.loadbalancer.server.port=80
    networks:
      - proxy
networks:
  proxy:
    external: true
COMPOSE_NB
  success "NetBird (combined server, embedded IdP) compose + config.yaml + dashboard.env written"
}

# ---- CrowdSec (Traefik-log aware) --------------------------------------------
gen_crowdsec_compose() {
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
      - ./traefik/logs:/traefik-logs:ro
      - /var/log:/var/log:ro
    environment:
      # traefik collection parses the Traefik JSON access log (replaces the old
      # nginx-proxy-manager collection). http-cve/http-dos/whitelist as before.
      - COLLECTIONS=crowdsecurity/sshd crowdsecurity/traefik crowdsecurity/linux crowdsecurity/http-cve crowdsecurity/http-dos crowdsecurity/whitelist-good-actors
      - BOUNCER_KEY_cloudflarebouncer=${CF_BOUNCER_KEY}
      # Pre-registered bouncer for the NetBird reverse proxy (enforces IP bans at
      # the proxy via NB_PROXY_CROWDSEC_API_KEY in netbird/proxy.env).
      - BOUNCER_KEY_netbirdproxy=${NB_PROXY_CROWDSEC_KEY}
      - TZ=UTC
    networks:
      - proxy
networks:
  proxy:
    external: true
COMPOSE_CROWDSEC
}

# ---- NetBird reverse proxy (the ingress engine) ------------------------------
# Deploys netbirdio/reverse-proxy. Traefik passes ALL unmatched HTTPS (every
# subdomain except netbird.${DOMAIN}) straight through to this container via a
# TCP HostSNI(*) passthrough route; the proxy terminates TLS itself (per-service
# ACME) and forwards to targets. Same-host containers are reached via "Direct
# Upstream" (e.g. dockhand:3000) with no WireGuard hairpin.
# Wiring mirrors NetBird's official getting-started.sh (v0.72). Per-service
# routes are auto-created via the NetBird management REST API (see
# create_netbird_proxy_services).
gen_netbird_proxy_files() {
  write_netbird_proxy_env ""          # token filled later by start_netbird_proxy
  mkdir -p "${NETBIRD_DIR}/proxy-certs"
  # The netbird-proxy container runs as a non-root user and needs to write
  # ACME certificates + lock files to /certs. Without this, cert issuance fails
  # with "permission denied" on .lock and account key files.
  chmod 777 "${NETBIRD_DIR}/proxy-certs"
  cat > "${STACK_DIR}/docker-compose.netbird-proxy.yml" << COMPOSE_NBPROXY
services:
  netbird-proxy:
    image: netbirdio/reverse-proxy:latest
    container_name: netbird-proxy
    hostname: netbird-proxy
    restart: unless-stopped
    ports:
      - 0.0.0.0:51820:51820/udp
    env_file:
      - ./netbird/proxy.env
    volumes:
      - ./netbird/proxy-certs:/certs
    labels:
      # TCP passthrough for any domain NOT matched by an explicit HTTP router
      # (netbird.${DOMAIN}). priority=1 keeps it lowest so the control-plane
      # subdomain still terminates at Traefik.
      - traefik.enable=true
      - traefik.tcp.routers.proxy-passthrough.entrypoints=websecure
      - "traefik.tcp.routers.proxy-passthrough.rule=HostSNI(\`*\`)"
      - traefik.tcp.routers.proxy-passthrough.tls.passthrough=true
      - traefik.tcp.routers.proxy-passthrough.service=proxy-tls
      - traefik.tcp.routers.proxy-passthrough.priority=1
      - traefik.tcp.services.proxy-tls.loadbalancer.server.port=8443
      - traefik.tcp.services.proxy-tls.loadbalancer.serverstransport=pp-v2@file
    networks:
      - proxy
networks:
  proxy:
    external: true
COMPOSE_NBPROXY
  success "NetBird reverse-proxy compose + proxy.env written"
}

# Write netbird/proxy.env. $1 = proxy token (empty on first render).
write_netbird_proxy_env() {
  local token="${1:-}"
  cat > "${NETBIRD_DIR}/proxy.env" << NBPROXYENV
# NetBird Proxy Configuration (mirrors NetBird official getting-started.sh v0.72)
NB_PROXY_DEBUG_LOGS=false
NB_PROXY_MANAGEMENT_ADDRESS=http://netbird-server:80
NB_PROXY_ALLOW_INSECURE=true
NB_PROXY_DOMAIN=${DOMAIN}
NB_PROXY_ADDRESS=:8443
NB_PROXY_TOKEN=${token}
NB_PROXY_CERTIFICATE_DIRECTORY=/certs
NB_PROXY_ACME_CERTIFICATES=true
NB_PROXY_ACME_CHALLENGE_TYPE=tls-alpn-01
NB_PROXY_FORWARDED_PROTO=https
NB_PROXY_PROXY_PROTOCOL=true
NB_PROXY_TRUSTED_PROXIES=${TRAEFIK_STATIC_IP}
NB_PROXY_CROWDSEC_API_URL=http://crowdsec:8080
NB_PROXY_CROWDSEC_API_KEY=${NB_PROXY_CROWDSEC_KEY}
NBPROXYENV
  chmod 600 "${NETBIRD_DIR}/proxy.env"
}

# Mint the proxy token from the RUNNING netbird-server, then start the proxy.
# Called after netbird-server + crowdsec are up.
start_netbird_proxy() {
  step "NetBird reverse proxy (token + start)"
  info "Minting netbird-proxy access token from netbird-server..."
  local i token=""
  for i in $(seq 1 20); do
    token=$(docker exec netbird-server /go/bin/netbird-server token create \
              --name "default-proxy" --config /etc/netbird/config.yaml 2>/dev/null \
            | grep "^Token:" | awk '{print $2}') || true
    [[ -n "$token" ]] && break
    printf "\r  ${C_DIM}Waiting for netbird-server to mint token... %d/20${C_R}" "$i" >&2
    sleep 3
  done; printf "\r" >&2

  if [[ -z "$token" ]]; then
    warn "Could not mint netbird-proxy token. Proxy NOT started. Finish manually:"
    warn "  docker exec -it netbird-server /go/bin/netbird-server token create --name default-proxy --config /etc/netbird/config.yaml"
    warn "  put it in ${NETBIRD_DIR}/proxy.env (NB_PROXY_TOKEN=), then:"
    warn "  docker compose -f ${STACK_DIR}/docker-compose.netbird-proxy.yml up -d"
    return 0
  fi
  NB_PROXY_TOKEN="$token"
  printf '%s' "$token" > "${NETBIRD_DIR}/.proxy_token"; chmod 600 "${NETBIRD_DIR}/.proxy_token"
  write_netbird_proxy_env "$token"
  success "netbird-proxy token created (saved: ${NETBIRD_DIR}/.proxy_token)"

  info "Pulling + starting netbird-proxy..."
  docker compose -f "${STACK_DIR}/docker-compose.netbird-proxy.yml" pull || true
  docker compose -f "${STACK_DIR}/docker-compose.netbird-proxy.yml" up -d
  for i in $(seq 1 30); do
    docker ps --format '{{.Names}}' | grep -qx "netbird-proxy" && { success "netbird-proxy running"; break; }
    printf "\r  ${C_DIM}Waiting for netbird-proxy... %d/30${C_R}" "$i" >&2
    [[ $i -eq 30 ]] && warn "netbird-proxy not detected. Check: docker logs netbird-proxy"
    sleep 2
  done; printf "\r" >&2
}

# Create the first NetBird owner user via the setup API and obtain a Personal
# Access Token (PAT). The PAT is required to authenticate REST API calls that
# create reverse proxy services. The proxy token (nbx_...) from 'token create'
# is for gRPC only; the REST API needs a PAT (nbp_...).
#
# Requires NB_SETUP_PAT_ENABLED=true on the netbird-server container (set in
# the compose file). The setup endpoint is only available when no users exist;
# once the owner is created, it auto-disables.
bootstrap_netbird_admin() {
  step "Bootstrapping NetBird admin user (setup API + PAT)"

  local nb_ip
  nb_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' netbird-server 2>/dev/null) || true
  if [[ -z "$nb_ip" ]]; then
    warn "Cannot find netbird-server container IP. NetBird admin NOT created."
    warn "  Create the admin manually: visit https://netbird.${DOMAIN} and follow the setup page."
    return 0
  fi
  local api_base="http://${nb_ip}:80/api"

  # Generate admin credentials
  NB_ADMIN_EMAIL="admin@${DOMAIN}"
  NB_ADMIN_PASSWORD=$(rand_password 24)

  local payload
  payload=$(jq -nc \
    --arg email "$NB_ADMIN_EMAIL" \
    --arg name "Admin" \
    --arg password "$NB_ADMIN_PASSWORD" \
    '{
      email: $email,
      name: $name,
      password: $password,
      create_pat: true,
      pat_expire_in: 365
    }')

  info "Creating NetBird admin user via setup API..."
  local resp http_code body
  for i in $(seq 1 30); do
    resp=$(curl -s -w '\n%{http_code}' --max-time 10 \
      -X POST \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "${api_base}/setup" 2>/dev/null) || true
    http_code=$(echo "$resp" | tail -1)
    body=$(echo "$resp" | sed '$d')

    if [[ "$http_code" == "200" || "$http_code" == "201" ]]; then
      # Extract the PAT from the response
      NB_PAT=$(echo "$body" | jq -r '.personal_access_token // empty' 2>/dev/null || true)
      if [[ -n "$NB_PAT" ]]; then
        success "NetBird admin user created: ${NB_ADMIN_EMAIL}"
        # Save credentials (mode 600)
        printf '%s' "$NB_ADMIN_PASSWORD" > "${NETBIRD_DIR}/.admin_password"
        chmod 600 "${NETBIRD_DIR}/.admin_password"
        printf '%s' "$NB_PAT" > "${NETBIRD_DIR}/.api_token"
        chmod 600 "${NETBIRD_DIR}/.api_token"
        success "PAT saved (365-day expiry): ${NETBIRD_DIR}/.api_token"
        return 0
      else
        # User created but no PAT in response -- NB_SETUP_PAT_ENABLED might not be set
        success "NetBird admin user created: ${NB_ADMIN_EMAIL}"
        warn "No PAT in setup response (NB_SETUP_PAT_ENABLED not active?)."
        warn "  Create a PAT manually in the dashboard to enable API automation."
        printf '%s' "$NB_ADMIN_PASSWORD" > "${NETBIRD_DIR}/.admin_password"
        chmod 600 "${NETBIRD_DIR}/.admin_password"
        return 0
      fi
    elif [[ "$http_code" == "400" ]]; then
      # Could be "setup already completed" if re-running
      local err_msg
      err_msg=$(echo "$body" | jq -r '.message // empty' 2>/dev/null || true)
      if echo "$err_msg" | grep -qi "setup\|already\|completed"; then
        info "NetBird setup already completed -- admin user exists."
        # Try to use an existing PAT if the script saved one before
        if [[ -f "${NETBIRD_DIR}/.api_token" ]]; then
          NB_PAT=$(cat "${NETBIRD_DIR}/.api_token" 2>/dev/null || true)
          if [[ -n "$NB_PAT" ]]; then
            success "Using existing PAT from ${NETBIRD_DIR}/.api_token"
            return 0
          fi
        fi
        warn "No existing PAT found. Create one in the dashboard (User settings)."
        return 0
      fi
    fi
    printf "\r  ${C_DIM}Waiting for NetBird setup API... %d/30${C_R}" "$i" >&2
    sleep 3
  done; printf "\r" >&2

  warn "Could not create NetBird admin via setup API (HTTP ${http_code:-0})."
  warn "  Response: ${body:-<empty>}"
  warn "  Create the admin manually: visit https://netbird.${DOMAIN} and follow the setup page."
  printf '%s' "$NB_ADMIN_PASSWORD" > "${NETBIRD_DIR}/.admin_password"
  chmod 600 "${NETBIRD_DIR}/.admin_password"
}

# Create reverse proxy services for Dockhand and Authentik via the NetBird
# management REST API. Requires a Personal Access Token (PAT) from
# bootstrap_netbird_admin(). The proxy cluster (netbird-proxy) must already be
# registered with the management server. Services are created with
# direct_upstream=true so the proxy dials the target containers directly over
# the Docker network (no WireGuard hairpin).
create_netbird_proxy_services() {
  step "Creating NetBird reverse proxy services (Dockhand + Authentik)"

  if [[ -z "$NB_PAT" ]]; then
    warn "No PAT -- cannot create reverse proxy services via API."
    warn "  Create a PAT in the NetBird dashboard (User settings), then run:"
    warn "    curl -X POST https://netbird.${DOMAIN}/api/reverse-proxies/services \\"
    warn "      -H 'Authorization: Token <YOUR_PAT>' -H 'Content-Type: application/json' \\"
    warn "      -d '{\"name\":\"dockhand.${DOMAIN}\",\"domain\":\"dockhand.${DOMAIN}\",\"mode\":\"http\",\"targets\":[{\"target_id\":\"\",\"target_type\":\"host\",\"path\":\"/\",\"protocol\":\"http\",\"host\":\"dockhand\",\"port\":3000,\"enabled\":true,\"options\":{\"direct_upstream\":true}}],\"enabled\":true}'"
    warn "    (repeat for authentik.${DOMAIN} -> authentik-server:9000)"
    return 0
  fi

  # The management server listens on :80 inside the container (HTTP, not HTTPS
  # -- safe because traffic never leaves the Docker network). Reach it via the
  # container's IP on the proxy bridge network.
  local nb_ip
  nb_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' netbird-server 2>/dev/null) || true
  if [[ -z "$nb_ip" ]]; then
    warn "Cannot find netbird-server container IP. Services not created via API."
    warn "  Create them manually in the NetBird dashboard -> Reverse Proxy -> Services:"
    warn "    dockhand.${DOMAIN}  ->  Host: dockhand, Port: 3000, Direct Upstream"
    warn "    authentik.${DOMAIN} ->  Host: authentik-server, Port: 9000, Direct Upstream"
    return 0
  fi
  local api_base="http://${nb_ip}:80/api"

  # Wait for the proxy cluster to register with the management server. Until it
  # appears in GET /api/reverse-proxies/clusters, service creation will fail.
  # The proxy must: start -> gRPC dial management -> authenticate -> register ->
  # management publishes it via the REST API. This can take 2-4 minutes on first
  # boot (key generation + TLS handshake). Poll up to 5 minutes.
  info "Waiting for netbird-proxy cluster to register with management server..."
  local cluster_ok=false i clusters_resp
  for i in $(seq 1 60); do
    clusters_resp=$(curl -sf --max-time 5 \
      -H "Authorization: Token ${NB_PAT}" \
      "${api_base}/reverse-proxies/clusters" 2>/dev/null) || true
    if echo "$clusters_resp" | jq -e '.[] | select(.online == true)' >/dev/null 2>&1; then
      cluster_ok=true; break
    fi
    printf "\r  ${C_DIM}Waiting for proxy cluster... %d/60${C_R}" "$i" >&2
    sleep 5
  done; printf "\r" >&2

  if ! $cluster_ok; then
    warn "netbird-proxy cluster not registered after 5 minutes. Services not created via API."
    warn "  Last API response from management server:"
    warn "    ${clusters_resp:-<empty>}"
    warn "  netbird-proxy logs (last 20 lines):"
    docker logs --tail 20 netbird-proxy 2>&1 | sed 's/^/    /' >&2 || true
    warn "  Create them manually in the NetBird dashboard -> Reverse Proxy -> Services:"
    warn "    dockhand.${DOMAIN}  ->  Host: dockhand, Port: 3000, Direct Upstream"
    warn "    authentik.${DOMAIN} ->  Host: authentik-server, Port: 9000, Direct Upstream"
    return 0
  fi
  success "Proxy cluster is online"

  # Verify the cluster has the Private capability (required for proxy_cluster
  # target type + direct_upstream). Without it, the API will reject our service
  # creation requests.
  local has_private=false
  echo "$clusters_resp" | jq -e '.[] | select(.private == true)' >/dev/null 2>&1 && has_private=true
  if ! $has_private; then
    warn "Proxy cluster does NOT have the Private capability."
    warn "  This is required for direct-upstream targets (same-host Docker containers)."
    warn "  Check: docker logs netbird-proxy (look for NB_PROXY_PRIVATE=true)"
    warn "  Ensure the proxy container was started with NB_PROXY_PRIVATE=true in proxy.env"
    return 0
  fi
  success "Proxy cluster has Private capability (direct upstream enabled)"

  # Helper: POST a reverse proxy service. $1=name/domain, $2=target host, $3=target port
  # Uses target_type "proxy_cluster" + direct_upstream=true so the proxy dials
  # the target directly from its Docker network stack (no WireGuard needed).
  # NB_PROXY_PRIVATE=true on the proxy container unlocks this target type.
  _nb_create_service() {
    local svc_domain="$1" tgt_host="$2" tgt_port="$3"
    local payload
    payload=$(jq -nc \
      --arg name "$svc_domain" \
      --arg domain "$svc_domain" \
      --arg host "$tgt_host" \
      --argjson port "$tgt_port" \
      '{
        name: $name,
        domain: $domain,
        mode: "http",
        targets: [{
          target_id: "",
          target_type: "proxy_cluster",
          path: "/",
          protocol: "http",
          host: $host,
          port: $port,
          enabled: true,
          options: {
            direct_upstream: true,
            skip_tls_verify: false
          }
        }],
        enabled: true,
        pass_host_header: false,
        rewrite_redirects: true,
        private: false
      }')

    local resp http_code
    resp=$(curl -s -w '\n%{http_code}' --max-time 15 \
      -X POST \
      -H "Authorization: Token ${NB_PAT}" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "${api_base}/reverse-proxies/services" 2>/dev/null) || true
    http_code=$(echo "$resp" | tail -1)
    local body; body=$(echo "$resp" | sed '$d')

    case "$http_code" in
      200|201)
        success "Reverse proxy service created: ${svc_domain} -> ${tgt_host}:${tgt_port}"
        ;;
      409)
        # Already exists -- not an error on re-run
        success "Service already exists: ${svc_domain}"
        ;;
      *)
        warn "Failed to create service ${svc_domain} (HTTP ${http_code:-0})"
        warn "  Response: ${body:-<empty>}"
        warn "  Manual: NetBird dashboard -> Reverse Proxy -> Services -> Add Service"
        warn "    Domain: ${svc_domain}, Target: Proxy Cluster, Host: ${tgt_host}, Port: ${tgt_port}"
        ;;
    esac
  }

  info "Creating reverse proxy service for Dockhand..."
  _nb_create_service "dockhand.${DOMAIN}" "dockhand" 3000

  info "Creating reverse proxy service for Authentik..."
  _nb_create_service "authentik.${DOMAIN}" "authentik-server" 9000

  info "Reverse proxy services created. Configure auth (SSO/password/PIN) in the"
  info "  NetBird dashboard -> Reverse Proxy -> Services -> [service] -> Authentication."
  info "  DNS: point *.${DOMAIN} -> $(get_external_ip) for TLS to issue."
}

# ==============================================================================
# DEPRECATED / UNUSED -- vestigial NPM + Authelia helpers carried over from
# deploy-dockhand.sh. Nothing calls them in this script (the stack uses Traefik +
# Authentik instead). They are inert (only referenced inside their own bodies) and
# safe to delete wholesale down to the "Firewall, logrotate, CrowdSec" banner.
# Kept only to keep this rewrite's diff reviewable; prune in a follow-up commit.
# ==============================================================================
npm_change_password() {
  step "Securing NPM admin password"
  local NEW_PASS JSON LOGIN
  NEW_PASS=$(rand_password 24)
  # NPM 2.15+ ships with NO default user: GET /api/ reports "setup":false and the
  # first admin is created via an UNAUTHENTICATED POST /api/users (admin@example.com/
  # changeme can NEVER log in there -> "Invalid email or password" + no proxy hosts).
  # Read .setup RAW (jq '.setup // empty' wrongly returns empty when it IS false), poll
  # until the API is ready, then create the admin with our random password.
  local _setup="" _st _cu _t
  for _st in 1 2 3 4 5 6 7 8; do
    _setup=$(_npm_api "/" 2>/dev/null | jq -r '.setup' 2>/dev/null || echo "")
    [[ "$_setup" == "true" || "$_setup" == "false" ]] && break
    sleep 3
  done
  if [[ "$_setup" == "false" ]]; then
    printf '%s' "$NEW_PASS" > "${STACK_DIR}/.npm_admin_password"; chmod 600 "${STACK_DIR}/.npm_admin_password"
    NPM_TOKEN=""
    _cu=$(jq -nc --arg pw "$NEW_PASS" '{name:"Administrator",nickname:"Admin",email:"admin@example.com",roles:["admin"],is_disabled:false,auth:{type:"password",secret:$pw}}')
    for _t in 1 2 3 4 5; do
      _npm_api "/users" -d "$_cu" >/dev/null 2>&1 || true
      LOGIN=$(_npm_api "/tokens" -d "$(jq -nc --arg s "$NEW_PASS" '{identity:"admin@example.com",secret:$s}')" 2>/dev/null) || true
      NPM_TOKEN=$(echo "$LOGIN" | jq -r '.token // empty' 2>/dev/null)
      [[ -n "$NPM_TOKEN" ]] && break
      sleep 3
    done
    if [[ -n "$NPM_TOKEN" ]]; then
      success "NPM first admin created (admin@example.com) - saved to ${STACK_DIR}/.npm_admin_password (mode 600)"
      return 0
    fi
    warn "NPM setup-mode first-user creation failed; trying the legacy default-login path."
  fi
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

npm_enable_ssl() {
  local HOST_ID="$1"
  local DOMAIN_NAME="$2"
  local EMAIL="${3:-admin@${DOMAIN}}"
  local JSON RESP CERT_ID HOST_JSON

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
    # Wildcard catch-all LAST: any other subdomain (incl. dockhand and
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
      default_redirection_url: "https://dockhand.${DOMAIN}"
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
  # which is a 404 -> every request to Dockhand would 500. The correct
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

register_dockhand_stacks() {
  step "Registering editable stacks in Dockhand"
  info "Copying compose files into the Dockhand data directory for browsing..."
  local f
  for f in traefik authentik netbird dockhand crowdsec; do
    cp "${STACK_DIR}/docker-compose.${f}.yml" "${DOCKHAND_DATA_DIR}/${f}.yml" 2>/dev/null || true
  done
  success "Compose files available in Dockhand file browser: ${DOCKHAND_DATA_DIR}"
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
  # rpcbind (port 111) ships enabled on many cloud images (Oracle/others) and is a
  # known DDoS-amplification + info-disclosure surface we never use. UFW already
  # blocks it from outside, but disable it outright so it isn't even listening.
  if systemctl list-unit-files 2>/dev/null | grep -q '^rpcbind'; then
    systemctl disable --now rpcbind.socket rpcbind 2>/dev/null || true
    success "rpcbind (port 111) disabled"
  fi
  warn "Note: Docker-published ports bypass UFW/firewalld INPUT rules by design. Only 80/443 + 3478/udp are published; CrowdSec bans are enforced in DOCKER-USER too (see bouncer config)."
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
  # NetBird STUN (combined server; relay rides the Traefik edge on /relay).
  ufw allow 3478/udp comment 'NetBird STUN'
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
  # NetBird STUN (combined server; relay rides the Traefik edge on /relay).
  firewall-cmd --permanent --add-port=3478/udp
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
  cat > /etc/logrotate.d/traefik << EOF
${TRAEFIK_LOG_DIR}/*.log {
    weekly
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0644 root root
    sharedscripts
    postrotate
        docker kill --signal='HUP' traefik 2>/dev/null || true
    endscript
}
EOF
  success "Log rotation: ${TRAEFIK_LOG_DIR}/*.log (14 days)"
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
  docker exec crowdsec cscli collections list 2>/dev/null | grep -q "crowdsecurity/traefik" && success "traefik collection" || warn "traefik collection not found"
  docker exec crowdsec cscli collections list 2>/dev/null | grep -q "crowdsecurity/linux" && success "linux collection" || warn "linux not found"
  info "Configuring Traefik log acquisition..."
  local cs_acquis="${CROWDSEC_DIR}/config/acquis.d/traefik.yaml"
  mkdir -p "$(dirname "$cs_acquis")"
  # Traefik writes JSON access logs (--accesslog.format=json, see gen_traefik_files).
  # The crowdsecurity/traefik collection parses them; bans key on the real client IP.
  cat > "$cs_acquis" << 'TRAEFIK_ACQUIS'
filenames:
  - /traefik-logs/*.log
labels:
  type: traefik
TRAEFIK_ACQUIS
  if docker exec crowdsec cat /etc/crowdsec/acquis.d/traefik.yaml &>/dev/null; then
    success "Traefik acquisition configured"
  else
    docker exec -i crowdsec sh -c "mkdir -p /etc/crowdsec/acquis.d && cat > /etc/crowdsec/acquis.d/traefik.yaml" << 'EOF' || true
filenames:
  - /traefik-logs/*.log
labels:
  type: traefik
EOF
    warn "Traefik acquisition written (via docker exec)"
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
  docker exec crowdsec cscli bouncers delete firewall-bouncer 2>/dev/null || true
  # FIXED: the old extraction grepped for lowercase hex ([a-f0-9]{32,}), but
  # modern CrowdSec issues base64-style keys with uppercase chars -> the grep
  # matched nothing, the config file was never written, and the bouncer
  # crash-looped on "no such file". '-o raw' prints exactly the key.
  local api_key
  api_key=$(docker exec crowdsec cscli bouncers add firewall-bouncer -o raw 2>/dev/null | tr -d '[:space:]' || true)
  if [[ -z "$api_key" ]]; then
    # fallback for very old cscli without -o raw: accept base64/hex charsets
    docker exec crowdsec cscli bouncers delete firewall-bouncer 2>/dev/null || true
    api_key=$(docker exec crowdsec cscli bouncers add firewall-bouncer 2>/dev/null | grep -oE '[A-Za-z0-9+/=_-]{30,}' | head -1 || true)
  fi
  if [[ -n "$api_key" ]]; then
    mkdir -p /etc/crowdsec
    local fw_mode="iptables"
    command -v nft &>/dev/null && fw_mode="nftables"
    # iptables_chains includes DOCKER-USER so bans also apply to traffic
    # heading into Docker-published ports (80/443/3478), which otherwise
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
    error "Could not obtain bouncer API key - config NOT written, bans will not be enforced. Fix manually: docker exec crowdsec cscli bouncers add firewall-bouncer -o raw"
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
  step "Cloudflare real-IP restoration (Traefik)"
  # Behind Cloudflare every request arrives from a CF edge IP. Traefik must TRUST
  # those IPs to read the true client from X-Forwarded-For/CF-Connecting-IP, so
  # CrowdSec bans key on the real attacker (not Cloudflare). trustedIPs is a static
  # entrypoint option -> we inject it into the websecure entrypoint and reload Traefik.
  local ips conf="${TRAEFIK_DIR}/cloudflare-ips.txt"
  ips=$(get_cloudflare_ips | paste -sd, - 2>/dev/null || true)
  printf '%s\n' "$ips" > "$conf" 2>/dev/null || true
  if [[ -z "$ips" ]]; then warn "No Cloudflare IP ranges fetched; skipping real-IP trust"; return 0; fi
  local tf="${STACK_DIR}/docker-compose.traefik.yml"
  if grep -q 'forwardedHeaders.trustedIPs' "$tf" 2>/dev/null; then
    info "Traefik trustedIPs already configured"
  else
    sed -i "s#\(\([[:space:]]*\)- \"--entrypoints.websecure.address=:443\"\)#\1\n\2- \"--entrypoints.websecure.forwardedHeaders.trustedIPs=${ips}\"#" "$tf" 2>/dev/null || true
    docker compose -f "$tf" up -d >/dev/null 2>&1 || true
    success "Traefik now trusts Cloudflare edge ranges for real client IP"
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
    # Hard timeouts: the packagecloud script + apt can block forever on the apt/dpkg
    # lock (apt-daily/unattended-upgrades on a fresh boot). Cap them and continue --
    # this whole bouncer step is optional edge enforcement, not required for the stack.
    timeout 180 bash -c 'curl -fsSL --max-time 60 https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash' </dev/null >>"$LOG_FILE" 2>&1 \
      || warn "CrowdSec repo add slow/failed (continuing)"
    # CRITICAL: we pre-created the stub config at the package's OWN conffile path,
    # so dpkg raises an interactive "keep/replace conffile?" prompt. DEBIAN_FRONTEND
    # alone does NOT suppress it -- need --force-confold (keep our stub; step 4
    # overwrites it with the real config). </dev/null guarantees no stdin hang even
    # if anything else prompts. Lock::Timeout waits out apt-daily instead of failing.
    DEBIAN_FRONTEND=noninteractive timeout 300 apt-get install -y -qq \
      -o DPkg::Lock::Timeout=300 \
      -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef \
      crowdsec-cloudflare-worker-bouncer </dev/null >>"$LOG_FILE" 2>&1 \
      || warn "Worker bouncer apt install slow/failed (continuing)"
    command -v crowdsec-cloudflare-worker-bouncer &>/dev/null && have_bin=true
  else
    info "Adding CrowdSec repository + installing the worker bouncer..."
    timeout 180 bash -c 'curl -fsSL --max-time 60 https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.rpm.sh | bash' </dev/null >>"$LOG_FILE" 2>&1 \
      || warn "CrowdSec repo add slow/failed (continuing)"
    local pkg="yum"; command -v dnf &>/dev/null && pkg="dnf"
    timeout 300 $pkg install -y -q crowdsec-cloudflare-worker-bouncer </dev/null >>"$LOG_FILE" 2>&1 \
      || warn "Worker bouncer install slow/failed (continuing)"
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
    # Strip chars the worker-bouncer config validator rejects (e.g. an apostrophe
    # in "Bob's Account") — otherwise its postinst FATALs, wedging dpkg + breaking
    # later apt installs. Allowed: letters digits space . _ - ( ) & + @ : ,
    account_name=$(printf '%s' "$account_name" | tr -cd 'A-Za-z0-9 ._()&+@:,-')
    # Sanitize account_name: the CrowdSec CF bouncer rejects characters outside
    # [A-Za-z0-9 ._-()&+@:,]. Cloudflare account names can contain apostrophes
    # (e.g. "user@gmail.com's Account") which crash its config parser with a
    # fatal error. Strip disallowed characters.
    account_name=$(printf '%s' "$account_name" | LC_ALL=C tr -cd 'A-Za-z0-9 ._,()&+@:-')
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
      account_name: "${account_name:-<CF_ACCOUNT_EMAIL>}"
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

  # Containers. NOTE: use an ARRAY -- IFS=$'\n\t' (set at top) means a plain
  # space-separated string would NOT word-split, so 'for c in $want' checked for a
  # single container named the whole string -> every run falsely "FAILED".
  local want=(traefik authentik-server netbird-server netbird-dashboard netbird-proxy dockhand crowdsec)
  local c
  for c in "${want[@]}"; do
    _check "container '$c' running" bash -c "docker ps --format '{{.Names}}' | grep -qx '$c'"
  done

  # Core service health
  _check "IP forwarding ON (Docker)" bash -c '[[ $(sysctl -n net.ipv4.ip_forward) == 1 ]]'
  _check "Traefik bound 443"          bash -c "ss -tln 2>/dev/null | grep -q ':443'"
  # Surface the cert state at deploy time. A WARN here = ACME couldn't validate:
  # DNS for netbird.<domain> isn't pointed at this host's PUBLIC IP yet, or inbound
  # 443 is blocked at the cloud firewall. (No host script can set your DNS.)
  _check "Public Let's Encrypt cert issued (else point DNS netbird.${DOMAIN} -> public IP)" bash -c \
    "echo | timeout 6 openssl s_client -connect 127.0.0.1:443 -servername 'netbird.${DOMAIN}' 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null | grep -qi \"let's encrypt\""
  _check "Authentik health OK" bash -c \
    "curl -sf --max-time 5 -o /dev/null http://127.0.0.1:9000/-/health/ready/"
  _check "netbird-proxy container running" bash -c \
    "docker ps --format '{{.Names}}' | grep -qx 'netbird-proxy'"

  _check "CrowdSec LAPI responding"   docker exec crowdsec cscli metrics
  _check "acquisition label is traefik" bash -c \
    "docker exec crowdsec cat /etc/crowdsec/acquis.d/traefik.yaml 2>/dev/null | grep -q 'type: traefik'"
  _check "traefik collection installed" bash -c \
    "docker exec crowdsec cscli collections list 2>/dev/null | grep -q crowdsecurity/traefik"
  _check "a firewall bouncer registered in LAPI" bash -c \
    "docker exec crowdsec cscli bouncers list 2>/dev/null | grep -qi bouncer"
  _check "http-cve collection installed" bash -c \
    "docker exec crowdsec cscli collections list 2>/dev/null | grep -q crowdsecurity/http-cve"
  _check "Cloudflare real-IP trustedIPs in Traefik" bash -c \
    "grep -q forwardedHeaders.trustedIPs '${STACK_DIR}/docker-compose.traefik.yml'"
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
  local ak_pass nb_pass
  ak_pass=$(_read_cred "${AUTHENTIK_DIR}/.akadmin_password")
  nb_pass=$(_read_cred "${NETBIRD_DIR}/.admin_password")

  printf "\n"
  printf "${C_B}${C_GRN}==============================================================================\n"
  printf "                          DEPLOYMENT COMPLETE\n"
  printf "==============================================================================${C_R}\n"
  printf "${C_B}  ${C_CYN}%s v%s${C_R}\n" "$SCRIPT_NAME" "$SCRIPT_VERSION"
  printf "${C_B}  Elapsed: ${C_CYN}%dm %ds${C_R}\n" $(( elapsed / 60 )) $(( elapsed % 60 ))
  printf "${C_B}==============================================================================${C_R}\n"

  cat << EOF

${C_B}Stack Directory${C_R}    ${STACK_DIR}

${C_B}${C_GRN}-- Traefik edge (single TLS terminator on 80/443) -----------${C_R}
netbird.${DOMAIN}              ->  netbird-dashboard + management(gRPC) + signal(gRPC)
authentik.${DOMAIN}            ->  authentik-server:9000
dockhand.${DOMAIN}             ->  dockhand:3000

${C_B}${C_GRN}-- NetBird reverse proxy (for future remote services) ----------${C_R}
  netbird-proxy is running and registered. To expose services on OTHER machines,
  install the NetBird client there as a peer, then add services via the dashboard
  (Reverse Proxy -> Services -> Add Service).

${C_B}Authentik (Identity Provider)${C_R}
  URL:       https://authentik.${DOMAIN}
  Admin:     akadmin
  Password:${C_YEL} ${ak_pass}${C_R}  (change after first login)
  Files:     ${AUTHENTIK_DIR}

${C_B}NetBird (self-hosted)${C_R}
  Dashboard: https://netbird.${DOMAIN}   (embedded IdP; admin auto-created by script)
  Admin:     ${NB_ADMIN_EMAIL:-admin@${DOMAIN}}
  Password:${C_YEL} ${nb_pass}${C_R}  (change after first login)
  Config:    ${NETBIRD_DIR}/config.yaml  (NetBird login = its own /oauth2)
  P2P ports: 3478/udp (STUN; relay rides the Traefik edge on /relay)
  Client:    install NetBird on a device; set management URL https://netbird.${DOMAIN}
  Ext IP:    ${ext_ip}
  Proxy:     netbird-proxy (reverse proxy engine; services auto-created for Dockhand + Authentik)

${C_B}Dockhand${C_R}
  URL:        https://dockhand.${DOMAIN}
  Auth:       Set in NetBird dashboard -> Reverse Proxy -> Services -> Dockhand -> Authentication
  Data:       ${DOCKHAND_DATA_DIR}
  Host Files: READ-ONLY mount under /host (see compose comment to enable writes)

${C_B}CrowdSec Console${C_R}
  URL:      https://app.crowdsec.net/
  Note:     Enrolled in the Console; if it failed: docker exec crowdsec cscli console enroll --auto
  Source:   parses Traefik JSON access logs (${TRAEFIK_LOG_DIR})

${C_B}Cloudflare Worker bouncer${C_R}
  Config:   /etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml
  Status:   $(systemctl is-active crowdsec-cloudflare-worker-bouncer 2>/dev/null || echo "not deployed (no token supplied)")
  Action:   ${CF_BOUNCER_ACTION} on banned IPs

${C_B}Firewall${C_R}  $(if [[ "$OS_FAMILY" == "debian" ]]; then echo "UFW"; else echo "firewalld"; fi)
${C_B}Docker${C_R}    $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo N/A)
${C_B}Network${C_R}   proxy (bridge)

${C_B}${C_YEL}Done automatically:${C_R}
  - Traefik edge on 80/443 with Let's Encrypt (HTTP-01 challenge)
  - Authentik IdP deployed (exposed via netbird-proxy, NOT Traefik)
  - NetBird combined server (mgmt/signal/relay/STUN) + dashboard behind the Traefik edge
  - NetBird admin user auto-created via setup API (credentials saved, see above)
  - NetBird reverse proxy (netbird-proxy) started + registered with management server
  - Reverse proxy services auto-created via API: Dockhand + Authentik (Direct Upstream)
  - CrowdSec parsing Traefik logs; bans enforced incl. Docker-published ports (DOCKER-USER)
  - Cloudflare real visitor IP trusted in Traefik (forwardedHeaders.trustedIPs)
  - Host filesystem mounted into Dockhand READ-ONLY

${C_B}${C_RED}STAGING NOTES (test before production):${C_R}
  - NetBird routing uses NetBird's OWN official Traefik labels (gRPC h2c handled
    upstream). If the dashboard cannot reach the API, compare the labels on
    netbird-server against your NetBird version:
    https://docs.netbird.io/selfhosted/external-reverse-proxy
  - NetBird login uses NetBird's EMBEDDED IdP (/oauth2). Admin user is
    auto-created by the script -- log in at https://netbird.<domain> with
    the credentials shown above.
  - Reverse proxy services are created with NO auth (public). Set SSO/password/PIN
    per-service in the NetBird dashboard before relying on them.
  - DNS: netbird.<domain> AND *.<domain> must point to this server's IP
    for the control plane + reverse proxy TLS certs to issue.

${C_B}${C_RED}REQUIRED -- OPEN INBOUND PORTS AT YOUR CLOUD FIREWALL${C_R} (security group / VCN / ACL)
  This script set the HOST firewall, but Docker-published ports BYPASS it, and your
  cloud provider's firewall sits IN FRONT of the VPS. It must allow inbound:
     80/tcp, 443/tcp   (NetBird dashboard + web apps; Let's Encrypt also needs 443)
     3478/udp          (NetBird STUN / NAT traversal)
     <your SSH port>/tcp
  Quick check ON the VPS:  curl -skI -m5 https://127.0.0.1 -H "Host: netbird.${DOMAIN}"
  If that responds but the site is unreachable from your browser, the block is the
  cloud firewall or DNS (netbird.${DOMAIN} -> this server's IP) -- not this script.

${C_B}${C_YEL}Cloudflare - finish in the dashboard (no public API for these):${C_R}
  1. Worker Route -> FAIL OPEN:  ${DOMAIN} > Workers Routes > the crowdsec route
  2. Managed WAF ruleset:        ${DOMAIN} > Security > WAF > Managed rules > enable
  3. Origin lockdown: re-run with LOCK_HTTP_TO_CLOUDFLARE=true to restrict 80/443 to CF

${C_B}${C_YEL}Credential files (root-only, mode 600):${C_R}
  ${AUTHENTIK_DIR}/.akadmin_password
  ${AUTHENTIK_DIR}/authentik.env
  ${NETBIRD_DIR}/.admin_password
  ${NETBIRD_DIR}/.api_token

${C_B}Troubleshooting:${C_R}
  Logs:    docker logs -f traefik   docker logs -f authentik-server   docker logs -f netbird-server
  Restart: cd ${STACK_DIR} && docker compose -f docker-compose.traefik.yml restart
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
  else warn "IP forwarding still off (=$ipf) - published ports 80/443 may be unreachable"; fi
}

main() {
  printf "\n${C_B}${C_CYN}VPS Deployment -- Traefik + Authentik (IdP) + NetBird (control plane + reverse proxy) + Dockhand + CrowdSec${C_R}\n" >&2
  printf "${C_DIM}${SCRIPT_NAME} v${SCRIPT_VERSION}${C_R}\n\n" >&2
  preflight_checks
  idempotent_cleanup
  system_update
  install_dependencies
  install_docker
  ensure_ip_forwarding
  setup_docker_network
  get_user_domain
  setup_stack            # Traefik edge + Authentik (IdP) + NetBird + CrowdSec + reverse proxy services
  setup_dockhand         # Dockhand on the proxy network (exposed via netbird-proxy)
  setup_firewall
  setup_crowdsec
  setup_cloudflare_realip
  setup_cloudflare_bouncer
  setup_crowdsec_console
  setup_logrotate
  register_dockhand_stacks
  verify_deployment
  DEPLOY_STATUS="success"
  print_summary
}

main "$@"
