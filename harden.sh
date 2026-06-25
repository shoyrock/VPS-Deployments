#!/usr/bin/env bash
# Auto-elevate to root if not already running as root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi
# VPS Security Hardening Script — standalone, idempotent, Debian + RHEL
# No third-party accounts, no Cloudflare, no registration required
set -euo pipefail
IFS=$'\n\t'

readonly LOGFILE="/var/log/harden.log"
readonly BAKSUF=".harden-backup-$(date +%Y%m%d-%H%M%S)"
readonly GEOIP_DIR="/usr/local/bin/geoip-block"
# NPM admin panel (port 81) exposure. DEFAULT 1 (locked down): dockerd publishes
# 81 on 0.0.0.0, BYPASSING UFW, so the only thing keeping the admin login off the
# internet is the cloud provider's security list. That is a single point of
# failure (and absent on providers without a cloud firewall) -> bind to localhost
# by default and reach it over an SSH tunnel.
#   1 = bind to 127.0.0.1:81   -> admin reachable ONLY via SSH tunnel (default, most secure):
#       ssh -L 8181:127.0.0.1:81 root@<vps-ip>  then open http://localhost:8181
#   0 = publish on 0.0.0.0:81  -> reachable at http://<vps-ip>:81 (convenient but the
#       login faces the internet unless a cloud firewall blocks 81; set a STRONG password).
# Override per run, e.g.:  LOCKDOWN_NPM_ADMIN=0 bash harden.sh
LOCKDOWN_NPM_ADMIN="${LOCKDOWN_NPM_ADMIN:-1}"
# GeoIP allowlist (harden_geoip): default-DENY — block ALL countries except the
# ones you allow. Gates 443 (web, via DOCKER-USER since NPM is a container) and,
# by default, 22 (SSH, via INPUT). Port 80 stays OPEN so Let's Encrypt HTTP-01
# keeps working. Overrides:
#   GEOIP_ALLOW="us,ca,gb"   non-interactive: skip the continent menu entirely.
#   GEOIP_GATE_SSH=0         do NOT geo-gate SSH (port 22). Default 1 (gate it).
GEOIP_GATE_SSH="${GEOIP_GATE_SSH:-1}"
# Colors (TTY only)
if [[ -t 1 ]]; then
  readonly C_RST='\033[0m' C_BLD='\033[1m' C_GRN='\033[1;32m'
  readonly C_YLW='\033[1;33m' C_RED='\033[1;31m' C_BLU='\033[1;34m'
else
  readonly C_RST='' C_BLD='' C_GRN='' C_YLW='' C_RED='' C_BLU=''
fi

get_external_ip() {
  curl -s -4 --max-time 10 https://api.ipify.org 2>/dev/null || \
  curl -s -4 --max-time 10 https://ifconfig.me 2>/dev/null || \
  curl -s -4 --max-time 10 https://icanhazip.com 2>/dev/null || \
  echo "unknown"
}

OS_FAMILY="" PKG_MANAGER="" PKG_INSTALL=""
# Install wrapper. The global IFS=$'\n\t' means an unquoted "$PKG_INSTALL" (which
# holds SPACES, e.g. "apt-get install -y -qq") would NOT word-split, so bash tried
# to exec the whole string as ONE command -> "apt-get install -y -qq: command not
# found", silently failing every package install on a fresh box. Reset IFS locally
# so it splits into argv, then append the package(s).
_pkg() { local IFS=$' \t\n'; $PKG_INSTALL "$@"; }

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_log()   { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOGFILE" || true; }
info()   { printf "${C_BLU}[INFO]${C_RST}  %s\n" "$*"; _log "INFO: $*"; }
warn()   { printf "${C_YLW}[WARN]${C_RST}  %s\n" "$*"; _log "WARN: $*"; }
ok()     { printf "${C_GRN}[OK]${C_RST}    %s\n" "$*"; _log "OK: $*"; }
error()  { printf "${C_RED}[ERR]${C_RST}   %s\n" "$*" >&2; _log "ERR: $*"; }

# ---------------------------------------------------------------------------
# Pre-flight: root check + OS detection
# ---------------------------------------------------------------------------
preflight() {
    info "=== Pre-flight checks ==="
    [[ $EUID -eq 0 ]] || { error "Must run as root. Use: sudo bash $0"; exit 1; }
    ok "Running as root"

    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        case "$ID" in
            ubuntu|debian|linuxmint|pop)
                OS_FAMILY="debian"; PKG_MANAGER="apt-get"
                PKG_INSTALL="apt-get install -y -qq" ;;
            rhel|centos|rocky|almalinux|fedora|ol|amzn)
                OS_FAMILY="rhel"
                if command -v dnf &>/dev/null; then
                    PKG_MANAGER="dnf"; PKG_INSTALL="dnf install -y -q"
                else
                    PKG_MANAGER="yum"; PKG_INSTALL="yum install -y -q"
                fi ;;
            *) error "Unsupported OS: $ID"; exit 1 ;;
        esac
        ok "OS family: ${C_BLD}${OS_FAMILY}${C_RST} (${ID})"
    else
        error "/etc/os-release not found"; exit 1
    fi

    # ---------------------------------------------------------------------------
    # Detect if deployment scripts have been run first
    # ---------------------------------------------------------------------------
    local deployed=false
    for d in /opt/apps/dockhand-stack /opt/dockhand-stack /opt/portainer-stack /opt/dockge-stack /opt/cosmos-stack /opt/coolify-stack /opt/dokploy-stack /opt/casaos-stack /opt/runtipi-stack /opt/yunohost-stack /opt/freedombox-stack /opt/netbird-stack; do
        [[ -d "$d" ]] && deployed=true && break
    done
    command -v docker &>/dev/null && docker ps --format '{{.Names}}' 2>/dev/null | grep -E 'npm|portainer|dockge|coolify|dockhand|cosmos|dokploy|casaos|runtipi|yunohost|freedombox|netbird-server|traefik|authentik' >/dev/null 2>&1 && deployed=true

    if [[ "$deployed" == false ]]; then
        echo ""
        warn "No deployment detected. Have you run a deploy script first?"
        printf "  ${C_YLW}harden.sh should be run AFTER deploying your tool.${C_RST}\n"
        printf "  ${C_YLW}It manages the NPM admin port (81) binding — you'll need NPM set up first.${C_RST}\n"
        printf "  ${C_BLU}Run: ./deploy.sh  → pick a tool  → then run: ./deploy.sh harden${C_RST}\n"
        echo ""
        read -rp "Continue anyway? [y/N]: " force
        [[ "$force" =~ ^[Yy]$ ]] || { info "Aborted. Deploy first, then harden."; exit 0; }
    fi

    mkdir -p "$(dirname "$LOGFILE")" && touch "$LOGFILE" 2>/dev/null || { error "Cannot write $LOGFILE"; exit 1; }
    if [[ "$OS_FAMILY" == "debian" ]]; then
        # Fresh boots run apt-daily/unattended-upgrades which hold the dpkg lock and
        # make apt-get exit 100. Stop them + set a global lock timeout so every apt
        # WAITS for the lock (the deploy sets this too; harden may run standalone).
        systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
        printf 'DPkg::Lock::Timeout "300";\n' > /etc/apt/apt.conf.d/99deploy-lock-timeout 2>/dev/null || true
        apt-get update -qq >> "$LOGFILE" 2>&1
    fi
    for t in curl wget sed awk; do
        command -v "$t" &>/dev/null && continue
        info "Installing: $t"; _pkg "$t" >> "$LOGFILE" 2>&1 || warn "Failed to install $t"
    done
    ok "Pre-flight complete"
}

