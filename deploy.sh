#!/usr/bin/env bash
# Auto-elevate to root if not already running as root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi
# ═══════════════════════════════════════════════════════════════════════════════
# deploy.sh — Unified VPS Deployment Menu
# v1.0.0 | Usage: ./deploy.sh [optional-tool-name]
#
# Interactive menu to choose and deploy any of the supported self-hosting
# platforms. Individual scripts must be in the same directory or will be
# downloaded from the GitHub repository.
#
# Direct usage: ./deploy.sh portainer
#               ./deploy.sh dockge
#               ./deploy.sh coolify
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="deploy.sh"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ═══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION — Update this if you fork the repo
# ═══════════════════════════════════════════════════════════════════════════════
# GitHub repo raw URL base (change if you fork)
readonly GITHUB_REPO="https://raw.githubusercontent.com/shoyrock/VPS-Deployments/main"

# ═══════════════════════════════════════════════════════════════════════════════
# TOOL DEFINITIONS
# ═══════════════════════════════════════════════════════════════════════════════
declare -A TOOL_NAMES
declare -A TOOL_DESCRIPTIONS
declare -A TOOL_PORTS
declare -A TOOL_CATEGORIES

# --- NPM + Container Manager ---
TOOL_NAMES[1]="portainer"
TOOL_DESCRIPTIONS[1]="Nginx Proxy Manager + Portainer — Visual container management with proxy"
TOOL_PORTS[1]="80, 443, 81 (NPM admin)"
TOOL_CATEGORIES[1]="NPM + Container Manager"

TOOL_NAMES[2]="dockge"
TOOL_DESCRIPTIONS[2]="Nginx Proxy Manager + Dockge — Compose stack manager with proxy"
TOOL_PORTS[2]="80, 443, 81 (NPM admin), 5001 (Dockge direct)"
TOOL_CATEGORIES[2]="NPM + Container Manager"

# --- PaaS / App Platforms ---
TOOL_NAMES[3]="coolify"
TOOL_DESCRIPTIONS[3]="Coolify — Open-source PaaS (Heroku/Netlify alternative)"
TOOL_PORTS[3]="80, 443, 8000 (Coolify UI)"
TOOL_CATEGORIES[3]="PaaS / App Platform"

TOOL_NAMES[4]="dokploy"
TOOL_DESCRIPTIONS[4]="Dokploy — Docker Swarm orchestration platform"
TOOL_PORTS[4]="80, 443, 3000 (Dokploy UI)"
TOOL_CATEGORIES[4]="PaaS / App Platform"

TOOL_NAMES[5]="dokku"
TOOL_DESCRIPTIONS[5]="Dokku — Docker-powered mini-Heroku (git push to deploy)"
TOOL_PORTS[5]="80, 443, 22 (SSH/git)"
TOOL_CATEGORIES[5]="PaaS / App Platform"

TOOL_NAMES[6]="runtipi"
TOOL_DESCRIPTIONS[6]="Runtipi — Home server with 300+ one-click apps"
TOOL_PORTS[6]="80, 443"
TOOL_CATEGORIES[6]="PaaS / App Platform"

# --- Home Server OS ---
TOOL_NAMES[7]="casaos"
TOOL_DESCRIPTIONS[7]="CasaOS — Simple, elegant home server with app store"
TOOL_PORTS[7]="80 (CasaOS Web UI)"
TOOL_CATEGORIES[7]="Home Server OS"

TOOL_NAMES[8]="cosmos"
TOOL_DESCRIPTIONS[8]="Cosmos Server — All-in-one homelab suite with built-in proxy"
TOOL_PORTS[8]="80, 443, 4242/udp (VPN)"
TOOL_CATEGORIES[8]="Home Server OS"

# --- Debian Server Distributions ---
TOOL_NAMES[9]="yunohost"
TOOL_DESCRIPTIONS[9]="YunoHost — All-in-one Debian server (mail, LDAP, apps)"
TOOL_PORTS[9]="22, 25, 80, 443, 587, 993 (Debian 12 only)"
TOOL_CATEGORIES[9]="Debian Server Distro"

TOOL_NAMES[10]="freedombox"
TOOL_DESCRIPTIONS[10]="FreedomBox — Debian home server with Cockpit admin"
TOOL_PORTS[10]="80, 443, 9090 (Cockpit) (Debian 12 only)"
TOOL_CATEGORIES[10]="Debian Server Distro"

