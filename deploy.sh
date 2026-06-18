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
#               ./deploy.sh dockhand
#               ./deploy.sh netbird
#               ./deploy.sh harden
#               ./deploy.sh add-domain example.com   # post-deploy utility (takes a domain)
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="deploy.sh"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ═══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION — Update this if you fork the repo
# ═══════════════════════════════════════════════════════════════════════════════
# GitHub repo raw URL base — change to your fork's URL
readonly GITHUB_REPO="https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main"

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
TOOL_PORTS[1]="80, 443, 81"
TOOL_CATEGORIES[1]="NPM + Container Manager"

TOOL_NAMES[2]="dockge"
TOOL_DESCRIPTIONS[2]="Nginx Proxy Manager + Dockge — Compose stack manager with proxy"
TOOL_PORTS[2]="80, 443, 81"
TOOL_CATEGORIES[2]="NPM + Container Manager"

TOOL_NAMES[3]="dockhand"
TOOL_DESCRIPTIONS[3]="Nginx Proxy Manager + Dockhand — Next-gen Docker manager with SSO"
TOOL_PORTS[3]="80, 443, 81"
TOOL_CATEGORIES[3]="NPM + Container Manager"

# --- NetBird + Authentik (Zero-Trust) ---
TOOL_NAMES[4]="netbird"
TOOL_DESCRIPTIONS[4]="NetBird + Authentik + Dockhand — Zero-trust mesh, OIDC SSO, Traefik edge"
TOOL_PORTS[4]="80, 443 + P2P 3478/udp, 49152-65535/udp, 33080"
TOOL_CATEGORIES[4]="NetBird + Authentik (Zero-Trust)"

# --- PaaS / App Platforms ---
TOOL_NAMES[5]="coolify"
TOOL_DESCRIPTIONS[5]="Coolify — Open-source PaaS (Heroku/Netlify alternative)"
TOOL_PORTS[5]="80, 443, 81"
TOOL_CATEGORIES[5]="PaaS / App Platform"

TOOL_NAMES[6]="dokploy"
TOOL_DESCRIPTIONS[6]="Dokploy — Docker Swarm orchestration platform"
TOOL_PORTS[6]="80, 443, 81"
TOOL_CATEGORIES[6]="PaaS / App Platform"

# --- Home Server OS ---
TOOL_NAMES[7]="casaos"
TOOL_DESCRIPTIONS[7]="CasaOS — Simple, elegant home server with app store"
TOOL_PORTS[7]="80, 443, 81"
TOOL_CATEGORIES[7]="Home Server OS"

TOOL_NAMES[8]="runtipi"
TOOL_DESCRIPTIONS[8]="Runtipi — Home server with 300+ one-click apps"
TOOL_PORTS[8]="80, 443, 81"
TOOL_CATEGORIES[8]="Home Server OS"

TOOL_NAMES[9]="cosmos"
TOOL_DESCRIPTIONS[9]="Cosmos Server — All-in-one homelab suite with built-in proxy"
TOOL_PORTS[9]="80, 443, 81"
TOOL_CATEGORIES[9]="Home Server OS"

# --- Debian Server Distributions ---
TOOL_NAMES[10]="yunohost"
TOOL_DESCRIPTIONS[10]="YunoHost — All-in-one Debian server (mail, LDAP, apps)"
TOOL_PORTS[10]="80, 443, 81 (Debian 12 only)"
TOOL_CATEGORIES[10]="Debian Server Distro"

TOOL_NAMES[11]="freedombox"
TOOL_DESCRIPTIONS[11]="FreedomBox — Debian home server with Cockpit admin"
TOOL_PORTS[11]="80, 443, 81 (Debian 12 only)"
TOOL_CATEGORIES[11]="Debian Server Distro"

# --- Security & Utilities (run AFTER deploying a platform) ---
TOOL_NAMES[12]="harden"
TOOL_DESCRIPTIONS[12]="🔒 Harden VPS — SSH lockdown, CrowdSec, GeoIP block, auto-updates"
TOOL_PORTS[12]="—"
TOOL_CATEGORIES[12]="Security & Utilities"

TOOL_NAMES[13]="add-domain"
TOOL_DESCRIPTIONS[13]="➕ Add another domain to a running NPM+Authelia stack (extra hosts + SSO realm)"
TOOL_PORTS[13]="—"
TOOL_CATEGORIES[13]="Security & Utilities"

readonly TOOL_COUNT=13

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
  printf "║           VPS SELF-HOSTING DEPLOYMENT SUITE v%s               ║\n" "$SCRIPT_VERSION"
  printf "╠══════════════════════════════════════════════════════════════════╣\n"
  printf "║   One script to deploy them all — Docker, CrowdSec, Firewall     ║\n"
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

# Map a tool name to its actual script filename. Platforms use deploy-<name>.sh;
# the utilities have their own names.
_script_for_name() {
  case "$1" in
    harden)     echo "harden.sh" ;;
    add-domain) echo "add-domain.sh" ;;
    *)          echo "deploy-$1.sh" ;;
  esac
}