# ---------------------------------------------------------------------------
# User confirmation
# ---------------------------------------------------------------------------
user_confirm() {
    echo ""; printf "${C_BLD}${C_YLW}VPS Security Hardening${C_RST}\n"
    printf "  OS: %s | Backup suffix: %s\n" "$OS_FAMILY" "$BAKSUF"
    printf "  Log: %s\n\n" "$LOGFILE"
    printf "Measures:\n"
    printf "  Kernel sysctl         Firewall rate limit   GeoIP allowlist (deny-all)\n"
    printf "  CrowdSec (local)      AIDE file integrity   Auto security updates\n"
    printf "  NPM admin port (81)   Docker hardening      Daily local backups\n"
    printf "  SSH daemon hardening  (key-only root, password auth off if key present)\n\n"
    read -rp $'Proceed? [y/N]: ' ans
    [[ "$ans" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }
    ok "Confirmed — hardening..."
}

# ---------------------------------------------------------------------------
# Backup utility
# ---------------------------------------------------------------------------
backup_file() {
    local f="$1"
    [[ -f "$f" && ! -f "${f}${BAKSUF}" ]] && cp -a "$f" "${f}${BAKSUF}" 2>/dev/null && _log "Backup: ${f} -> ${f}${BAKSUF}"
    return 0   # best-effort: never let an absent file abort the caller under 'set -e'
}

backup_configs() {
    info "=== Backing up configs ==="
    local f
    for f in /etc/sysctl.conf /etc/ufw/before.rules \
             /etc/ufw/ufw.conf /etc/docker/daemon.json /etc/ssh/sshd_config \
             /etc/apt/apt.conf.d/50unattended-upgrades /etc/dnf/automatic.conf; do
        [[ -f "$f" ]] && backup_file "$f"
    done
    ok "Backups complete"
}

# ---------------------------------------------------------------------------
# 1. Sysctl Kernel Hardening — rollback: rm /etc/sysctl.d/99-harden.conf
# ---------------------------------------------------------------------------
harden_sysctl() {
    info "=== Applying kernel sysctl hardening ==="
    backup_file /etc/sysctl.conf || true
    mkdir -p /etc/sysctl.d || true
    {
        # MUST be 1 on a Docker host — Docker routes host→container traffic through
        # IP forwarding. Setting this to 0 breaks ALL container networking (NPM and
        # every published port become unreachable), and persists across reboots.
        echo "net.ipv4.ip_forward=1"
        echo "net.ipv4.conf.all.send_redirects=0"
        echo "net.ipv4.conf.default.send_redirects=0"
        echo "net.ipv4.conf.all.accept_redirects=0"
        echo "net.ipv4.conf.default.accept_redirects=0"
        echo "net.ipv4.conf.all.accept_source_route=0"
        echo "net.ipv4.conf.default.accept_source_route=0"
        echo "net.ipv4.conf.all.log_martians=1"
        echo "net.ipv4.conf.default.log_martians=1"
        echo "net.ipv4.conf.all.rp_filter=1"
        echo "net.ipv4.conf.default.rp_filter=1"
        echo "net.ipv4.tcp_syncookies=1"
        echo "net.ipv4.tcp_timestamps=0"
        echo "net.ipv4.tcp_max_syn_backlog=2048"
        echo "net.ipv4.tcp_synack_retries=2"
        echo "net.ipv4.tcp_syn_retries=2"
        echo "net.ipv4.tcp_fin_timeout=10"
        echo "net.ipv4.tcp_keepalive_time=300"
        echo "net.ipv4.tcp_keepalive_probes=5"
        echo "net.ipv4.tcp_keepalive_intvl=15"
        echo "net.ipv4.icmp_echo_ignore_broadcasts=1"
        echo "net.ipv4.icmp_ignore_bogus_error_responses=1"
        echo "kernel.randomize_va_space=2"
        echo "kernel.kptr_restrict=2"
        echo "kernel.yama.ptrace_scope=1"
        echo "fs.suid_dumpable=0"
        echo "kernel.core_uses_pid=1"
        echo "kernel.sysrq=0"
    } > /etc/sysctl.d/99-harden.conf || { warn "Failed to write sysctl config"; return; }
    sysctl --system >> "$LOGFILE" 2>&1 || warn "sysctl had errors (non-fatal)"
    ok "Kernel sysctl hardening applied"
    _log "sysctl hardening applied"
}

# ---------------------------------------------------------------------------
# Discover the host ports the CURRENT deployment actually needs: every port a
# running container publishes on a PUBLIC host IP (0.0.0.0 / ::). Ports bound to
# 127.0.0.1 are intentionally skipped (localhost-only; e.g. CrowdSec LAPI 8080,
# Authentik 9000). Emits unique "PORT/PROTO" lines (e.g. 443/tcp, 3478/udp).
# This auto-adapts per platform: NetBird -> 80,443,3478/udp,51820/udp ;
# NPM stacks -> 80,443,81 ; etc. No hardcoded per-platform list to drift.
# ---------------------------------------------------------------------------
collect_public_ports() {
    command -v docker &>/dev/null || return 0
    local cid
    docker ps -q 2>/dev/null | while read -r cid; do
        docker inspect --format \
          '{{range $p, $b := .NetworkSettings.Ports}}{{range $b}}{{.HostIp}}|{{$p}}{{println}}{{end}}{{end}}' \
          "$cid" 2>/dev/null
    done | awk -F'|' '($1=="0.0.0.0" || $1=="::" || $1=="") && $2!="" {print $2}' | sort -u
}

# ---------------------------------------------------------------------------
# 3. Firewall — opens ONLY the ports the deployed stack publishes (+ SSH).
#    Rollback: ufw reset / remove firewalld rules
# ---------------------------------------------------------------------------
harden_firewall() {
    info "=== Configuring firewall (only ports your deployment publishes) ==="
    local -a pub=()
    mapfile -t pub < <(collect_public_ports)
    if [[ ${#pub[@]} -eq 0 ]]; then
        warn "No public container ports detected (deploy not run yet?) — opening 80/443 as a fallback"
        pub=(80/tcp 443/tcp)
    fi
    info "Allowing: 22/tcp (SSH) + ${pub[*]}"

    local p
    if [[ "$OS_FAMILY" == "debian" ]]; then
        command -v ufw &>/dev/null || { info "Installing UFW"; _pkg ufw >> "$LOGFILE" 2>&1; }
        # NOTE: Docker publishes container ports straight into the DOCKER iptables
        # chain, BYPASSING UFW INPUT. These rules document intent + protect host-bound
        # services; CrowdSec's firewall bouncer (DOCKER-USER chain) is the real
        # enforcement for container-published ports. The SSH (22) limit IS effective
        # because sshd runs on the host.
        if ufw status 2>/dev/null | grep -q 'Status: active'; then
            warn "UFW already active — 'ufw --force reset' will WIPE existing rules"
            _log "Existing UFW rules before reset:"; ufw status numbered >> "$LOGFILE" 2>&1 || true
        fi
        ufw --force reset >> "$LOGFILE" 2>&1 || true
        ufw default deny incoming  >> "$LOGFILE" 2>&1 || true
        ufw default allow outgoing >> "$LOGFILE" 2>&1 || true
        ufw limit 22/tcp comment 'SSH rate limit' >> "$LOGFILE" 2>&1 || true
        for p in "${pub[@]}"; do
            case "$p" in
                80/tcp|443/tcp) ufw limit "$p" comment 'web (host only; Docker bypasses UFW)' >> "$LOGFILE" 2>&1 || true ;;
                *)              ufw allow "$p" comment 'deployment port'                       >> "$LOGFILE" 2>&1 || true ;;
            esac
        done
        ufw --force enable >> "$LOGFILE" 2>&1 || true
        ok "UFW configured (SSH + ${pub[*]})"
    else
        systemctl is-active --quiet firewalld 2>/dev/null || { _pkg firewalld >> "$LOGFILE" 2>&1; systemctl enable --now firewalld >> "$LOGFILE" 2>&1; }
        firewall-cmd --permanent --add-rich-rule='rule service name=ssh limit value=6/m accept' >> "$LOGFILE" 2>&1 || true
        firewall-cmd --permanent --add-service=ssh >> "$LOGFILE" 2>&1 || true
        for p in "${pub[@]}"; do
            firewall-cmd --permanent --add-port="$p" >> "$LOGFILE" 2>&1 || true
            case "$p" in
                80/tcp)  firewall-cmd --permanent --add-rich-rule='rule service name=http  limit value=30/m accept' >> "$LOGFILE" 2>&1 || true ;;
                443/tcp) firewall-cmd --permanent --add-rich-rule='rule service name=https limit value=30/m accept' >> "$LOGFILE" 2>&1 || true ;;
            esac
        done
        firewall-cmd --reload >> "$LOGFILE" 2>&1 || true
        ok "Firewalld configured (SSH + ${pub[*]})"
    fi
    _log "Firewall configured: 22/tcp ${pub[*]}"
}

# ---------------------------------------------------------------------------
# 4. GeoIP ALLOWLIST (default-deny; free ipdeny.com lists) — rollback:
#    GEOIP_DISABLE=1 bash $GEOIP_DIR/apply-geoip.sh ; rm -rf $GEOIP_DIR
#    Blocks ALL countries except the ones you select. Gates 443 (web — filtered
#    in DOCKER-USER because NPM is a container and bypasses INPUT) and, by
#    default, 22 (SSH — INPUT). Port 80 is LEFT OPEN so Let's Encrypt HTTP-01
#    validation (arrives from many countries) keeps working; 80 only serves the
#    ACME challenge + a 301 redirect, no app content. Always-allowed carve-outs:
#    established conns, loopback, RFC1918/docker nets, Cloudflare edge ranges.
#    Set GEOIP_ALLOW="us,ca,gb" to skip the menu.
# ---------------------------------------------------------------------------

# ------- country data: single source of truth (code | continent# | Name) -----
# Continents: 1 North America  2 South America  3 Europe  4 Asia  5 Africa  6 Oceania
# (codes are ipdeny.com zone filenames). Both the menu and the name lookups are
# derived from this one table, so there is no drift between them.
geoip_country_table() {
    cat <<'TBL'
us|1|United States
ca|1|Canada
mx|1|Mexico
gt|1|Guatemala
bz|1|Belize
sv|1|El Salvador
hn|1|Honduras
ni|1|Nicaragua
cr|1|Costa Rica
pa|1|Panama
bs|1|Bahamas
cu|1|Cuba
jm|1|Jamaica
ht|1|Haiti
do|1|Dominican Republic
tt|1|Trinidad and Tobago
bb|1|Barbados
pr|1|Puerto Rico
gl|1|Greenland
bm|1|Bermuda
ag|1|Antigua and Barbuda
dm|1|Dominica
gd|1|Grenada
kn|1|Saint Kitts and Nevis
lc|1|Saint Lucia
vc|1|Saint Vincent and the Grenadines
br|2|Brazil
ar|2|Argentina
cl|2|Chile
co|2|Colombia
pe|2|Peru
ve|2|Venezuela
ec|2|Ecuador
bo|2|Bolivia
py|2|Paraguay
uy|2|Uruguay
gy|2|Guyana
sr|2|Suriname
gb|3|United Kingdom
ie|3|Ireland
fr|3|France
de|3|Germany
es|3|Spain
pt|3|Portugal
it|3|Italy
nl|3|Netherlands
be|3|Belgium
lu|3|Luxembourg
ch|3|Switzerland
at|3|Austria
dk|3|Denmark
se|3|Sweden
no|3|Norway
fi|3|Finland
is|3|Iceland
pl|3|Poland
cz|3|Czechia
sk|3|Slovakia
hu|3|Hungary
ro|3|Romania
bg|3|Bulgaria
gr|3|Greece
hr|3|Croatia
si|3|Slovenia
rs|3|Serbia
ba|3|Bosnia and Herzegovina
me|3|Montenegro
mk|3|North Macedonia
al|3|Albania
ee|3|Estonia
lv|3|Latvia
lt|3|Lithuania
ua|3|Ukraine
by|3|Belarus
md|3|Moldova
cy|3|Cyprus
mt|3|Malta
li|3|Liechtenstein
mc|3|Monaco
ad|3|Andorra
sm|3|San Marino
ru|3|Russia
cn|4|China
jp|4|Japan
kr|4|South Korea
kp|4|North Korea
in|4|India
pk|4|Pakistan
bd|4|Bangladesh
lk|4|Sri Lanka
np|4|Nepal
bt|4|Bhutan
mv|4|Maldives
mm|4|Myanmar
th|4|Thailand
vn|4|Vietnam
la|4|Laos
kh|4|Cambodia
my|4|Malaysia
sg|4|Singapore
id|4|Indonesia
ph|4|Philippines
bn|4|Brunei
mn|4|Mongolia
kz|4|Kazakhstan
uz|4|Uzbekistan
tm|4|Turkmenistan
tj|4|Tajikistan
kg|4|Kyrgyzstan
af|4|Afghanistan
ir|4|Iran
iq|4|Iraq
sa|4|Saudi Arabia
ae|4|United Arab Emirates
qa|4|Qatar
bh|4|Bahrain
kw|4|Kuwait
om|4|Oman
ye|4|Yemen
jo|4|Jordan
il|4|Israel
lb|4|Lebanon
sy|4|Syria
tr|4|Turkey
ge|4|Georgia
am|4|Armenia
az|4|Azerbaijan
hk|4|Hong Kong
tw|4|Taiwan
za|5|South Africa
eg|5|Egypt
ng|5|Nigeria
ke|5|Kenya
gh|5|Ghana
et|5|Ethiopia
tz|5|Tanzania
ug|5|Uganda
dz|5|Algeria
ma|5|Morocco
tn|5|Tunisia
ly|5|Libya
sd|5|Sudan
sn|5|Senegal
ci|5|Ivory Coast
cm|5|Cameroon
ao|5|Angola
mz|5|Mozambique
zm|5|Zambia
zw|5|Zimbabwe
bw|5|Botswana
na|5|Namibia
mw|5|Malawi
rw|5|Rwanda
so|5|Somalia
cd|5|DR Congo
cg|5|Congo
ga|5|Gabon
ml|5|Mali
bf|5|Burkina Faso
ne|5|Niger
td|5|Chad
mr|5|Mauritania
gm|5|Gambia
gw|5|Guinea-Bissau
sl|5|Sierra Leone
lr|5|Liberia
tg|5|Togo
bj|5|Benin
mg|5|Madagascar
mu|5|Mauritius
au|6|Australia
nz|6|New Zealand
pg|6|Papua New Guinea
fj|6|Fiji
sb|6|Solomon Islands
vu|6|Vanuatu
nc|6|New Caledonia
pf|6|French Polynesia
ws|6|Samoa
to|6|Tonga
ki|6|Kiribati
fm|6|Micronesia
mh|6|Marshall Islands
nr|6|Nauru
pw|6|Palau
tv|6|Tuvalu
TBL
}

