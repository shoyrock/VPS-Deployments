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

readonly TOOL_COUNT=11

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
# EXECUTION
# ═══════════════════════════════════════════════════════════════════════════════
run_tool() {
  local name=$1
  local script="${SCRIPT_DIR}/deploy-${name}.sh"

  # Check if script exists locally
  if [[ -f "$script" ]]; then
    printf "${C_GRN}✔${C_R} Found ${C_B}deploy-${name}.sh${C_R} locally.\n"
    printf "${C_YEL}⚠${C_R} This will install Docker (if needed), ${name}, Fail2Ban, and firewall rules.\n"
    printf "${C_YEL}⚠${C_R} Existing Docker containers and data will be ${C_RED}DESTROYED${C_R}.\n"
    read -rp "Proceed? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { printf "Aborted.\n"; return 1; }
    printf "\n${C_CYN}▶ Starting deployment of ${name}...${C_R}\n\n"
    exec sudo bash "$script"
  fi

  # Not found locally — offer to download
  printf "${C_YEL}⚠${C_R} deploy-${name}.sh not found in ${SCRIPT_DIR}\n"
  printf "  ${C_DIM}Would you like to download it from GitHub?${C_R}\n"
  read -rp "Download and run? [y/N]: " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    local url="${GITHUB_REPO}/deploy-${name}.sh"
    local tmp_script="/tmp/deploy-${name}.sh"
    printf "${C_CYN}▶ Downloading from ${url}...${C_R}\n"
    if curl -fsSL -o "$tmp_script" "$url" 2>/dev/null; then
      chmod +x "$tmp_script"
      printf "${C_GRN}✔${C_R} Downloaded.\n"
      printf "${C_YEL}⚠${C_R} This will install Docker (if needed), ${name}, Fail2Ban, and firewall rules.\n"
      printf "${C_YEL}⚠${C_R} Existing Docker containers and data will be ${C_RED}DESTROYED${C_R}.\n"
      read -rp "Proceed? [y/N]: " confirm2
      [[ "$confirm2" =~ ^[Yy]$ ]] || { printf "Aborted.\n"; rm -f "$tmp_script"; return 1; }
      printf "\n${C_CYN}▶ Starting deployment of ${name}...${C_R}\n\n"
      exec sudo bash "$tmp_script"
    else
      printf "${C_RED}✖${C_R} Failed to download deploy-${name}.sh\n"
      printf "  ${C_DIM}Check your internet connection and the GitHub URL:${C_R}\n"
      printf "  ${C_DIM}${url}${C_R}\n"
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
