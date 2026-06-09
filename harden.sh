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
readonly C_RST='\033[0m' C_BLD='\033[1m' C_GRN='\033[1;32m'
readonly C_YLW='\033[1;33m' C_RED='\033[1;31m' C_BLU='\033[1;34m'

get_external_ip() {
  curl -s -4 --max-time 10 https://api.ipify.org 2>/dev/null || \
  curl -s -4 --max-time 10 https://ifconfig.me 2>/dev/null || \
  curl -s -4 --max-time 10 https://icanhazip.com 2>/dev/null || \
  echo "unknown"
}

OS_FAMILY="" PKG_MANAGER="" PKG_INSTALL=""

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
    [[ -d /opt/npm/data ]] && deployed=true
    [[ -d /opt/portainer ]] && deployed=true
    [[ -d /opt/dockge ]] && deployed=true
    [[ -d /opt/coolify ]] && deployed=true
    [[ -d /captain ]] && deployed=true
    [[ -d /opt/stacks ]] && deployed=true
    command -v docker &>/dev/null && docker ps --format '{{.Names}}' 2>/dev/null | grep -qE 'npm|portainer|dockge|coolify' && deployed=true

    if [[ "$deployed" == false ]]; then
        echo ""
        warn "No deployment detected. Have you run a deploy script first?"
        printf "  ${C_YLW}harden.sh should be run AFTER deploying your tool.${C_RST}\n"
        printf "  ${C_YLW}It locks down port 81 — you'll need NPM set up first.${C_RST}\n"
        printf "  ${C_BLU}Run: ./deploy.sh  → pick a tool  → then run: ./deploy.sh harden${C_RST}\n"
        echo ""
        read -rp "Continue anyway? [y/N]: " force
        [[ "$force" =~ ^[Yy]$ ]] || { info "Aborted. Deploy first, then harden."; exit 0; }
    fi

    mkdir -p "$(dirname "$LOGFILE")" && touch "$LOGFILE" 2>/dev/null || { error "Cannot write $LOGFILE"; exit 1; }
    [[ "$OS_FAMILY" == "debian" ]] && apt-get update -qq >> "$LOGFILE" 2>&1
    for t in curl wget sed awk; do
        command -v "$t" &>/dev/null && continue
        info "Installing: $t"; $PKG_INSTALL "$t" >> "$LOGFILE" 2>&1 || warn "Failed to install $t"
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
    printf "  Kernel sysctl         Firewall rate limit   GeoIP blocking\n"
    printf "  CrowdSec (local)      AIDE file integrity   Auto security updates\n"
    printf "  NPM admin lockdown    Docker hardening      Daily local backups\n\n"
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
}