geoip_continent_name() {
    case "$1" in
        1) echo "North America" ;; 2) echo "South America" ;; 3) echo "Europe" ;;
        4) echo "Asia" ;; 5) echo "Africa" ;; 6) echo "Oceania" ;; *) echo "?" ;;
    esac
}
# Space-separated iso2 codes belonging to continent $1.
geoip_continent_codes() { geoip_country_table | awk -F'|' -v k="$1" '$2==k{printf "%s ",$1}'; }
# Human name for one iso2 code (empty if unknown).
geoip_name() { geoip_country_table | awk -F'|' -v c="$1" '$1==c{print $3; exit}'; }
# Continent number for one iso2 code (empty if unknown).
geoip_continent_of() { geoip_country_table | awk -F'|' -v c="$1" '$1==c{print $2; exit}'; }
# Map a list of codes -> "Name, Name, Name" (falls back to the code if unknown).
geoip_names() {
    local IFS=$' \t\n' out="" c nm
    for c in $1; do nm=$(geoip_name "$c"); [[ -z "$nm" ]] && nm="$c"; out+=", $nm"; done
    printf '%s' "${out#, }"
}

# Best-effort: the IP of the admin running THIS session, so we can pre-allow the
# country you're connecting from. sudo (auto-elevate) wipes SSH_* env, so fall
# back to utmp (who) and the live :22 socket (ss).
geoip_client_ip() {
    local ip=""
    [[ -n "${SSH_CONNECTION:-}" ]] && ip="${SSH_CONNECTION%% *}"
    [[ -z "$ip" ]] && ip=$(who am i 2>/dev/null | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -1)
    [[ -z "$ip" ]] && ip=$(who      2>/dev/null | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -1)
    [[ -z "$ip" ]] && ip=$(ss -tnH 2>/dev/null | awk '$1=="ESTAB" && $4 ~ /:22$/ {print $5}' | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -1)
    printf '%s' "$ip"
}
# ISO2 country of an IP via ipapi.co (best effort; empty on failure/private IP).
geoip_country_of_ip() {
    [[ -z "${1:-}" ]] && return 0
    curl -fsSL --max-time 8 "https://ipapi.co/${1}/country/" 2>/dev/null | tr 'A-Z' 'a-z' | grep -E '^[a-z]{2}$' || true
}

# Build the allowed-country list into global GEOIP_SELECTED (space-sep iso2).
# GEOIP_MYCC (set by harden_geoip) = the country you're connecting from.
geoip_select_countries() {
    local IFS=$' \t\n'
    GEOIP_SELECTED=""
    # Non-interactive override (mirrors the CF_API_TOKEN env pattern).
    if [[ -n "${GEOIP_ALLOW:-}" ]]; then
        GEOIP_SELECTED=$(printf '%s' "$GEOIP_ALLOW" | tr 'A-Z,;' 'a-z  ' | tr -s ' ' | sed 's/^ //;s/ $//') || GEOIP_SELECTED=""
        info "GEOIP_ALLOW set — allowing: $(geoip_names "$GEOIP_SELECTED")"
        return
    fi
    if [[ ! -t 0 ]]; then
        warn "No TTY and GEOIP_ALLOW unset — skipping GeoIP allowlist (a default-deny with no list would block everything)"
        return
    fi

    # Pre-allow the country (and offer the whole region) you're connecting from.
    local seedcc="${GEOIP_MYCC:-}" seedcont=""
    if [[ -n "$seedcc" ]]; then
        seedcont=$(geoip_continent_of "$seedcc")
        GEOIP_SELECTED=" $seedcc"
        printf "\n${C_GRN}Detected your connection from: %s (%s) — pre-allowed.${C_RST}\n" "$(geoip_name "$seedcc")" "$seedcc"
        if [[ -n "$seedcont" ]]; then
            local regans
            read -rp "Allow your whole region ($(geoip_continent_name "$seedcont")) too? [Y/n]: " regans
            [[ "$regans" =~ ^[Nn]$ ]] || GEOIP_SELECTED+=" $(geoip_continent_codes "$seedcont")"
        fi
    fi

    printf "\n${C_BLD}GeoIP allowlist — block ALL countries except the ones you allow.${C_RST}\n"
    printf "Choose more continents to add countries from (or just confirm at the end):\n\n"
    local i star
    for i in 1 2 3 4 5 6; do
        star=""; [[ -n "$seedcont" && "$i" == "$seedcont" ]] && star="   ${C_GRN}<- your region${C_RST}"
        printf "  %s) %s%b\n" "$i" "$(geoip_continent_name "$i")" "$star"
    done
    printf "\n"
    local picks
    read -rp "Continents to choose from (e.g. 1 3; blank to skip): " picks
    picks=$(printf '%s' "$picks" | tr ',' ' ')

    local p codes ans n code sel idx
    local -a arr
    for p in $picks; do
        codes=$(geoip_continent_codes "$p")
        [[ -z "${codes// /}" ]] && { warn "Skipping invalid choice: $p"; continue; }
        read -ra arr <<< "$codes"
        printf "\n${C_BLD}%s${C_RST} (%s countries)\n" "$(geoip_continent_name "$p")" "${#arr[@]}"
        read -rp "Allow ALL of $(geoip_continent_name "$p")? [Y/n]: " ans
        if [[ "$ans" =~ ^[Nn]$ ]]; then
            n=1
            for code in "${arr[@]}"; do printf "  %2s) %s\n" "$n" "$(geoip_name "$code")"; n=$((n+1)); done
            read -rp "  Numbers to ALLOW (e.g. 1 5 9): " sel
            sel=$(printf '%s' "$sel" | tr ',' ' ')
            for idx in $sel; do
                [[ "$idx" =~ ^[0-9]+$ ]] || continue
                code="${arr[$((idx-1))]:-}"
                [[ -n "$code" ]] && GEOIP_SELECTED+=" $code"
            done
        else
            GEOIP_SELECTED+=" $codes"
        fi
    done

    # Escape hatch: extra countries anywhere, typed by NAME (or code).
    local extra tok mc
    local -a extra_arr
    read -rp $'\nExtra countries by NAME (e.g. Japan, Australia) or blank: ' extra
    if [[ -n "${extra// /}" ]]; then
        IFS=',' read -ra extra_arr <<< "$extra"
        for tok in "${extra_arr[@]}"; do
            tok=$(printf '%s' "$tok" | sed 's/^ *//;s/ *$//' | tr 'A-Z' 'a-z')
            [[ -z "$tok" ]] && continue
            if [[ "$tok" =~ ^[a-z]{2}$ && -n "$(geoip_name "$tok")" ]]; then GEOIP_SELECTED+=" $tok"; continue; fi
            mc=$(geoip_country_table | awk -F'|' -v n="$tok" 'tolower($3)==n{print $1; exit}')
            [[ -z "$mc" ]] && mc=$(geoip_country_table | awk -F'|' -v n="$tok" 'index(tolower($3),n)>0{print $1; exit}')
            if [[ -n "$mc" ]]; then GEOIP_SELECTED+=" $mc"; else warn "  No match for '$tok' — skipped"; fi
        done
    fi

    # Dedupe + keep only valid 2-letter codes.
    GEOIP_SELECTED=$(printf '%s\n' $GEOIP_SELECTED | grep -E '^[a-z]{2}$' | sort -u | tr '\n' ' ' | sed 's/ $//') || GEOIP_SELECTED=""

    # Final review (by name) + explicit confirm.
    printf "\n${C_BLD}Final allow-list (%s countries):${C_RST}\n  %s\n" "$(printf '%s' "$GEOIP_SELECTED" | wc -w)" "$(geoip_names "$GEOIP_SELECTED")"
    local conf
    read -rp "Apply this allowlist? [y/N]: " conf
    [[ "$conf" =~ ^[Yy]$ ]] || { warn "Allowlist not confirmed — GeoIP will be disabled."; GEOIP_SELECTED=""; }
}

