#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# install.sh — one-line bootstrapper for the VPS Self-Hosting Deployment Suite
#
#   curl -fsSL https://raw.githubusercontent.com/shoyrock/VPS-Deployments/main/install.sh | bash
#   wget -qO-  https://raw.githubusercontent.com/shoyrock/VPS-Deployments/main/install.sh | bash
#
# Jump straight to a tool (skip the menu) by passing its name:
#   curl -fsSL .../install.sh | bash -s -- dockhand-authentik
#   curl -fsSL .../install.sh | bash -s -- harden
#   curl -fsSL .../install.sh | bash -s -- verify
#
# What it does: ensures you're root, makes sure curl + ca-certificates exist,
# downloads deploy.sh (the menu) into /opt/vps-deploy, and launches it. deploy.sh
# then fetches each individual platform/utility script from GitHub on demand.
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# Change this if you fork the repo.
REPO_RAW="https://raw.githubusercontent.com/shoyrock/VPS-Deployments/main"
DEST_DIR="/opt/vps-deploy"

# ---- colours (only if attached to a terminal) --------------------------------
c_g=''; c_y=''; c_r=''; c_b=''; c_c=''; c_n=''
if [ -t 1 ]; then
  c_g=$'\e[0;32m'; c_y=$'\e[0;33m'; c_r=$'\e[0;31m'; c_b=$'\e[1m'; c_c=$'\e[0;36m'; c_n=$'\e[0m'
fi
say()  { printf '%s\n' "$*"; }
info() { printf '%s[*]%s %s\n' "$c_c" "$c_n" "$*"; }
ok()   { printf '%s[ok]%s %s\n' "$c_g" "$c_n" "$*"; }
warn() { printf '%s[!]%s %s\n'  "$c_y" "$c_n" "$*"; }
die()  { printf '%s[x]%s %s\n'  "$c_r" "$c_n" "$*" >&2; exit 1; }

# A downloader (the user already used one to fetch this script, so one exists).
_dl() {  # _dl <url> -> stdout
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$1"
  elif command -v wget >/dev/null 2>&1; then wget -qO- "$1"
  else return 1; fi
}

say ""
printf '%s%s============================================================%s\n' "$c_b" "$c_c" "$c_n"
printf '  %s%sVPS SELF-HOSTING DEPLOYMENT SUITE%s  %sinstaller%s\n' "$c_b" "$c_c" "$c_n" "$c_n" "$c_n"
printf '%s%s============================================================%s\n' "$c_b" "$c_c" "$c_n"

# ---- 1. must be Linux --------------------------------------------------------
[ "$(uname -s 2>/dev/null)" = "Linux" ] || die "This installer is for Linux VPS hosts."

# ---- 2. must be root (re-fetch + re-exec under sudo if not) -------------------
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || die "Run as root, or install sudo first."
  warn "Not root — re-running the installer with sudo..."
  # This script came in over a pipe, so $0 is not a file we can re-exec. Re-fetch
  # the installer text and hand it to sudo bash, forwarding any tool argument.
  script="$(_dl "${REPO_RAW}/install.sh")" || die "Could not re-download the installer."
  exec sudo bash -c "$script" -- "$@"
fi

# ---- 3. ensure curl + ca-certificates (deploy.sh downloads tools with curl) --
if ! command -v curl >/dev/null 2>&1; then
  info "Installing curl..."
  if   command -v apt-get >/dev/null 2>&1; then apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates
  elif command -v dnf     >/dev/null 2>&1; then dnf install -y -q curl ca-certificates
  elif command -v yum     >/dev/null 2>&1; then yum install -y -q curl ca-certificates
  else die "curl is missing and no supported package manager (apt/dnf/yum) was found."; fi
  ok "curl installed"
fi

# ---- 4. fetch deploy.sh into a persistent dir --------------------------------
mkdir -p "$DEST_DIR"
info "Downloading deploy.sh ..."
if ! curl -fsSL -o "${DEST_DIR}/deploy.sh" "${REPO_RAW}/deploy.sh"; then
  die "Failed to download deploy.sh from ${REPO_RAW}. Check the URL / network."
fi
chmod +x "${DEST_DIR}/deploy.sh"
ok "Installed to ${DEST_DIR}/deploy.sh"
say ""

# ---- 5. launch the menu ------------------------------------------------------
# Read keypresses from the real terminal even though this installer arrived over
# a pipe (curl | bash leaves stdin pointing at the pipe, not the keyboard).
if [ -e /dev/tty ]; then
  exec bash "${DEST_DIR}/deploy.sh" "$@" < /dev/tty
else
  warn "No terminal detected (non-interactive). Pass a tool name to run it, e.g.:"
  warn "  curl -fsSL ${REPO_RAW}/install.sh | bash -s -- dockhand-authentik"
  exec bash "${DEST_DIR}/deploy.sh" "$@"
fi