backup_configs() {
    info "=== Backing up configs ==="
    local f
    for f in /etc/sysctl.conf /etc/ufw/before.rules \
             /etc/ufw/ufw.conf /etc/docker/daemon.json \
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
        echo "net.ipv4.ip_forward=0"
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
# 3. Firewall Rate Limiting — rollback: ufw reset / remove firewalld rules
# ---------------------------------------------------------------------------
harden_firewall() {
    info "=== Configuring firewall rate limiting ==="
    if [[ "$OS_FAMILY" == "debian" ]]; then
        command -v ufw &>/dev/null || { info "Installing UFW"; $PKG_INSTALL ufw >> "$LOGFILE" 2>&1; }
        ufw --force reset >> "$LOGFILE" 2>&1 || true
        ufw default deny incoming  >> "$LOGFILE" 2>&1 || true
        ufw default allow outgoing >> "$LOGFILE" 2>&1 || true
        ufw limit 22/tcp  comment 'SSH rate limit'    >> "$LOGFILE" 2>&1 || true
        ufw limit 80/tcp  comment 'HTTP rate limit'   >> "$LOGFILE" 2>&1 || true
        ufw limit 443/tcp comment 'HTTPS rate limit'  >> "$LOGFILE" 2>&1 || true
        ufw delete allow 81/tcp >> "$LOGFILE" 2>&1 || true
        ufw --force enable >> "$LOGFILE" 2>&1 || true
        ok "UFW rate limiting configured"
    else
        systemctl is-active --quiet firewalld 2>/dev/null || { $PKG_INSTALL firewalld >> "$LOGFILE" 2>&1; systemctl enable --now firewalld >> "$LOGFILE" 2>&1; }
        firewall-cmd --permanent --add-rich-rule='rule service name=ssh  limit value=6/m accept'  >> "$LOGFILE" 2>&1 || true
        firewall-cmd --permanent --add-rich-rule='rule service name=http limit value=30/m accept' >> "$LOGFILE" 2>&1 || true
        firewall-cmd --permanent --add-rich-rule='rule service name=https limit value=30/m accept' >> "$LOGFILE" 2>&1 || true
        firewall-cmd --permanent --add-service=http >> "$LOGFILE" 2>&1 || true
        firewall-cmd --permanent --add-service=https >> "$LOGFILE" 2>&1 || true
        firewall-cmd --permanent --add-service=ssh >> "$LOGFILE" 2>&1 || true
        firewall-cmd --reload >> "$LOGFILE" 2>&1 || true
        ok "Firewalld rate limiting configured"
    fi
    _log "Firewall rate limiting applied"
}

# ---------------------------------------------------------------------------
# 4. GeoIP Blocking (free ipdeny lists) — rollback: rm $GEOIP_DIR
# ---------------------------------------------------------------------------
harden_geoip() {
    info "=== Setting up GeoIP blocking ==="
    mkdir -p "$GEOIP_DIR"
    local c updated=0
    for c in cn ru kp ir; do
        curl -fsSL --max-time 30 "https://www.ipdeny.com/ipblocks/data/countries/${c}.zone" -o "${GEOIP_DIR}/${c}.zone" >> "$LOGFILE" 2>&1 && {
            updated=$((updated+1))
            _log "GeoIP zone downloaded: ${c}.zone"
        } || warn "Failed to download zone: $c"
    done
    [[ "$updated" -eq 0 ]] && { warn "No GeoIP zones downloaded — skipping"; return; }

    cat > "${GEOIP_DIR}/apply-geoip.sh" << 'GEOEOF'
#!/usr/bin/env bash
DIR="/usr/local/bin/geoip-block" CHAIN="GEOIP_BLOCK"
for cmd in iptables ip6tables; do
    command -v "$cmd" &>/dev/null || continue
    "$cmd" -F "$CHAIN" 2>/dev/null || true
    "$cmd" -D INPUT -j "$CHAIN" 2>/dev/null || true
    "$cmd" -X "$CHAIN" 2>/dev/null || true
    "$cmd" -N "$CHAIN" 2>/dev/null || true
    "$cmd" -A INPUT -j "$CHAIN" 2>/dev/null || true
done
for c in cn ru kp ir; do
    [[ -f "${DIR}/${c}.zone" ]] || continue
    while IFS= read -r subnet; do
        [[ -z "$subnet" || "$subnet" =~ ^# ]] && continue
        iptables -A "$CHAIN" -s "$subnet" -j DROP 2>/dev/null || true
    done < "${DIR}/${c}.zone"
done
echo "$(date '+%Y-%m-%d %H:%M:%S') GeoIP blocks applied" >> /var/log/harden.log
GEOEOF
    chmod +x "${GEOIP_DIR}/apply-geoip.sh"
    info "Applying GeoIP blocks (this may take a minute)..."
    nohup bash "${GEOIP_DIR}/apply-geoip.sh" >> "$LOGFILE" 2>&1 &
    local geoip_pid=$!
    local waited=0
    while kill -0 "$geoip_pid" 2>/dev/null && [[ "$waited" -lt 60 ]]; do
        sleep 1; waited=$((waited + 1))
    done
    kill -0 "$geoip_pid" 2>/dev/null && warn "GeoIP apply still running in background (PID $geoip_pid)"

    local cronline="0 4 * * * ${GEOIP_DIR}/apply-geoip.sh >> /var/log/harden.log 2>&1"
    (crontab -l 2>/dev/null | grep -vF "apply-geoip"; echo "$cronline") | sort -u | crontab -

    ok "GeoIP blocking configured (${updated} countries, daily refresh)"
    _log "GeoIP blocking applied for: cn ru kp ir"
}

# ---------------------------------------------------------------------------
# 5. CrowdSec (local mode, NO registration) — rollback: remove packages
# ---------------------------------------------------------------------------
install_crowdsec() {
    info "=== Installing CrowdSec (local mode) ==="
    if command -v cscli &>/dev/null; then
        ok "CrowdSec already installed"
    else
        curl -s https://install.crowdsec.net | bash -s -- -d "$OS_FAMILY" >> "$LOGFILE" 2>&1 || { warn "CrowdSec repo failed — skipping"; return; }
        $PKG_INSTALL crowdsec >> "$LOGFILE" 2>&1 || { warn "CrowdSec install failed — skipping"; return; }
        ok "CrowdSec installed"
    fi
    cscli collections install crowdsecurity/sshd 2>/dev/null || true
    cscli collections install crowdsecurity/nginx-proxy-manager 2>/dev/null || true
    cscli collections install crowdsecurity/linux 2>/dev/null || true

    if [[ "$OS_FAMILY" == "debian" ]]; then
        dpkg -l crowdsec-firewall-bouncer-iptables &>/dev/null || $PKG_INSTALL crowdsec-firewall-bouncer-iptables >> "$LOGFILE" 2>&1 || true
    else
        rpm -q crowdsec-firewall-bouncer-iptables &>/dev/null || $PKG_INSTALL crowdsec-firewall-bouncer-iptables >> "$LOGFILE" 2>&1 || true
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
    command -v aide &>/dev/null || $PKG_INSTALL aide >> "$LOGFILE" 2>&1 || { warn "AIDE install failed — skipping"; return; }

    info "Initializing AIDE database (may take a few minutes)..."
    if aideinit 2>/dev/null >> "$LOGFILE" 2>&1; then
        ok "AIDE database initialized (aideinit)"
    elif aide --init 2>/dev/null >> "$LOGFILE" 2>&1; then
        local dbout; dbout=$(grep "^database_out=" /etc/aide/aide.conf 2>/dev/null | cut -d= -f2 | tr -d ' ' || echo "/var/lib/aide/aide.db.new")
        [[ -f "$dbout" ]] && cp -a "$dbout" "${dbout%.new}" 2>/dev/null || true
        ok "AIDE database initialized (aide --init)"
    else
        warn "AIDE init had issues — run 'aide --init' manually"
    fi

    local cronline="30 4 * * * /usr/bin/aide --check >> /var/log/aide-check.log 2>&1 || true"
    (crontab -l 2>/dev/null | grep -vF "aide --check"; echo "$cronline") | sort -u | crontab -
    ok "AIDE configured (daily check at 04:30)"
    _log "AIDE installed and scheduled"
}

# ---------------------------------------------------------------------------
# 7. Unattended Security Updates — rollback: remove packages
# ---------------------------------------------------------------------------
setup_auto_updates() {
    info "=== Configuring automatic security updates ==="
    if [[ "$OS_FAMILY" == "debian" ]]; then
        $PKG_INSTALL unattended-upgrades apt-listchanges >> "$LOGFILE" 2>&1 || true
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
        ok "Unattended-upgrades configured"
    else
        $PKG_INSTALL dnf-automatic >> "$LOGFILE" 2>&1 || { warn "dnf-automatic install failed"; return; }
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
# 8. NPM Admin Lockdown — rollback: restore docker-compose.yml backup
# ---------------------------------------------------------------------------
lockdown_npm_admin() {
    info "=== Locking down NPM admin panel ==="
    local dcf="${NPM_DIR:-/opt/npm}/docker-compose.yml"
    if grep -q '127\.0\.0\.1:81:81' "$dcf" 2>/dev/null; then
        info "NPM admin already locked to localhost"; return 0
    fi
    local paths=(/opt/npm /root/npm /home/*/npm /opt/nginx-proxy-manager)
    local found=0
    for p in "${paths[@]}"; do
        for dcf in "$p"/docker-compose.yml "$p"/docker-compose.yaml; do
            [[ -f "$dcf" ]] || continue
            found=1; backup_file "$dcf"
            sed -i -E "s/([\"']?)0\.0\.0\.0:81:81\1/\1127.0.0.1:81:81\1/g" "$dcf" 2>/dev/null || true
            sed -i -E "s/([\"']?)81:81\1/\1127.0.0.1:81:81\1/g" "$dcf" 2>/dev/null || true
            sed -i '/port.*81:81/s/81:81/127.0.0.1:81:81/' "$dcf" 2>/dev/null || true
            info "Updated: $dcf"
            if command -v docker &>/dev/null; then
                (cd "$p" && docker compose up -d >> "$LOGFILE" 2>&1) || \
                    (cd "$p" && docker-compose up -d >> "$LOGFILE" 2>&1) || \
                    warn "Docker compose failed for $p"
            fi
        done
    done
    [[ "$found" -eq 0 ]] && warn "No NPM docker-compose.yml found — manual lockdown needed" || ok "NPM admin locked to 127.0.0.1:81"
    _log "NPM lockdown: found=$found"
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
    (crontab -l 2>/dev/null | grep -vF "vps-backup"; echo "$cronline") | sort -u | crontab -
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
    ok "Misc hardening applied (permissions, core dumps, MOTD)"
    _log "Misc hardening applied"
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

    # 2. Firewall
    if [[ "$OS_FAMILY" == "debian" ]]; then
        _check "UFW rate limit SSH"  "ufw status 2>/dev/null | grep -q 'LIMIT.*22'"
        _check "UFW rate limit HTTP" "ufw status 2>/dev/null | grep -q 'LIMIT.*80'"
    else
        _check "Firewalld rate limit" "firewall-cmd --list-all 2>/dev/null | grep -q 'rich rule'"
    fi

    # 3. GeoIP
    _check "GeoIP zone files"        "[[ -f /usr/local/bin/geoip-block/cn.zone ]]"
    _check "GeoIP iptables chain"    "iptables -L GEOIP_BLOCK -n >/dev/null 2>&1"

    # 4. CrowdSec
    _check "CrowdSec installed"      "command -v cscli >/dev/null 2>&1"
    _check "CrowdSec running"        "systemctl is-active --quiet crowdsec 2>/dev/null"
    _check "CrowdSec bouncer"        "systemctl is-active --quiet crowdsec-firewall-bouncer 2>/dev/null"

    # 5. AIDE
    _check "AIDE installed"          "command -v aide >/dev/null 2>&1"

    # 6. Auto updates
    if [[ "$OS_FAMILY" == "debian" ]]; then
        _check "Auto-updates active" "systemctl is-active --quiet unattended-upgrades 2>/dev/null"
    else
        _check "Auto-updates active" "systemctl is-active --quiet dnf-automatic.timer 2>/dev/null"
    fi

    # 7. NPM lockdown
    _check "NPM on localhost:81"     "ss -tln 2>/dev/null | grep -q '127.0.0.1:81'"

    # 8. Docker
    _check "Docker daemon.json"      "[[ -f /etc/docker/daemon.json ]]"

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

    echo "  ${C_YLW}Access NPM Admin:${C_RST}  ssh -L 8181:127.0.0.1:81 root@<vps-ip>"
    echo "                    Then open http://localhost:8181"
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
    printf "${C_BLD}║    • CrowdSec (local IDS)     • GeoIP blocking                               ║${C_RST}\n"
    printf "${C_BLD}║    • Auto security updates    • AIDE file integrity                          ║${C_RST}\n"
    printf "${C_BLD}║    • Firewall rate limiting   • Docker log rotation                          ║${C_RST}\n"
    printf "${C_BLD}╠══════════════════════════════════════════════════════════════════════════════╣${C_RST}\n"
    printf "${C_BLD}║  ${C_RED}⚠️  IMPORTANT:${C_RST} NPM admin (port 81) now restricted to localhost.           ${C_BLD}║${C_RST}\n"
    printf "${C_BLD}║     Access via SSH tunnel:  ssh -L 8080:localhost:81 user@${ext_ip}         ${C_BLD}║${C_RST}\n"
    printf "${C_BLD}╚══════════════════════════════════════════════════════════════════════════════╝${C_RST}\n"
    printf "\n"
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
    setup_backups
    verify_hardening
    print_summary
}

main "$@"