harden_geoip() {
    local IFS=$' \t\n'
    info "=== Setting up GeoIP allowlist (default-deny) ==="
    mkdir -p "$GEOIP_DIR"

    # Detect the country THIS admin session connects from — used both to pre-allow
    # your region and for the lockout guard. The SSH gate filters by SOURCE IP, so
    # we check the CLIENT's country, NOT the box's hosting country.
    local GEOIP_MYIP GEOIP_MYCC
    GEOIP_MYIP=$(geoip_client_ip)
    GEOIP_MYCC=$(geoip_country_of_ip "$GEOIP_MYIP")

    geoip_select_countries
    if [[ -z "${GEOIP_SELECTED:-}" ]]; then
        warn "No countries selected — GeoIP allowlist DISABLED (nothing blocked). Removing any prior geo rules."
        [[ -x "${GEOIP_DIR}/apply-geoip.sh" ]] && GEOIP_DISABLE=1 bash "${GEOIP_DIR}/apply-geoip.sh" >> "$LOGFILE" 2>&1 || true
        (crontab -l 2>/dev/null | grep -vF "apply-geoip" || true) | crontab - 2>/dev/null || true
        return
    fi

    # Lockout guard: SSH (22) is geo-gated. If the country you're connecting from
    # is NOT in the list, applying this drops your NEXT SSH connection.
    if [[ -n "$GEOIP_MYCC" && " $GEOIP_SELECTED " != *" $GEOIP_MYCC "* ]]; then
        printf "\n${C_RED}${C_BLD}⚠️  LOCKOUT WARNING${C_RST}\n"
        printf "${C_RED}You're connecting from %s (%s / IP %s) — NOT in your allow list.${C_RST}\n" "$(geoip_name "$GEOIP_MYCC")" "$GEOIP_MYCC" "${GEOIP_MYIP:-unknown}"
        printf "${C_RED}SSH (22) is geo-gated, so applying this can lock YOU out. Recovery = your provider's web/serial console.${C_RST}\n"
        if [[ -t 0 ]]; then
            local sure
            read -rp "Type 'yes' to apply anyway, anything else to abort GeoIP: " sure
            [[ "$sure" == "yes" ]] || { warn "GeoIP allowlist aborted by user."; return; }
        else
            warn "Non-interactive: proceeding despite connecting-country mismatch (GEOIP_ALLOW set explicitly)."
        fi
    fi

    if ! command -v ipset &>/dev/null; then
        info "Installing ipset"
        [[ "$OS_FAMILY" == "debian" ]] && apt-get update -qq >> "$LOGFILE" 2>&1
        _pkg ipset >> "$LOGFILE" 2>&1 || { warn "ipset install failed — GeoIP allowlist requires ipset; skipping"; return; }
    fi

    # Write the apply script. The header carries the dynamic config; the body is
    # literal (refresh zones -> build sets -> install the default-deny gate).
    cat > "${GEOIP_DIR}/apply-geoip.sh" << GEOHEAD
#!/usr/bin/env bash
# GENERATED by harden.sh — GeoIP default-deny allowlist. Re-run to refresh.
COUNTRIES="${GEOIP_SELECTED}"
GATE_SSH="${GEOIP_GATE_SSH:-1}"
GEOHEAD
    cat >> "${GEOIP_DIR}/apply-geoip.sh" << 'GEOEOF'
DIR="/usr/local/bin/geoip-block"
ALLOW="geoip_allow" CFSET="geoip_cf" GATE="GEOIP_GATE" LOG="/var/log/harden.log"
ALLOW6="geoip_allow6" CFSET6="geoip_cf6" GATE6="GEOIP_GATE6"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') GeoIP: $*" >> "$LOG"; }

command -v iptables &>/dev/null || { log "iptables missing — skipping"; exit 0; }
command -v ipset    &>/dev/null || { log "ipset missing — skipping"; exit 0; }
# Dual-stack: enforce the SAME country allowlist over IPv6 via ip6tables, so a box
# with a public IPv6 address isn't a trivial geo-bypass (host SSH listens on [::]:22).
# Best-effort + fully guarded below; completely inert on v4-only hosts.
HAVE6=0; command -v ip6tables &>/dev/null && HAVE6=1

# Remove every geo rule/chain (fail-open). Sets are left intact unless disabling.
geo_teardown() {
    iptables -D INPUT       -p tcp --dport 443 -j "$GATE" 2>/dev/null || true
    iptables -D INPUT       -p tcp --dport 22  -j "$GATE" 2>/dev/null || true
    iptables -D DOCKER-USER -p tcp --dport 443 -j "$GATE" 2>/dev/null || true
    iptables -F "$GATE" 2>/dev/null || true
    iptables -X "$GATE" 2>/dev/null || true
    if [[ "$HAVE6" == "1" ]]; then
        ip6tables -D INPUT       -p tcp --dport 443 -j "$GATE6" 2>/dev/null || true
        ip6tables -D INPUT       -p tcp --dport 22  -j "$GATE6" 2>/dev/null || true
        ip6tables -D DOCKER-USER -p tcp --dport 443 -j "$GATE6" 2>/dev/null || true
        ip6tables -F "$GATE6" 2>/dev/null || true
        ip6tables -X "$GATE6" 2>/dev/null || true
    fi
}

# Disable mode: rip everything out and stop.
if [[ "${GEOIP_DISABLE:-0}" == "1" ]]; then
    geo_teardown
    ipset destroy "$ALLOW" 2>/dev/null || true
    ipset destroy "$CFSET" 2>/dev/null || true
    ipset destroy "$ALLOW6" 2>/dev/null || true
    ipset destroy "$CFSET6" 2>/dev/null || true
    log "disabled (all geo rules removed)"
    exit 0
fi

# Clean up the OLD blocklist model if a previous harden.sh left it behind.
iptables -D INPUT -m set --match-set geoip_block src -j DROP 2>/dev/null || true
ipset destroy geoip_block 2>/dev/null || true
iptables -D INPUT -j GEOIP_BLOCK 2>/dev/null || true
iptables -F GEOIP_BLOCK 2>/dev/null || true
iptables -X GEOIP_BLOCK 2>/dev/null || true

# Refresh country zones (keep the cached copy if a download fails). Prefer the
# AGGREGATED list (merged CIDRs — far fewer entries than the raw per-country
# list, which can exceed an ipset's element cap); fall back to the full list.
mkdir -p "$DIR"
for c in $COUNTRIES; do
    got=0
    for url in "aggregated/${c}-aggregated.zone" "countries/${c}.zone"; do
        if curl -fsSL --max-time 30 "https://www.ipdeny.com/ipblocks/data/${url}" -o "${DIR}/${c}.zone.tmp"; then
            mv "${DIR}/${c}.zone.tmp" "${DIR}/${c}.zone"; got=1; break
        fi
    done
    [[ "$got" -eq 0 ]] && { rm -f "${DIR}/${c}.zone.tmp"; log "zone download failed: $c (using cached copy if present)"; }
done

# Build the allow set atomically via a SINGLE ipset restore (one process — a
# per-line `ipset add` would fork tens of thousands of times for a big country).
build="${DIR}/.allow.restore"
{
    # maxelem well above any realistic multi-country allowlist (default 65536 is
    # too small — a single large country overflows it and the set silently truncates).
    echo "create ${ALLOW}_tmp hash:net hashsize 65536 maxelem 1048576 -exist"
    echo "flush ${ALLOW}_tmp"
    for c in $COUNTRIES; do
        [[ -f "${DIR}/${c}.zone" ]] || continue
        sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "${DIR}/${c}.zone" | sed "s#^#add ${ALLOW}_tmp #"
    done
} > "$build"
allow_n=$(grep -c '^add ' "$build" || true)
# SAFETY: never install a default-deny gate with an EMPTY allow set (= total lockout).
if [[ "$allow_n" -eq 0 ]]; then
    rm -f "$build"
    geo_teardown
    log "ERROR allow set empty — gate NOT applied (fail-open) to avoid lockout"
    exit 1
fi
ipset restore -exist < "$build"
rm -f "$build"
# Create the live set only if absent (a plain create -exist still errors when an
# older set has different header params; the swap below carries the new content).
ipset list -n "$ALLOW" &>/dev/null || ipset create "$ALLOW" hash:net hashsize 65536 maxelem 1048576
ipset swap "${ALLOW}_tmp" "$ALLOW"
ipset destroy "${ALLOW}_tmp" 2>/dev/null || true

# Build the Cloudflare carve-out set (best effort — so CF-proxied traffic, which
# reaches origin from CF POPs worldwide, is never geo-dropped).
ipset create "${CFSET}_tmp" hash:net -exist
ipset flush  "${CFSET}_tmp"
if curl -fsSL --max-time 15 https://www.cloudflare.com/ips-v4 -o /tmp/cf-v4.txt 2>/dev/null; then
    { echo "create ${CFSET}_tmp hash:net -exist"
      sed -e '/^[[:space:]]*$/d' /tmp/cf-v4.txt | sed "s#^#add ${CFSET}_tmp #"
    } | ipset restore -exist
    rm -f /tmp/cf-v4.txt
fi
ipset list -n "$CFSET" &>/dev/null || ipset create "$CFSET" hash:net
ipset swap "${CFSET}_tmp" "$CFSET"
ipset destroy "${CFSET}_tmp" 2>/dev/null || true

# (Re)build the gate chain. Every RETURN is an "allowed" exit; the final DROP is
# the default-deny. ESTABLISHED first so a live SSH session is never cut.
iptables -N "$GATE" 2>/dev/null || iptables -F "$GATE"
iptables -A "$GATE" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
iptables -A "$GATE" -i lo -j RETURN
iptables -A "$GATE" -s 127.0.0.0/8    -j RETURN
iptables -A "$GATE" -s 10.0.0.0/8     -j RETURN
iptables -A "$GATE" -s 172.16.0.0/12  -j RETURN
iptables -A "$GATE" -s 192.168.0.0/16 -j RETURN
iptables -A "$GATE" -m set --match-set "$CFSET" src -j RETURN
iptables -A "$GATE" -m set --match-set "$ALLOW" src -j RETURN
iptables -A "$GATE" -j DROP

# Hook the gate. Web 443: NPM is a container, so filter in DOCKER-USER (INPUT
# never sees forwarded container traffic). SSH 22: host service -> INPUT.
if iptables -L DOCKER-USER -n &>/dev/null; then
    iptables -C DOCKER-USER -p tcp --dport 443 -j "$GATE" 2>/dev/null || iptables -I DOCKER-USER -p tcp --dport 443 -j "$GATE"
fi
iptables -C INPUT -p tcp --dport 443 -j "$GATE" 2>/dev/null || iptables -I INPUT -p tcp --dport 443 -j "$GATE"
if [[ "$GATE_SSH" == "1" ]]; then
    iptables -C INPUT -p tcp --dport 22 -j "$GATE" 2>/dev/null || iptables -I INPUT -p tcp --dport 22 -j "$GATE"
else
    iptables -D INPUT -p tcp --dport 22 -j "$GATE" 2>/dev/null || true
fi

# ---------- IPv6 (dual-stack): mirror the allowlist via ip6tables ----------
# Fully guarded: if no v6 ranges build, IPv6 is left UNGATED (never lock). Only TCP
# 443/22 enter the chain, so ICMPv6/NDP/multicast are never touched. Carve-outs
# MUST include link-local (fe80::/10) + ULA (fc00::/7) or v6 would break.
if [[ "$HAVE6" == "1" ]]; then
    for c in $COUNTRIES; do
        got6=0
        for url in "ipv6/ipaddresses/aggregated/${c}-aggregated.zone" "ipv6/ipaddresses/${c}.zone"; do
            if curl -fsSL --max-time 30 "https://www.ipdeny.com/${url}" -o "${DIR}/${c}.v6.zone.tmp"; then
                mv "${DIR}/${c}.v6.zone.tmp" "${DIR}/${c}.v6.zone"; got6=1; break
            fi
        done
        [[ "$got6" -eq 0 ]] && rm -f "${DIR}/${c}.v6.zone.tmp"
    done
    build6="${DIR}/.allow6.restore"
    {
        echo "create ${ALLOW6}_tmp hash:net family inet6 hashsize 16384 maxelem 1048576 -exist"
        echo "flush ${ALLOW6}_tmp"
        for c in $COUNTRIES; do
            [[ -f "${DIR}/${c}.v6.zone" ]] || continue
            sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "${DIR}/${c}.v6.zone" | sed "s#^#add ${ALLOW6}_tmp #"
        done
    } > "$build6"
    allow6_n=$(grep -c '^add ' "$build6" || true)
    if [[ "$allow6_n" -gt 0 ]]; then
        ipset restore -exist < "$build6"
        ipset list -n "$ALLOW6" &>/dev/null || ipset create "$ALLOW6" hash:net family inet6 hashsize 16384 maxelem 1048576
        ipset swap "${ALLOW6}_tmp" "$ALLOW6"
        ipset destroy "${ALLOW6}_tmp" 2>/dev/null || true
        # Cloudflare IPv6 carve-out
        ipset create "${CFSET6}_tmp" hash:net family inet6 -exist; ipset flush "${CFSET6}_tmp"
        if curl -fsSL --max-time 15 https://www.cloudflare.com/ips-v6 -o /tmp/cf-v6.txt 2>/dev/null; then
            { echo "create ${CFSET6}_tmp hash:net family inet6 -exist"
              sed -e '/^[[:space:]]*$/d' /tmp/cf-v6.txt | sed "s#^#add ${CFSET6}_tmp #"
            } | ipset restore -exist
            rm -f /tmp/cf-v6.txt
        fi
        ipset list -n "$CFSET6" &>/dev/null || ipset create "$CFSET6" hash:net family inet6
        ipset swap "${CFSET6}_tmp" "$CFSET6"
        ipset destroy "${CFSET6}_tmp" 2>/dev/null || true
        ip6tables -N "$GATE6" 2>/dev/null || ip6tables -F "$GATE6"
        ip6tables -A "$GATE6" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
        ip6tables -A "$GATE6" -i lo -j RETURN
        ip6tables -A "$GATE6" -s ::1/128   -j RETURN
        ip6tables -A "$GATE6" -s fe80::/10 -j RETURN
        ip6tables -A "$GATE6" -s fc00::/7  -j RETURN
        ip6tables -A "$GATE6" -m set --match-set "$CFSET6" src -j RETURN
        ip6tables -A "$GATE6" -m set --match-set "$ALLOW6" src -j RETURN
        ip6tables -A "$GATE6" -j DROP
        if ip6tables -L DOCKER-USER -n &>/dev/null; then
            ip6tables -C DOCKER-USER -p tcp --dport 443 -j "$GATE6" 2>/dev/null || ip6tables -I DOCKER-USER -p tcp --dport 443 -j "$GATE6"
        fi
        ip6tables -C INPUT -p tcp --dport 443 -j "$GATE6" 2>/dev/null || ip6tables -I INPUT -p tcp --dport 443 -j "$GATE6"
        if [[ "$GATE_SSH" == "1" ]]; then
            ip6tables -C INPUT -p tcp --dport 22 -j "$GATE6" 2>/dev/null || ip6tables -I INPUT -p tcp --dport 22 -j "$GATE6"
        else
            ip6tables -D INPUT -p tcp --dport 22 -j "$GATE6" 2>/dev/null || true
        fi
        log "IPv6 gate applied — ${allow6_n} v6 subnets"
    else
        # No v6 ranges -> leave IPv6 UNGATED (fail-open). Strip any stale v6 gate so
        # we never DROP against an empty set.
        ip6tables -D INPUT -p tcp --dport 443 -j "$GATE6" 2>/dev/null || true
        ip6tables -D INPUT -p tcp --dport 22  -j "$GATE6" 2>/dev/null || true
        ip6tables -D DOCKER-USER -p tcp --dport 443 -j "$GATE6" 2>/dev/null || true
        ip6tables -F "$GATE6" 2>/dev/null || true
        log "IPv6 zones unavailable — IPv6 left ungated (v4 enforced)"
    fi
    rm -f "$build6"
fi

log "applied — ${allow_n} allowed subnets, SSH gate=${GATE_SSH}"
GEOEOF
    chmod +x "${GEOIP_DIR}/apply-geoip.sh"

    info "Applying GeoIP allowlist (downloading zones — may take a minute)..."
    nohup bash "${GEOIP_DIR}/apply-geoip.sh" >> "$LOGFILE" 2>&1 &
    local geoip_pid=$! waited=0
    while kill -0 "$geoip_pid" 2>/dev/null && [[ "$waited" -lt 90 ]]; do
        sleep 1; waited=$((waited + 1))
    done
    kill -0 "$geoip_pid" 2>/dev/null && warn "GeoIP apply still running in background (PID $geoip_pid)"

    # Daily refresh + re-apply on reboot (iptables/ipset rules are not persisted).
    local cron_daily="0 4 * * * ${GEOIP_DIR}/apply-geoip.sh >> /var/log/harden.log 2>&1"
    local cron_boot="@reboot sleep 60 && ${GEOIP_DIR}/apply-geoip.sh >> /var/log/harden.log 2>&1"
    (crontab -l 2>/dev/null | grep -vF "apply-geoip" || true; echo "$cron_daily"; echo "$cron_boot") | crontab - 2>/dev/null || true

    ok "GeoIP allowlist active (IPv4+IPv6) — allowed: ${GEOIP_SELECTED} (443 + SSH gated, 80 open for ACME, daily refresh)"
    _log "GeoIP allowlist applied for: ${GEOIP_SELECTED}"
}