TOOL_NAMES[11]="authelia"
TOOL_DESCRIPTIONS[11]="Authelia — SSO + TOTP 2FA portal for all services behind NPM"
TOOL_PORTS[11]="9091 (internal, proxied via NPM)"
TOOL_CATEGORIES[11]="Authentication / MFA"

TOOL_NAMES[12]="harden"
TOOL_DESCRIPTIONS[12]="🔒 Harden VPS — SSH lockdown, CrowdSec, GeoIP block, auto-updates"
TOOL_PORTS[12]="—"
TOOL_CATEGORIES[12]="Security"

readonly TOOL_COUNT=12

# ═══════════════════════════════════════════════════════════════════════════════
# COLORS & UI
# ═══════════════════════════════════════════════════════════════════════════════
if [[ -t 1 ]]; then
  C_R='\033[0m'; C_B='\033[1m'; C_RED='\033[0;31m'; C_GRN='\033[0;32m'
  C_YEL='\033[0;33m'; C_BLU='\033[0;34m'; C_CYN='\033[0;36m'; C_DIM='\033[2m'
  C_MAG='\033[0;35m'
else
  C_R=''; C_B=''; C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_CYN=''; C_DIM=''
  C_MAG=''
fi

header() {
  printf "\n${C_B}${C_CYN}"
  printf "╔══════════════════════════════════════════════════════════════════╗\n"
  printf "║          VPS SELF-HOSTING DEPLOYMENT SUITE v%s              ║\n" "$SCRIPT_VERSION"
  printf "╠══════════════════════════════════════════════════════════════════╣\n"
  printf "║  One script to deploy them all — Docker, Fail2Ban, Firewall    ║\n"
  printf "╚══════════════════════════════════════════════════════════════════╝"
  printf "${C_R}\n\n"
}

print_menu() {
  # Quick setup option
  printf "\n${C_B}${C_GRN}── Quick Setup ──${C_R}\n"
  printf "  ${C_B} 0)${C_R} ${C_GRN}%-12s${C_R} %s\n" "lite" "NPM + Portainer (minimal, expand later)"
  printf "\n${C_DIM}  Or choose individual tools below:${C_R}"

  local current_category=""
  for i in $(seq 1 $TOOL_COUNT); do
    local category="${TOOL_CATEGORIES[$i]}"
    if [[ "$category" != "$current_category" ]]; then
      current_category="$category"
      printf "\n${C_B}${C_YEL}── %s ──${C_R}\n" "$category"
    fi
    printf "  ${C_B}%2d)${C_R} ${C_CYN}%-12s${C_R} %s\n" "$i" "${TOOL_NAMES[$i]}" "${TOOL_DESCRIPTIONS[$i]}"
  done
  printf "\n  ${C_B} q)${C_R} ${C_RED}Quit${C_R}\n"
  printf "\n"
}

print_tool_detail() {
  local num=$1
  printf "\n${C_B}${C_CYN}── %s ──${C_R}\n" "${TOOL_NAMES[$num]}"
  printf "  ${C_DIM}%s${C_R}\n" "${TOOL_DESCRIPTIONS[$num]}"
  printf "  ${C_B}Ports:${C_R} ${TOOL_PORTS[$num]}\n"
  printf "  ${C_B}Script:${C_R} deploy-${TOOL_NAMES[$num]}.sh\n\n"
}

