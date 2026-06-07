#!/usr/bin/env bash
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

TOOL_NAMES[11]="caprover"
TOOL_DESCRIPTIONS[11]="CapRover — Free self-hostable Heroku alternative (Docker Swarm)"
TOOL_PORTS[11]="80, 443, 3000, 2377, 7946, 4789 (Swarm)"
TOOL_CATEGORIES[11]="PaaS / App Platform"

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
_run_script() {
  local script_path=$1
  local script_name=$(basename "$script_path")
  printf "${C_YEL}⚠${C_R} This will install/configure services. Existing containers may be ${C_RED}DESTROYED${C_R}.\n"
  read -rp "Proceed? [y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { printf "Aborted.\n"; return 1; }
  printf "\n${C_CYN}▶ Starting ${script_name}...${C_R}\n\n"
  exec sudo bash "$script_path"
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

  # Always try to download the latest version first
  printf "${C_CYN}▶ Checking for latest ${script_name}...${C_R}\n"
  if curl -fsSL -o "$tmp_script" "$url" 2>/dev/null; then
    chmod +x "$tmp_script"
    # Compare with local copy (if exists)
    if [[ -f "$local_script" ]] && diff -q "$tmp_script" "$local_script" >/dev/null 2>&1; then
      printf "${C_GRN}✔${C_R} ${script_name} is up to date.\n"
      rm -f "$tmp_script"
      _run_script "$local_script"
    else
      [[ -f "$local_script" ]] && printf "${C_YEL}⚠${C_R} Newer version found — updating ${script_name}\n"
      [[ ! -f "$local_script" ]] && printf "${C_GRN}✔${C_R} Downloaded ${script_name}\n"
      mv -f "$tmp_script" "$local_script" 2>/dev/null || { cp -f "$tmp_script" "$local_script" && rm -f "$tmp_script"; }
      _run_script "$local_script"
    fi
  else
    # Download failed — fall back to local copy
    printf "${C_RED}✖${C_R} Could not download latest ${script_name} from GitHub.\n"
    if [[ -f "$local_script" ]]; then
      printf "${C_YEL}⚠${C_R} Using local copy (may be outdated).\n"
      _run_script "$local_script"
    else
      printf "${C_RED}✖${C_R} ${script_name} not found locally either.\n"
      printf "  ${C_DIM}Check internet connection and GitHub URL:${C_R} ${url}\n"
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
    caprover)                         requested="caprover" ;;
    harden|security|lockdown)          requested="harden" ;;
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

  read -rp "Enter number [1-${TOOL_COUNT}] or [q] to quit: " choice

  # Handle quit
  [[ "$choice" =~ ^[Qq]$ ]] && { printf "\n${C_DIM}Goodbye!${C_R}\n\n"; exit 0; }

  # Validate number
  if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le $TOOL_COUNT ]]; then
    print_tool_detail "$choice"
    run_tool "${TOOL_NAMES[$choice]}"
    printf "\n${C_DIM}Press Enter to return to menu...${C_R}"
    read -r
  else
    printf "${C_RED}Invalid choice. Please enter 1-${TOOL_COUNT} or q.${C_R}\n"
    sleep 1
  fi
done