print_tool_detail() {
  local num=$1
  printf "\n${C_B}${C_CYN}── %s ──${C_R}\n" "${TOOL_NAMES[$num]}"
  printf "  ${C_DIM}%s${C_R}\n" "${TOOL_DESCRIPTIONS[$num]}"
  printf "  ${C_B}Ports:${C_R} ${TOOL_PORTS[$num]}\n"
  printf "  ${C_B}Script:${C_R} %s\n\n" "$(_script_for_name "${TOOL_NAMES[$num]}")"
}

# ═══════════════════════════════════════════════════════════════════════════════
# EXECUTION — always fetches latest from GitHub, falls back to local
# ═══════════════════════════════════════════════════════════════════════════════
_run_script() {
  local script_path=$1; shift
  local script_name; script_name=$(basename "$script_path")
  # Show appropriate warning based on script type
  case "$script_name" in
    harden.sh)
      printf "${C_YEL}!${C_R} This will harden system security (firewall, CrowdSec, auto-updates).\n"
      printf "  ${C_GRN}✔${C_R} Docker containers will NOT be affected.\n"
      ;;
    add-domain.sh)
      printf "${C_GRN}✔${C_R} Additive + safe on a live system — adds proxy hosts + an SSO realm for a new domain.\n"
      printf "  ${C_GRN}✔${C_R} Existing domains, hosts and certs are NOT touched.\n"
      ;;
    *)
      printf "${C_YEL}⚠${C_R} This will install/configure services. Existing containers may be ${C_RED}DESTROYED${C_R}.\n"
      ;;
  esac
  read -rp "Proceed? [y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { printf "Aborted.\n"; return 1; }
  printf "\n${C_CYN}▶ Starting ${script_name}...${C_R}\n\n"
  bash "$script_path" "$@"
}

run_tool() {
  local name=$1; shift || true
  local extra_args=("$@")
  local script_name local_script url tmp_script
  script_name="$(_script_for_name "$name")"
  local_script="${SCRIPT_DIR}/${script_name}"
  url="${GITHUB_REPO}/${script_name}"
  tmp_script="$(mktemp "/tmp/${script_name}.XXXXXX")"

  # add-domain needs a target domain; prompt if none was passed on the CLI.
  if [[ "$name" == "add-domain" && ${#extra_args[@]} -eq 0 ]]; then
    local dom
    read -rp "Root domain to add (e.g. example.com): " dom
    [[ -n "$dom" ]] || { printf "${C_RED}x${C_R} No domain given. Aborted.\n"; rm -f "$tmp_script"; return 1; }
    extra_args=("$dom")
  fi

  # Always download latest from GitHub — GitHub version wins over local
  printf "${C_CYN}> Downloading latest ${script_name}...${C_R}\n"
  if curl -fsSL -o "$tmp_script" "$url" 2>/dev/null; then
    chmod +x "$tmp_script"
    # Fresh GitHub copy ALWAYS wins: erase the local script and replace it, so a
    # stale local file can never be reused. No diff / "up to date" shortcut.
    rm -f "$local_script" 2>/dev/null || true
    mv -f "$tmp_script" "$local_script" 2>/dev/null || { cp -f "$tmp_script" "$local_script"; rm -f "$tmp_script"; }
    chmod +x "$local_script" 2>/dev/null || true
    printf "${C_GRN}+${C_R} Fetched fresh ${script_name} from GitHub (replaced any local copy)\n"
    _run_script "$local_script" ${extra_args[@]+"${extra_args[@]}"}
  else
    # GitHub unreachable — fall back to local copy
    printf "${C_RED}x${C_R} Could not download ${script_name} from GitHub\n"
    rm -f "$tmp_script" 2>/dev/null || true
    if [[ -f "$local_script" ]]; then
      printf "${C_YEL}!${C_R} Using local ${script_name} (may be outdated)\n"
      _run_script "$local_script" ${extra_args[@]+"${extra_args[@]}"}
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
  requested="$1"; shift || true
  case "$requested" in
    portainer|npm|vps)                requested="portainer" ;;
    dockge)                           requested="dockge" ;;
    dockhand)                         requested="dockhand" ;;
    netbird|authentik|zerotrust|nb)   requested="netbird" ;;
    coolify)                          requested="coolify" ;;
    dokploy)                          requested="dokploy" ;;

    runtipi|tipi)                     requested="runtipi" ;;
    casaos|casa)                      requested="casaos" ;;
    cosmos)                           requested="cosmos" ;;
    yunohost|ynh)                     requested="yunohost" ;;
    freedombox|fbx)                   requested="freedombox" ;;
    harden|security|lockdown)         requested="harden" ;;
    add-domain|adddomain|domain)      requested="add-domain" ;;
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
      run_tool "$requested" "$@"
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

  read -rp "Enter [1-${TOOL_COUNT}] for tool, or [q] to quit: " choice

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