# ═══════════════════════════════════════════════════════════════════════════════
# EXECUTION — always fetches latest from GitHub, falls back to local
# ═══════════════════════════════════════════════════════════════════════════════
# ═══════════════════════════════════════════════════════════════════════════════
# LITE BUNDLE — NPM + Portainer only (NON-DESTRUCTIVE)
# ═══════════════════════════════════════════════════════════════════════════════
run_lite_bundle() {
  header
  printf "${C_B}${C_GRN}Lite Bundle Setup${C_R}\n"
  printf "Deploys: Nginx Proxy Manager + Portainer (minimal, ~200MB RAM)\n"
  printf "${C_YEL}Non-destructive:${C_R} existing containers are preserved.\n\n"

  # Show what's already installed
  local has_npm=false has_portainer=false
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^npm$' && has_npm=true
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^portainer$' && has_portainer=true

  if $has_npm && $has_portainer; then
    printf "${C_GRN}✔${C_R} NPM and Portainer are already running.\n"
    printf "  NPM Admin: http://$(hostname -I | awk '{print $1}'):81\n\n"
    return 0
  fi

  $has_npm && printf "${C_GRN}✔${C_R} NPM already running — skipping\n"
  $has_portainer && printf "${C_GRN}✔${C_R} Portainer already running — skipping\n"

  read -rp "Deploy missing components? [y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { printf "Aborted.\n"; return 1; }

  # Ensure Docker and network exist
  command -v docker &>/dev/null || { printf "${C_RED}Docker required.${C_R}\n"; return 1; }
  if ! docker network ls --format '{{.Name}}' | grep -q '^proxy$'; then
    docker network create proxy || { printf "${C_RED}Failed to create proxy network.${C_R}\n"; return 1; }
    printf "${C_GRN}✔${C_R} Created proxy network\n"
  fi

  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<VPS_IP>")

  # Deploy NPM if missing
  if ! $has_npm; then
    printf "\n${C_B}▶ Deploying NPM...${C_R}\n"
    docker rm -f npm 2>/dev/null || true
    mkdir -p /opt/npm/data /opt/npm/letsencrypt /opt/npm/logs
    docker run -d \
      --name npm \
      --hostname npm \
      --restart always \
      --network proxy \
      -p '0.0.0.0:80:80' \
      -p '0.0.0.0:443:443' \
      -p '0.0.0.0:81:81' \
      -v /opt/npm/data:/data \
      -v /opt/npm/letsencrypt:/etc/letsencrypt \
      -v /opt/npm/logs:/var/log/nginx \
      -e TZ=America/New_York \
      jc21/nginx-proxy-manager:latest
    printf "${C_GRN}✔${C_R} NPM deployed — http://${ip}:81 (admin@example.com / changeme)\n"
  fi

  # Deploy Portainer if missing
  if ! $has_portainer; then
    printf "\n${C_B}▶ Deploying Portainer...${C_R}\n"
    docker rm -f portainer 2>/dev/null || true
    docker run -d \
      --name portainer \
      --hostname portainer \
      --restart always \
      --network proxy \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v portainer_data:/data \
      -e TZ=America/New_York \
      portainer/portainer-ce:latest
    printf "${C_GRN}✔${C_R} Portainer deployed — add proxy host in NPM: portainer.YOURDOMAIN → http://portainer:9000\n"
  fi

  printf "\n${C_B}${C_GRN}Lite bundle ready!${C_R}\n"
  printf "  NPM:      http://${ip}:81\n"
  printf "  Portainer internal: http://portainer:9000\n\n"
  printf "To add 2FA (Authelia): ./deploy.sh authelia\n"
  printf "To add more tools:     ./deploy.sh\n"
  printf "\n${C_DIM}Press Enter to return to menu...${C_R}"
  read -r
}

_run_script() {
  local script_path=$1
  local script_name=$(basename "$script_path")
  # Show appropriate warning based on script type
  case "$script_name" in
    harden.sh)
      printf "${C_YEL}!${C_R} This will harden system security (firewall, CrowdSec, auto-updates).\n"
      printf "  ${C_GRN}✔${C_R} Docker containers will NOT be affected.\n"
      ;;
    deploy-authelia.sh)
      printf "${C_YEL}!${C_R} This will add the Authelia 2FA container to your existing setup.\n"
      printf "  ${C_GRN}✔${C_R} Existing containers will NOT be affected.\n"
      ;;
    *)
      printf "${C_YEL}⚠${C_R} This will install/configure services. Existing containers may be ${C_RED}DESTROYED${C_R}.\n"
      ;;
  esac
  read -rp "Proceed? [y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { printf "Aborted.\n"; return 1; }
  printf "\n${C_CYN}▶ Starting ${script_name}...${C_R}\n\n"
  bash "$script_path"
}