# ---------------------------------------------------------------------------
# 5. CrowdSec (local mode, NO registration) — rollback: remove packages
# ---------------------------------------------------------------------------
install_crowdsec() {
    info "=== Installing CrowdSec (local mode) ==="
    # CONFLICT GUARD: the deploy-*.sh stacks already run CrowdSec in a Docker
    # container with an *nftables* firewall bouncer (table ip crowdsec). Do NOT
    # install a second NATIVE CrowdSec + the *iptables* bouncer variant here -
    # two LAPIs and two firewall backends (nft vs iptables) collide and silently
    # break enforcement. Instead just rebuild the existing bouncer's rules, which
    # the `ufw --force reset` + GeoIP step above flushed, and return.
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -x crowdsec >/dev/null 2>&1 \
       || systemctl list-unit-files 2>/dev/null | grep -E '^crowdsec-firewall-bouncer' >/dev/null 2>&1 \
       || [[ -f /etc/crowdsec/crowdsec-firewall-bouncer.yaml ]]; then
        ok "Existing CrowdSec + firewall bouncer detected (from deploy) — not installing a parallel native instance"
        if systemctl list-unit-files 2>/dev/null | grep -E '^crowdsec-firewall-bouncer' >/dev/null 2>&1; then
            # Rebuild the bouncer's nft table on top of the new UFW/GeoIP ruleset.
            if systemctl restart crowdsec-firewall-bouncer >> "$LOGFILE" 2>&1; then
                ok "Firewall bouncer restarted — ban rules rebuilt after firewall reset"
            else
                warn "Could not restart crowdsec-firewall-bouncer — run: systemctl restart crowdsec-firewall-bouncer"
            fi
        else
            warn "Bouncer config present but no systemd unit — bans may not be enforced until the bouncer runs"
        fi
        _log "CrowdSec: kept existing deploy instance; firewall bouncer restarted"
        return
    fi
    if command -v cscli &>/dev/null; then
        ok "CrowdSec already installed"
    else
        curl -s https://install.crowdsec.net | bash -s -- -d "$OS_FAMILY" >> "$LOGFILE" 2>&1 || { warn "CrowdSec repo failed — skipping"; return; }
        _pkg crowdsec >> "$LOGFILE" 2>&1 || { warn "CrowdSec install failed — skipping"; return; }
        ok "CrowdSec installed"
    fi
    cscli collections install crowdsecurity/sshd 2>/dev/null || true
    cscli collections install crowdsecurity/nginx-proxy-manager 2>/dev/null || true
    cscli collections install crowdsecurity/linux 2>/dev/null || true

    if [[ "$OS_FAMILY" == "debian" ]]; then
        dpkg -l crowdsec-firewall-bouncer-iptables &>/dev/null || _pkg crowdsec-firewall-bouncer-iptables >> "$LOGFILE" 2>&1 || true
    else
        rpm -q crowdsec-firewall-bouncer-iptables &>/dev/null || _pkg crowdsec-firewall-bouncer-iptables >> "$LOGFILE" 2>&1 || true
    fi
    systemctl enable --now crowdsec >> "$LOGFILE" 2>&1 || true
    systemctl enable --now crowdsec-firewall-bouncer 2>/dev/null || true

    systemctl is-active --quiet crowdsec 2>/dev/null && ok "CrowdSec active (local mode)" || warn "CrowdSec not running — check ${LOGFILE}"
    _log "CrowdSec configured"
}

# ---------------------------------------------------------------------------
# 6. AIDE File Integrity — rollback: remove aide package + cron
# ---------------------------------------------------------------------------
install_aide() {
    info "=== Installing AIDE file integrity monitor ==="
    if ! command -v aide &>/dev/null; then
        # ROBUSTNESS: a single pre-existing half-configured package (e.g. a
        # crash-looping crowdsec bouncer) makes `apt-get install` exit non-zero
        # even when AIDE itself installs fine — the old `|| { warn; return; }`
        # then silently skipped AIDE while the summary still claimed it. Clear any
        # wedged dpkg state first, then judge success by the BINARY, not the exit code.
        [[ "$OS_FAMILY" == "debian" ]] && DEBIAN_FRONTEND=noninteractive dpkg --configure -a >> "$LOGFILE" 2>&1 || true
        # --no-install-recommends: AIDE's recommends pull a full MTA (postfix),
        # which then LISTENS on :25 - a surface we never want. Reports go to the
        # cron log file, so no MTA is required.
        if [[ "$OS_FAMILY" == "debian" ]]; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends aide aide-common >> "$LOGFILE" 2>&1 || true
        else
            _pkg aide >> "$LOGFILE" 2>&1 || true
        fi
        if ! command -v aide &>/dev/null && [[ "$OS_FAMILY" == "debian" ]]; then
            DEBIAN_FRONTEND=noninteractive apt-get install -f -y >> "$LOGFILE" 2>&1 || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends aide aide-common >> "$LOGFILE" 2>&1 || true
        fi
    fi
    command -v aide &>/dev/null || { warn "AIDE install failed (apt/dpkg may be wedged by a broken package — run 'sudo dpkg --configure -a', then re-run) — skipping"; return; }

    # DEFENSIVE: if an MTA (postfix) was pulled in regardless, bind it to loopback
    # so it is not a public :25 surface.
    if command -v postconf &>/dev/null; then
        postconf -e 'inet_interfaces = loopback-only' >> "$LOGFILE" 2>&1 || true
        systemctl restart postfix >> "$LOGFILE" 2>&1 || true
        ok "Postfix (if present) bound to loopback-only (no public :25)"
    fi

    # EXCLUDE mutable container data: AIDE monitors SYSTEM files, not app data. On a
    # Docker host this (a) lets the DB init in seconds instead of scanning tens of GB
    # and (b) stops a daily alert firing for every normal container/DB write.
    if [[ -d /etc/aide/aide.conf.d ]]; then
        printf '%s\n' '!/opt/apps' '!/var/lib/docker' '!/var/lib/containerd' '!/var/lib/crowdsec' '!/var/log' \
            > /etc/aide/aide.conf.d/99_harden_exclude_volatile 2>/dev/null || true
    fi

    info "Initializing AIDE database (may take a few minutes)..."
    # A leftover db.new makes aideinit print "Overwrite existing ... [Yn]?" and BLOCK
    # on stdin - and because output is redirected to the log, that prompt is INVISIBLE
    # on screen so it looks like a silent hang. Remove the stale db.new and feed
    # /dev/null + -y/-f so it can NEVER prompt.
    rm -f /var/lib/aide/aide.db.new /var/lib/aide/aide.db.new.gz 2>/dev/null || true
    if aideinit -y -f < /dev/null >> "$LOGFILE" 2>&1 || aideinit < /dev/null >> "$LOGFILE" 2>&1; then
        ok "AIDE database initialized (aideinit)"
    elif aide --init < /dev/null 2>/dev/null >> "$LOGFILE" 2>&1; then
        local dbout; dbout=$(grep "^database_out=" /etc/aide/aide.conf 2>/dev/null | cut -d= -f2 | tr -d ' ' || echo "/var/lib/aide/aide.db.new")
        [[ -f "$dbout" ]] && cp -a "$dbout" "${dbout%.new}" 2>/dev/null || true
        ok "AIDE database initialized (aide --init)"
    else
        warn "AIDE init had issues — run 'aide --init' manually"
    fi

    local cronline="30 4 * * * /usr/bin/aide --check >> /var/log/aide-check.log 2>&1 || true"
    (crontab -l 2>/dev/null | grep -vF "aide --check" || true; echo "$cronline") | crontab - 2>/dev/null || true
    ok "AIDE configured (daily check at 04:30)"
    _log "AIDE installed and scheduled"
}

# ---------------------------------------------------------------------------
# 7. Unattended Security Updates — rollback: remove packages
# ---------------------------------------------------------------------------
setup_auto_updates() {
    info "=== Configuring automatic security updates ==="
    if [[ "$OS_FAMILY" == "debian" ]]; then
        _pkg unattended-upgrades apt-listchanges >> "$LOGFILE" 2>&1 || true
        cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'UNATTENDED'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::SyslogEnable "true";
Unattended-Upgrade::OnlyOnACPower "false";
UNATTENDED
        cat > /etc/apt/apt.conf.d/20auto-upgrades << 'AUTOUPG'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
AUTOUPG
        # Ensure the schedulers are actually ON. A fresh box has them enabled, but an
        # earlier deploy/harden run may have left them stopped/disabled while dodging
        # the apt lock — re-enable so scheduled security updates really fire.
        systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >> "$LOGFILE" 2>&1 || true
        systemctl start unattended-upgrades.service >> "$LOGFILE" 2>&1 || true
        ok "Unattended-upgrades configured"
    else
        _pkg dnf-automatic >> "$LOGFILE" 2>&1 || { warn "dnf-automatic install failed"; return; }
        cat > /etc/dnf/automatic.conf << 'DNFAUTO'
[commands]
upgrade_type = security
random_sleep = 0
download_updates = yes
apply_updates = yes
[emitters]
emit_via = stdio
DNFAUTO
        systemctl enable --now dnf-automatic.timer >> "$LOGFILE" 2>&1 || true
        ok "dnf-automatic configured"
    fi
    _log "Auto-updates configured"
}