run_tool() {
  local name=$1
  local script_name=""
  local url=""
  local local_script=""
  local tmp_script=""

  # Determine script name
  if [[ "$name" == "harden" ]]; then
    script_name="harden.sh"
    local_script="${SCRIPT_DIR}/harden.sh"
  else
    script_name="deploy-${name}.sh"
    local_script="${SCRIPT_DIR}/deploy-${name}.sh"
  fi

  url="${GITHUB_REPO}/${script_name}"
  tmp_script="/tmp/${script_name}.new"

  # Always download latest from GitHub — GitHub version wins over local
  printf "${C_CYN}> Downloading latest ${script_name}...${C_R}\n"
  if curl -fsSL -o "$tmp_script" "$url" 2>/dev/null; then
    chmod +x "$tmp_script"
    if [[ -f "$local_script" ]] && diff -q "$tmp_script" "$local_script" >/dev/null 2>&1; then
      printf "${C_GRN}+${C_R} ${script_name} is up to date\n"
      rm -f "$tmp_script"
    else
      [[ -f "$local_script" ]] && printf "${C_YEL}!${C_R} Updating ${script_name} from GitHub\n"
      [[ ! -f "$local_script" ]] && printf "${C_GRN}+${C_R} Downloaded ${script_name}\n"
      mv -f "$tmp_script" "$local_script" 2>/dev/null || { cp -f "$tmp_script" "$local_script" && rm -f "$tmp_script"; }
    fi
    _run_script "$local_script"
  else
    # GitHub unreachable — fall back to local copy
    printf "${C_RED}x${C_R} Could not download ${script_name} from GitHub\n"
    if [[ -f "$local_script" ]]; then
      printf "${C_YEL}!${C_R} Using local ${script_name} (may be outdated)\n"
      _run_script "$local_script"
    else
      printf "${C_RED}x${C_R} ${script_name} not found locally or on GitHub\n"
      return 1
    fi
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# COMMAND-LINE MODE
# ═══════════════════════════════════════════════════════════════════════════════
if [[ $# -gt 0 ]]; then
  # Map common aliases
  requested="$1"
  case "$requested" in
    portainer|npm|vps)                requested="portainer" ;;
    dockge)                           requested="dockge" ;;
    coolify)                          requested="coolify" ;;
    dokploy)                          requested="dokploy" ;;
    dokku)                            requested="dokku" ;;
    runtipi|tipi)                     requested="runtipi" ;;
    casaos|casa)                      requested="casaos" ;;
    cosmos)                           requested="cosmos" ;;
    yunohost|ynh)                     requested="yunohost" ;;
    freedombox|fbx)                   requested="freedombox" ;;
    lite|light|minimal|quick)              requested="lite" ;;
    authelia|mfa|2fa|sso)             requested="authelia" ;;
    harden|security|lockdown)         requested="harden" ;;
    *)
      printf "${C_RED}Unknown tool: ${requested}${C_R}\n"
      printf "Run ${C_B}./deploy.sh${C_R} without arguments for the interactive menu.\n"
      printf "\nAvailable tools:\n"
      for i in $(seq 1 $TOOL_COUNT); do
        printf "  ${C_CYN}%-12s${C_R} %s\n" "${TOOL_NAMES[$i]}" "${TOOL_DESCRIPTIONS[$i]}"
      done
      exit 1
      ;;
  esac

  # Handle lite bundle
  if [[ "$requested" == "lite" ]]; then
    run_lite_bundle
    exit $?
  fi

  header
  # Find the tool number
  for i in $(seq 1 $TOOL_COUNT); do
    if [[ "${TOOL_NAMES[$i]}" == "$requested" ]]; then
      print_tool_detail "$i"
      run_tool "$requested"
      exit $?
    fi
  done
fi

# ═══════════════════════════════════════════════════════════════════════════════
# INTERACTIVE MENU MODE
# ═══════════════════════════════════════════════════════════════════════════════
while true; do
  header
  print_menu

  read -rp "Enter [0] for lite bundle, [1-${TOOL_COUNT}] for individual tool, or [q] to quit: " choice

  # Handle quit
  [[ "$choice" =~ ^[Qq]$ ]] && { printf "\n${C_DIM}Goodbye!${C_R}\n\n"; exit 0; }

  # Handle lite bundle (0)
  if [[ "$choice" == "0" ]]; then
    run_lite_bundle
    continue
  fi

  # Validate number
  if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le $TOOL_COUNT ]]; then
    print_tool_detail "$choice"
    run_tool "${TOOL_NAMES[$choice]}"
    printf "\n${C_DIM}Press Enter to return to menu...${C_R}"
    read -r
  else
    printf "${C_RED}Invalid choice. Please enter 0-${TOOL_COUNT} or q.${C_R}\n"
    sleep 1
  fi
done