# ---------------------------------------------------------------------------
# 8. NPM Admin port-81 binding — rollback: restore docker-compose.yml backup
#    LOCKDOWN_NPM_ADMIN=1 -> bind 127.0.0.1:81 (admin via SSH tunnel only)
#    LOCKDOWN_NPM_ADMIN=0 -> bind 0.0.0.0:81   (admin at http://<vps-ip>:81)
#    Idempotent and reversible: re-running with the other value flips it back.
# ---------------------------------------------------------------------------
lockdown_npm_admin() {
    local lock="${LOCKDOWN_NPM_ADMIN:-0}" target want
    if [[ "$lock" == "1" ]]; then
        info "=== Locking NPM admin panel to 127.0.0.1:81 ==="
        target='127.0.0.1:81:81'; want='127\.0\.0\.1:81:81'
    else
        info "=== Exposing NPM admin panel on 0.0.0.0:81 ==="
        target='0.0.0.0:81:81';   want='0\.0\.0\.0:81:81'
    fi
    local paths=(/opt/apps/dockhand-stack /opt/dockhand-stack /opt/portainer-stack /opt/dockge-stack /opt/cosmos-stack /opt/coolify-stack /opt/dokploy-stack /opt/casaos-stack /opt/runtipi-stack /opt/yunohost-stack /opt/freedombox-stack /opt/npm /root/npm /home/*/npm /opt/nginx-proxy-manager)
    [[ -n "${NPM_DIR:-}" ]] && paths=("$NPM_DIR" "${paths[@]}")
    local found=0 p dcf
    for p in "${paths[@]}"; do
        for dcf in "$p"/docker-compose.npm.yml "$p"/docker-compose.npm.yaml "$p"/docker-compose.yml "$p"/docker-compose.yaml; do
            [[ -f "$dcf" ]] || continue
            # Only touch files that actually publish NPM's admin port 81.
            grep -qE '(^|[^0-9])81:81([^0-9]|$)' "$dcf" 2>/dev/null || continue
            found=1
            if grep -q "$want" "$dcf" 2>/dev/null; then
                info "Already correct: $dcf"; continue
            fi
            backup_file "$dcf"
            # Strip any host prefix(es) off the 81:81 mapping (handles 0.0.0.0:,
            # 127.0.0.1:, or a doubled/corrupted prefix), then bind to the target.
            # Two idempotent passes — safe to re-run, never compounds.
            sed -i -E 's#([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:)+81:81#81:81#g' "$dcf" 2>/dev/null || true
            sed -i -E "s#(^[[:space:]]*-[[:space:]]*\"?)81:81#\1${target}#" "$dcf" 2>/dev/null || true
            info "Updated: $dcf -> ${target}"
            if command -v docker &>/dev/null; then
                # CRITICAL: recreate under the SAME compose project the stack was
                # deployed with (e.g. `-p npm`), inferred from the running container's
                # label. Without -p, `up -d` uses the directory name as the project,
                # targets a DIFFERENT project, and the real container is never
                # recreated -> the edited 127.0.0.1 binding never takes effect and
                # port 81 stays public.
                local _cid _proj=""
                _cid=$(docker ps -aq --filter "label=com.docker.compose.project.config_files=$dcf" 2>/dev/null | head -1)
                [[ -n "$_cid" ]] && _proj=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$_cid" 2>/dev/null || true)
                (cd "$p" && docker compose ${_proj:+-p "$_proj"} -f "$dcf" up -d >> "$LOGFILE" 2>&1) || \
                    (cd "$p" && docker-compose ${_proj:+-p "$_proj"} -f "$dcf" up -d >> "$LOGFILE" 2>&1) || \
                    warn "Docker compose failed for $p"
            fi
        done
    done
    if [[ "$found" -eq 0 ]]; then
        warn "No NPM docker-compose file found — manual change needed"
    elif [[ "$lock" == "1" ]]; then
        ok "NPM admin bound to 127.0.0.1:81 (tunnel: ssh -L 8181:127.0.0.1:81 root@<vps-ip>)"
    else
        ok "NPM admin published on 0.0.0.0:81 (http://<vps-ip>:81 — use a strong password)"
    fi
    _log "NPM admin binding: lock=$lock target=$target found=$found"
}

# ---------------------------------------------------------------------------
# 9. Docker Security — rollback: restore daemon.json backup
# ---------------------------------------------------------------------------
harden_docker() {
    info "=== Hardening Docker daemon ==="
    command -v docker &>/dev/null || { warn "Docker not installed — skipping"; return; }
    mkdir -p /etc/docker; backup_file /etc/docker/daemon.json
    cat > /etc/docker/daemon.json << 'DOCKERCONF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true,
  "userland-proxy": false,
  "no-new-privileges": true
}
DOCKERCONF
    systemctl restart docker >> "$LOGFILE" 2>&1 || warn "Docker restart failed"
    ok "Docker hardened (log rotation, live-restore, no-new-privileges)"
    _log "Docker hardening applied"
}

# ---------------------------------------------------------------------------
# 10. Local Backups — rollback: remove script + crontab entry
# ---------------------------------------------------------------------------
setup_backups() {
    info "=== Setting up local backups ==="
    mkdir -p /backups
    cat > /usr/local/bin/vps-backup << 'BACKUPEOF'
#!/usr/bin/env bash
set -euo pipefail
readonly BACKUP_DIR="/backups" DATE=$(date +%Y%m%d_%H%M%S) RETENTION_DAYS=7
mkdir -p "$BACKUP_DIR"
[[ -d /opt ]]        && tar czf "${BACKUP_DIR}/opt-${DATE}.tar.gz"        -C / opt        2>/dev/null || true
[[ -d /etc ]]        && tar czf "${BACKUP_DIR}/etc-${DATE}.tar.gz"        -C / etc        2>/dev/null || true
[[ -d /etc/crowdsec ]] && tar czf "${BACKUP_DIR}/crowdsec-${DATE}.tar.gz" -C / etc/crowdsec 2>/dev/null || true
find "$BACKUP_DIR" -name "*.tar.gz" -mtime +${RETENTION_DAYS} -delete 2>/dev/null || true
echo "$(date '+%Y-%m-%d %H:%M:%S') Backup complete: ${DATE}" >> /var/log/backup.log
BACKUPEOF
    chmod +x /usr/local/bin/vps-backup
    local cronline="0 3 * * * /usr/local/bin/vps-backup"
    (crontab -l 2>/dev/null | grep -vF "vps-backup" || true; echo "$cronline") | crontab - 2>/dev/null || true
    nohup /usr/local/bin/vps-backup >> /var/log/backup.log 2>&1 &
    ok "Backups configured (daily 03:00, 7-day retention)"
    _log "Backup system configured"
}

# ---------------------------------------------------------------------------
# 11. Misc hardening
# ---------------------------------------------------------------------------
harden_misc() {
    info "=== Miscellaneous hardening ==="
    chmod 700 /root 2>/dev/null || true
    chmod 700 /root/.ssh 2>/dev/null || true
    chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true
    cat > /etc/security/limits.d/99-harden.conf << 'LIMITS'
* soft core 0
* hard core 0
LIMITS
    chmod -x /etc/update-motd.d/* 2>/dev/null || true
    # Disable rpcbind/portmapper (port 111). Ubuntu ships it enabled and listening
    # on 0.0.0.0:111 (+ [::]:111) - a classic DDoS-amplification + info-disclosure
    # surface - yet nothing on a single-host Docker deploy needs it. Skip only if
    # NFS is actually in use (rpcbind is required for NFS client/server).
    # CRITICAL: capture into vars + use `grep` (NOT `grep -q`). Under `set -o pipefail`,
    # `systemctl list-unit-files | grep -q '^rpcbind'` had grep -q close the pipe on the
    # first match -> SIGPIPE killed systemctl (exit 141) -> pipefail made the whole
    # condition FALSE -> this entire block SILENTLY never ran, so rpcbind stayed up on
    # EVERY box (the purge line was here but unreached). grep without -q drains all input.
    local _nfs_in_use _rpc_units
    _nfs_in_use=$( { mount 2>/dev/null | grep -E ' type nfs| type nfs4'; grep -hsE '\snfs[4 ]' /etc/fstab 2>/dev/null; } || true )
    _rpc_units=$(systemctl list-unit-files 2>/dev/null | grep -iE '^rpcbind' || true)
    if [[ -n "$_nfs_in_use" ]]; then
        info "rpcbind left enabled (NFS mount detected)"
    elif [[ -n "$_rpc_units" ]]; then
        # nfs-common Depends on rpcbind, so masking alone is NOT enough — the package
        # stays installed and socket-activation/apt upgrades re-open :111. We only reach
        # here when NO NFS is in use (checked above), so PURGE both for good; then mask
        # any leftover unit and verify :111 is actually closed.
        [[ "$OS_FAMILY" == "debian" ]] && DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq -o DPkg::Lock::Timeout=300 nfs-common rpcbind </dev/null >>"$LOGFILE" 2>&1 || true
        systemctl mask --now rpcbind.socket rpcbind.service 2>/dev/null || true
        systemctl stop rpcbind.socket rpcbind.service 2>/dev/null || true
        if ss -tlnH 2>/dev/null | grep -E ':111 ' >/dev/null; then
            warn "rpcbind still on :111 — check 'systemctl status rpcbind.socket'"
        else
            ok "rpcbind (port 111) removed (purged nfs-common+rpcbind, no NFS in use)"
        fi
    fi
    ok "Misc hardening applied (permissions, core dumps, MOTD)"
    _log "Misc hardening applied"
}

# ---------------------------------------------------------------------------
# 11b. SSH Daemon Hardening — rollback: restore sshd_config backup
# ---------------------------------------------------------------------------
harden_ssh() {
    info "=== Hardening SSH daemon ==="
    local cfg="/etc/ssh/sshd_config"
    local sshd_bin; sshd_bin="$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)"
    [[ -f "$cfg" ]] || { warn "No $cfg — skipping SSH hardening"; return; }
    backup_file "$cfg"

    # Safety: only disable password auth if a key is already installed — otherwise
    # we could lock the operator out of the box.
    local have_key=false kf
    for kf in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
        [[ -s "$kf" ]] && { have_key=true; break; }
    done

    _set_sshd() {  # $1=key $2=value — replace existing (commented or not) or append
        if grep -qiE "^[#[:space:]]*${1}([[:space:]]|$)" "$cfg"; then
            sed -i -E "s|^[#[:space:]]*${1}([[:space:]]).*|${1} ${2}|I" "$cfg"
        else
            printf '%s %s\n' "$1" "$2" >> "$cfg"
        fi
    }

    _set_sshd PermitRootLogin prohibit-password
    _set_sshd X11Forwarding no
    _set_sshd MaxAuthTries 3
    _set_sshd ClientAliveInterval 300
    _set_sshd ClientAliveCountMax 2
    _set_sshd PermitEmptyPasswords no

    if [[ "$have_key" == true ]]; then
        _set_sshd PasswordAuthentication no
        ok "SSH: password auth DISABLED (key present); root login is key-only"
    else
        warn "No SSH authorized_keys found — leaving PasswordAuthentication ENABLED to avoid lockout"
        warn "Install your public key, then set 'PasswordAuthentication no' in $cfg manually"
    fi

    if "$sshd_bin" -t 2>>"$LOGFILE"; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || \
            systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
        ok "SSH daemon hardened"
    else
        warn "sshd config test FAILED — restoring backup, no changes applied"
        cp -a "${cfg}${BAKSUF}" "$cfg" 2>/dev/null || true
    fi
    _log "SSH hardening applied (have_key=$have_key)"
}

# ---------------------------------------------------------------------------
# 12. Self-Verification — checks every module and reports PASS/FAIL
# ---------------------------------------------------------------------------
verify_hardening() {
    info "=== Verifying hardening ==="
    local total=0 pass=0
    local status val

    _check() {
        total=$((total + 1))
        if eval "$2" >> "$LOGFILE" 2>&1; then
            pass=$((pass + 1))
            printf "  ${C_GRN}[PASS]${C_RST}  %s\n" "$1"
            _log "VERIFY PASS: $1"
        else
            printf "  ${C_RED}[FAIL]${C_RST}  %s\n" "$1"
            _log "VERIFY FAIL: $1"
        fi
    }

    echo ""
    echo "┌──────────────────────────────────────────────────────────────────┐"
    echo "│  HARDENING VERIFICATION                                        │"
    echo "├──────────────────────────────────────────────────────────────────┤"

    # 1. Sysctl
    _check "Kernel SYN cookies"      "[[ \$(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null) == '1' ]]"
    _check "Kernel RP filter"        "[[ \$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null) == '1' ]]"
    _check "No source routing"       "[[ \$(sysctl -n net.ipv4.conf.all.accept_source_route 2>/dev/null) == '0' ]]"
    _check "IP forwarding ON (Docker)" "[[ \$(sysctl -n net.ipv4.ip_forward 2>/dev/null) == '1' ]]"

    # 2. Firewall
    if [[ "$OS_FAMILY" == "debian" ]]; then
        _check "UFW rate limit SSH"  "ufw status 2>/dev/null | grep -qE '22/tcp .*LIMIT'"
        _check "UFW rate limit HTTP" "ufw status 2>/dev/null | grep -qE '80/tcp .*LIMIT'"
    else
        _check "Firewalld rate limit" "firewall-cmd --list-all 2>/dev/null | grep -q 'rich rule'"
    fi

    # 3. GeoIP
    # GeoIP is now a default-deny ALLOWLIST (GEOIP_GATE chain + geoip_allow ipset),
    # and it's OPTIONAL. PASS when the gate is active OR when GeoIP wasn't enabled
    # (no geoip_allow set) - only FAIL if a set exists but the gate isn't hooked.
    _check "GeoIP zone files"        "ls /usr/local/bin/geoip-block/*.zone >/dev/null 2>&1 || ! ipset list -n 2>/dev/null | grep -q geoip_allow"
    _check "GeoIP allowlist active"  "iptables -L GEOIP_GATE -n >/dev/null 2>&1 || ! ipset list -n 2>/dev/null | grep -q geoip_allow"
    _check "rpcbind (port 111) off"  "mount 2>/dev/null | grep -qE ' type nfs' || ! ss -tlnH 2>/dev/null | grep -q ':111 '"

    # 4. CrowdSec
    _check "CrowdSec installed"      "command -v cscli >/dev/null 2>&1 || docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx crowdsec"
    _check "CrowdSec running"        "systemctl is-active --quiet crowdsec 2>/dev/null || docker ps --format '{{.Names}}' 2>/dev/null | grep -qx crowdsec"
    _check "CrowdSec bouncer"        "systemctl is-active --quiet crowdsec-firewall-bouncer 2>/dev/null"

    # 5. AIDE
    _check "AIDE installed"          "command -v aide >/dev/null 2>&1"

    # 6. Auto updates
    if [[ "$OS_FAMILY" == "debian" ]]; then
        _check "Auto-updates active" "systemctl is-active --quiet unattended-upgrades 2>/dev/null"
    else
        _check "Auto-updates active" "systemctl is-active --quiet dnf-automatic.timer 2>/dev/null"
    fi

    # 7. NPM admin port-81 binding (matches LOCKDOWN_NPM_ADMIN) — only when an NPM
    # stack is actually deployed (skipped for NetBird/Traefik stacks, which have no
    # 'npm' container and no port 81).
    # Prefer 'docker port' — robust even with userland-proxy disabled (no host
    # listener socket shows in ss when docker-proxy is off; DNAT lives in iptables).
    if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx npm; then
        if [[ "${LOCKDOWN_NPM_ADMIN:-0}" == "1" ]]; then
            _check "NPM admin bound to localhost" "if docker port npm 81 >/dev/null 2>&1; then docker port npm 81 2>/dev/null | grep -q '127.0.0.1'; else ss -tln 2>/dev/null | grep -q '127.0.0.1:81'; fi"
        else
            _check "NPM admin reachable on :81" "if docker port npm 81 >/dev/null 2>&1; then docker port npm 81 2>/dev/null | grep -qE '0\.0\.0\.0|\[::\]'; else ss -tln 2>/dev/null | grep -qE '(0\.0\.0\.0|\*|\[::\]):81'; fi"
        fi
    fi

    # 8. Docker
    _check "Docker daemon.json"      "[[ -f /etc/docker/daemon.json ]]"

    # 8b. SSH
    _check "SSH root login key-only" "${SSHD_BIN:-$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)} -T 2>/dev/null | grep -qiE 'permitrootlogin (prohibit-password|without-password|no)' || grep -rqiE '^[[:space:]]*PermitRootLogin[[:space:]]+(prohibit-password|without-password|no)' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null"

    # 9. Backups
    _check "Backup script exists"    "[[ -f /usr/local/bin/vps-backup ]]"
    _check "Backup cron set"         "crontab -l 2>/dev/null | grep -q 'vps-backup'"

    echo "├──────────────────────────────────────────────────────────────────┤"
    printf "│  Result: ${C_BLD}%d/%d${C_RST} checks passed                                  │\n" "$pass" "$total"
    echo "└──────────────────────────────────────────────────────────────────┘"
    echo ""

    if [[ "$pass" -lt "$total" ]]; then
        local fail=$((total - pass))
        warn "$fail check(s) failed — review output above"
        echo "  Failed items can be re-run individually. Check log: $LOGFILE"
        echo "  All configs backed up with suffix: $BAKSUF"
    else
        ok "All $total checks passed"
    fi

    if [[ "${LOCKDOWN_NPM_ADMIN:-0}" == "1" ]]; then
        echo "  ${C_YLW}Access NPM Admin:${C_RST}  ssh -L 8181:127.0.0.1:81 root@<vps-ip>"
        echo "                    Then open http://localhost:8181"
    else
        echo "  ${C_YLW}Access NPM Admin:${C_RST}  http://<vps-ip>:81  (exposed — set a strong password)"
    fi
    echo ""
    _log "=== Verification: $pass/$total passed ==="
    # Clear abort trap on successful completion
    trap - ERR
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
    local ip ext_ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<internal_ip>")
    ext_ip=$(get_external_ip)

    printf "\n"
    printf "${C_BLD}${C_GRN}╔══════════════════════════════════════════════════════════════════════════════╗${C_RST}\n"
    printf "${C_BLD}${C_GRN}║                   ✅  VPS HARDENING COMPLETE                                 ║${C_RST}\n"
    printf "${C_BLD}${C_GRN}╠══════════════════════════════════════════════════════════════════════════════╣${C_RST}\n"
    printf "${C_BLD}║  External IP:  ${C_BLU}%-16s${C_RST}${C_BLD}                                                   ║${C_RST}\n" "$ext_ip"
    printf "${C_BLD}║  Internal IP:  ${C_BLU}%-16s${C_RST}${C_BLD}                                                   ║${C_RST}\n" "$ip"
    printf "${C_BLD}╠══════════════════════════════════════════════════════════════════════════════╣${C_RST}\n"
    printf "${C_BLD}║  ${C_YLW}Security layers enabled:${C_RST}                                                  ${C_BLD}║${C_RST}\n"
    printf "${C_BLD}║    • CrowdSec (local IDS)     • GeoIP allowlist (deny-all)                   ║${C_RST}\n"
    printf "${C_BLD}║    • Auto security updates    • AIDE file integrity                          ║${C_RST}\n"
    printf "${C_BLD}║    • Firewall rate limiting   • Docker log rotation                          ║${C_RST}\n"
    printf "${C_BLD}╠══════════════════════════════════════════════════════════════════════════════╣${C_RST}\n"
    if [[ "${LOCKDOWN_NPM_ADMIN:-0}" == "1" ]]; then
    printf "${C_BLD}║  ${C_RED}⚠️  IMPORTANT:${C_RST} NPM admin (port 81) now restricted to localhost.           ${C_BLD}║${C_RST}\n"
    printf "${C_BLD}║     Tunnel:  ssh -L 8181:127.0.0.1:81 root@${ext_ip}  -> http://localhost:8181   ${C_BLD}║${C_RST}\n"
    else
    printf "${C_BLD}║  ${C_RED}⚠️  IMPORTANT:${C_RST} NPM admin (port 81) is EXPOSED at http://<vps-ip>:81.        ${C_BLD}║${C_RST}\n"
    printf "${C_BLD}║     Open:    ${C_BLU}http://${ext_ip}:81${C_RST}  — set a STRONG admin password now.        ${C_BLD}║${C_RST}\n"
    fi
    printf "${C_BLD}╚══════════════════════════════════════════════════════════════════════════════╝${C_RST}\n"
    printf "\n"
    # HONEST status: the box above lists INTENDED layers; this reflects what is
    # actually present (so a silent install failure can't masquerade as success).
    local _miss=""
    command -v aide >/dev/null 2>&1 || _miss+="AIDE "
    { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx crowdsec || systemctl is-active --quiet crowdsec 2>/dev/null; } || _miss+="CrowdSec "
    systemctl is-active --quiet crowdsec-firewall-bouncer 2>/dev/null || _miss+="firewall-bouncer "
    if [[ -n "$_miss" ]]; then
        printf "${C_RED}${C_BLD}⚠️  Listed above but NOT actually active: ${_miss}${C_RST}\n"
        printf "   Common cause: a half-configured package wedged apt/dpkg. Fix + retry:\n"
        printf "     ${C_BLU}sudo dpkg --configure -a && sudo apt-get -f install${C_RST}  then re-run this script\n\n"
    fi
    if [[ -x "${GEOIP_DIR}/apply-geoip.sh" ]] && ipset list geoip_allow &>/dev/null; then
        printf "${C_YLW}${C_BLD}GeoIP allowlist ACTIVE (default-deny):${C_RST}\n"
        printf "  Allowed: %s\n" "$(geoip_names "$(sed -n 's/^COUNTRIES="\(.*\)"/\1/p' "${GEOIP_DIR}/apply-geoip.sh" | head -1)")"
        printf "  ${C_RED}SSH (22) is geo-gated.${C_RST} If your home IP's country drops off the list you\n"
        printf "  lose SSH — recover via your provider's web/serial console, then run:\n"
        printf "    ${C_BLU}GEOIP_DISABLE=1 bash %s/apply-geoip.sh${C_RST}  (removes all geo rules)\n" "$GEOIP_DIR"
        printf "  Edit the country list: re-run harden.sh, or set GEOIP_ALLOW=\"us,ca,...\".\n\n"
    fi
    printf "  Log:     %s\n" "$LOGFILE"
    printf "  Backups: files with suffix %s\n\n" "$BAKSUF"

    printf "${C_BLD}${C_YLW}OPTIONAL: Disable SSH access when setup is done${C_RST}\n\n"
    printf "  When you've finished configuring your services, disable SSH\n"
    printf "  via your cloud provider's security group / firewall (NOT via\n"
    printf "  UFW — you'd have no way to re-enable it without SSH):\n\n"
    printf "    ${C_BLU}Oracle Cloud:${C_RST}  VCN → Security Lists → Remove ingress rule for port 22\n"
    printf "    ${C_BLU}AWS:${C_RST}          EC2 → Security Groups → Remove inbound rule for port 22\n"
    printf "    ${C_BLU}DigitalOcean:${C_RST} Networking → Firewalls → Remove SSH rule\n"
    printf "    ${C_BLU}Hetzner:${C_RST}      Console → Firewalls → Remove SSH rule\n\n"
    printf "  Your services (NPM, apps, etc.) continue running normally.\n"
    printf "  To re-enable SSH later, add the ingress rule back from the\n"
    printf "  provider's web console — no SSH access required.\n\n"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    # Log any unexpected error (does not fire on normal exit)
    trap '_log "=== SCRIPT ABORTED at line $LINENO ==="' ERR
    preflight
    user_confirm
    backup_configs
    harden_sysctl
    harden_firewall
    harden_geoip
    install_crowdsec
    install_aide
    setup_auto_updates
    lockdown_npm_admin
    harden_docker
    harden_misc
    harden_ssh
    setup_backups
    verify_hardening
    print_summary
}

main "$@"
