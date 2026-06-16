#!/usr/bin/env bash
# add-domain.sh — additively attach ANOTHER root domain to an existing
# deploy-*.sh stack (Nginx Proxy Manager + Authelia).
#
# SAFE on a live system, by design:
#   * Never purges or edits existing proxy hosts / certificates.
#   * Idempotent — re-running skips anything already in place.
#   * Authelia config is backed up before editing and auto-rolled-back if the
#     container fails its health check afterwards (a broken edit can never leave
#     SSO down).
#   * Reuses the existing, domain-agnostic Authelia nginx snippets — no per-domain
#     nginx changes.
#
# Two domains can coexist indefinitely; or add the new one, verify, then delete
# the old hosts/certs in the NPM UI at your leisure.
#
# Usage:
#   ./add-domain.sh <root-domain> [options]
#
# Options:
#   --app  SUB:HOST:PORT   Create SUB.<root-domain> -> HOST:PORT, Authelia-protected.
#                          Repeatable.  e.g. --app portainer:portainer:9000
#   --open SUB:HOST:PORT   Same, but PUBLIC (no Authelia).  Repeatable.
#   --no-authelia          Do not wire an Authelia SSO realm for this domain
#                          (use for domains that don't need 2FA).
#   --email ADDR           Let's Encrypt email (default: admin@<root-domain>).
#   --stack DIR            NPM stack dir (default: auto-detect under /opt).
#   --dry-run              Show the plan and change nothing.
#   -h | --help            This help.
#
# Notes:
#   * Point DNS first:  *.<root-domain>  ->  this server's IP (cert issuance needs it).
#   * An  authelia.<root-domain>  host is created automatically unless --no-authelia.
#   * Run AFTER a deploy-*.sh install; it talks to the live NPM on 127.0.0.1:81.
set -euo pipefail
IFS=$'\n\t'

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then exec sudo -E bash "$0" "$@"; fi

# ---- pretty output ---------------------------------------------------------
if [[ -t 1 ]]; then
  C_RST=$'\033[0m'; C_B=$'\033[1m'; C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'
  C_R=$'\033[1;31m'; C_BL=$'\033[1;34m'
else
  C_RST=''; C_B=''; C_G=''; C_Y=''; C_R=''; C_BL=''
fi
# All logging goes to stderr so command-substitution ( id=$(npm_add_host ...) )
# captures ONLY the function's echoed return value, never log text.
info()    { printf "${C_BL}[INFO]${C_RST} %s\n" "$*" >&2; }
warn()    { printf "${C_Y}[WARN]${C_RST} %s\n" "$*" >&2; }
err()     { printf "${C_R}[ERR]${C_RST}  %s\n" "$*" >&2; }
success() { printf "${C_G}[OK]${C_RST}   %s\n" "$*" >&2; }
fatal()   { err "$*"; exit 1; }
usage()   { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }

# ---- args ------------------------------------------------------------------
ROOT=""; EMAIL=""; STACK_DIR="${STACK_DIR:-}"; DO_AUTHELIA=true; DRY=false
declare -a APPS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)         [[ $# -ge 2 ]] || fatal "--app needs SUB:HOST:PORT";  APPS+=("two_factor|$2"); shift 2;;
    --open)        [[ $# -ge 2 ]] || fatal "--open needs SUB:HOST:PORT"; APPS+=("public|$2");     shift 2;;
    --no-authelia) DO_AUTHELIA=false; shift;;
    --email)       [[ $# -ge 2 ]] || fatal "--email needs ADDR"; EMAIL="$2"; shift 2;;
    --stack)       [[ $# -ge 2 ]] || fatal "--stack needs DIR";  STACK_DIR="$2"; shift 2;;
    --dry-run)     DRY=true; shift;;
    -h|--help)     usage; exit 0;;
    -*)            fatal "Unknown option: $1 (see --help)";;
    *)             [[ -z "$ROOT" ]] && ROOT="$1" || fatal "Unexpected argument: $1"; shift;;
  esac
done
[[ -n "$ROOT" ]] || { usage; exit 1; }

# normalise + validate the root domain (same rule as the deploy scripts)
ROOT=$(printf '%s' "$ROOT" | sed 's#https\?://##; s#/.*##' | tr -d ' ')
[[ "$ROOT" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] \
  || fatal "Invalid domain: '$ROOT'"
EMAIL="${EMAIL:-admin@${ROOT}}"

# ---- deps ------------------------------------------------------------------
for b in jq curl docker; do command -v "$b" &>/dev/null || fatal "Missing dependency: $b"; done

# ---- locate the live stack -------------------------------------------------
detect_stack() {
  [[ -n "$STACK_DIR" && -f "$STACK_DIR/docker-compose.npm.yml" ]] && return 0
  local d
  for d in /opt/*-stack /opt/npm; do
    [[ -f "$d/docker-compose.npm.yml" ]] && { STACK_DIR="$d"; return 0; }
  done
  fatal "Could not find an NPM stack under /opt (looked for docker-compose.npm.yml). Pass --stack DIR."
}
detect_stack
AUTHELIA_CFG="${STACK_DIR}/authelia/config/configuration.yml"
info "Using stack: ${C_B}${STACK_DIR}${C_RST}"

docker ps --format '{{.Names}}' | grep -qx npm \
  || fatal "NPM container 'npm' is not running — deploy the stack first."

# ---- NPM API ---------------------------------------------------------------
NPM_API_BASE="http://127.0.0.1:81/api"
NPM_TOKEN=""
_npm_api() {
  local path="$1"; shift
  local args=(-s --max-time 60 -H "Content-Type: application/json")
  [[ -n "$NPM_TOKEN" ]] && args+=(-H "Authorization: Bearer ${NPM_TOKEN}")
  curl "${args[@]}" "${NPM_API_BASE}${path}" "$@"
}
npm_login() {
  local pass="changeme" pf="${STACK_DIR}/.npm_admin_password" resp
  [[ -f "$pf" ]] && pass="$(tr -d '\n' < "$pf")"
  resp=$(_npm_api /tokens -d "$(jq -nc --arg s "$pass" '{identity:"admin@example.com",secret:$s}')" 2>/dev/null) || true
  NPM_TOKEN=$(echo "$resp" | jq -r '.token // empty' 2>/dev/null || true)
  [[ -n "$NPM_TOKEN" ]] || fatal "NPM API login failed (tried ${pf} then 'changeme'). Is NPM admin reachable on :81?"
}
npm_host_id() {  # <fqdn> -> existing proxy-host id, or empty
  _npm_api /nginx/proxy-hosts 2>/dev/null \
    | jq -r --arg d "$1" '.[]? | select(.domain_names | index($d) != null) | .id' 2>/dev/null | head -1 || true
}
npm_add_host() {  # <fqdn> <host> <port> <protect:true|false>  -> prints id
  local fqdn="$1" host="$2" port="$3" protect="$4" adv="" id json resp
  id=$(npm_host_id "$fqdn")
  if [[ -n "$id" ]]; then info "Proxy host already exists: ${fqdn} (id ${id}) — leaving as-is"; echo "$id"; return 0; fi
  [[ "$protect" == "true" ]] && adv=$'include /data/nginx/custom/authelia-location.conf;\ninclude /data/nginx/custom/authelia-authrequest.conf;'
  json=$(jq -nc --arg d "$fqdn" --arg h "$host" --argjson p "$port" --arg adv "$adv" '{
    domain_names:[$d], forward_scheme:"http", forward_host:$h, forward_port:$p,
    access_list_id:0, certificate_id:0, ssl_forced:false, caching_enabled:false,
    block_exploits:true, allow_websocket_upgrade:true, http2_support:false,
    hsts_enabled:false, hsts_subdomains:false, advanced_config:$adv }')
  resp=$(_npm_api /nginx/proxy-hosts -X POST -d "$json") || true
  id=$(echo "$resp" | jq -r '.id // empty')
  [[ -n "$id" ]] || { warn "Create failed for ${fqdn}: $(echo "$resp" | jq -r '.error.message // .message // "unknown"' 2>/dev/null)"; return 1; }
  success "Created proxy host: ${fqdn} -> ${host}:${port} (protected=${protect})"
  echo "$id"
}
npm_enable_ssl() {  # <id> <fqdn>
  local id="$1" fqdn="$2" cur json resp cert
  cur=$(_npm_api "/nginx/proxy-hosts/${id}" 2>/dev/null | jq -r '.certificate_id // 0' 2>/dev/null || echo 0)
  if [[ "$cur" =~ ^[0-9]+$ && "$cur" -gt 0 ]]; then info "SSL already enabled on ${fqdn} (cert ${cur})"; return 0; fi
  json=$(jq -nc --arg e "$EMAIL" --arg d "$fqdn" '{provider:"letsencrypt", nice_name:$d, domain_names:[$d],
    meta:{letsencrypt_email:$e, letsencrypt_agree:true, dns_challenge:false}}')
  info "Requesting Let's Encrypt cert for ${fqdn} (up to ~2 min; DNS must already point here)..."
  resp=$(_npm_api /nginx/certificates --max-time 180 -X POST -d "$json") || true
  cert=$(echo "$resp" | jq -r '.id // empty')
  [[ -n "$cert" ]] || { warn "Cert issuance failed for ${fqdn} (DNS not pointed yet?). Host stays HTTP-only — add SSL in the NPM UI once DNS resolves."; return 1; }
  json=$(jq -nc --argjson c "$cert" '{certificate_id:$c, ssl_forced:true, hsts_enabled:true, hsts_subdomains:false, http2_support:true}')
  resp=$(_npm_api "/nginx/proxy-hosts/${id}" -X PUT -d "$json") || true
  [[ -n "$(echo "$resp" | jq -r '.id // empty')" ]] \
    && success "SSL forced for ${fqdn} (cert ${cert})" \
    || warn "Could not attach cert ${cert} to ${fqdn} — attach it manually in the NPM UI."
}

# ---- Authelia (additive, validated, auto-rollback) -------------------------
authelia_add_domain() {  # <root>
  local root="$1" esc bak
  if [[ ! -f "$AUTHELIA_CFG" ]]; then
    warn "Authelia config not found (${AUTHELIA_CFG}) — skipping SSO wiring for ${root}."
    return 0
  fi
  esc=${root//./\\.}
  if grep -qE "domain:[[:space:]]*\"${esc}\"" "$AUTHELIA_CFG"; then
    info "Authelia already wired for ${root} — skipping."
    return 0
  fi
  bak="${AUTHELIA_CFG}.bak-$(date +%Y%m%d-%H%M%S)"
  cp "$AUTHELIA_CFG" "$bak"
  info "Backed up Authelia config -> ${bak}"

  # Insert two access_control rules (bypass authelia.<root> BEFORE the *.<root>
  # two_factor catch-all) and one session.cookies entry. Existing domains' rules
  # and cookies are left untouched.
  awk -v root="$root" '
    /^[A-Za-z]/ { sect=$0 }
    { print }
    sect ~ /^access_control:/ && $0 ~ /^[[:space:]]+rules:[[:space:]]*$/ && !ar {
      print "    - domain: \"authelia." root "\""
      print "      policy: bypass"
      print "    - domain: \"*." root "\""
      print "      policy: two_factor"
      ar=1
    }
    sect ~ /^session:/ && $0 ~ /^[[:space:]]+cookies:[[:space:]]*$/ && !sc {
      print "    - domain: \"" root "\""
      print "      authelia_url: \"https://authelia." root "\""
      print "      default_redirection_url: \"https://authelia." root "\""
      sc=1
    }
  ' "$bak" > "$AUTHELIA_CFG.new"

  # Sanity: make sure both injections happened; otherwise the file structure
  # was unexpected — abort without touching the live file.
  if ! grep -qE "domain:[[:space:]]*\"authelia\.${esc}\"" "$AUTHELIA_CFG.new" \
     || ! grep -qE "domain:[[:space:]]*\"${esc}\"" "$AUTHELIA_CFG.new"; then
    rm -f "$AUTHELIA_CFG.new"
    warn "Could not locate the expected 'rules:' / 'cookies:' sections in ${AUTHELIA_CFG}."
    warn "Left config UNCHANGED. Add ${root} to Authelia manually, or use --no-authelia."
    return 1
  fi
  mv "$AUTHELIA_CFG.new" "$AUTHELIA_CFG"

  info "Restarting Authelia to apply (brief SSO blip for existing domain)..."
  docker restart authelia >/dev/null 2>&1 || true
  local ok=false i
  for i in $(seq 1 15); do
    if docker exec authelia wget -q -O- http://127.0.0.1:9091/api/health 2>/dev/null | grep -q OK; then ok=true; break; fi
    sleep 2
  done
  if $ok; then
    success "Authelia healthy — SSO realm added for ${root}"
  else
    warn "Authelia did NOT come back healthy — rolling back the config."
    cp "$bak" "$AUTHELIA_CFG"
    docker restart authelia >/dev/null 2>&1 || true
    fatal "Authelia config change reverted. Existing setup is intact. Check: docker logs authelia"
  fi
}

# ---- plan ------------------------------------------------------------------
declare -a PLAN=()
$DO_AUTHELIA && PLAN+=("Authelia: add SSO realm for ${ROOT} (cookies + access rules)") \
            && PLAN+=("NPM host: authelia.${ROOT} -> authelia:9091  (+SSL, public/bypass)")
for entry in "${APPS[@]:-}"; do
  [[ -z "$entry" ]] && continue
  ptype="${entry%%|*}"; spec="${entry#*|}"
  IFS=':' read -r sub host port <<< "$spec"
  [[ -n "${sub:-}" && -n "${host:-}" && -n "${port:-}" ]] || fatal "Bad app spec '${spec}' — need SUB:HOST:PORT"
  if [[ "$ptype" == "two_factor" ]]; then
    PLAN+=("NPM host: ${sub}.${ROOT} -> ${host}:${port}  (+SSL, Authelia-protected)")
  else
    PLAN+=("NPM host: ${sub}.${ROOT} -> ${host}:${port}  (+SSL, PUBLIC)")
  fi
done

printf "\n${C_B}Plan for %s${C_RST}\n" "$ROOT"
printf "  Stack:   %s\n" "$STACK_DIR"
printf "  LE email:%s\n" " $EMAIL"
printf "  ${C_Y}DNS required:${C_RST} *.%s  ->  this server's public IP\n" "$ROOT"
for p in "${PLAN[@]:-}"; do [[ -n "$p" ]] && printf "    • %s\n" "$p"; done
echo ""

if $DRY; then info "--dry-run: no changes made."; exit 0; fi

# ---- execute ---------------------------------------------------------------
npm_login

if $DO_AUTHELIA; then
  authelia_add_domain "$ROOT" || warn "Authelia wiring skipped/failed for ${ROOT} (see above)."
  aid=$(npm_add_host "authelia.${ROOT}" authelia 9091 false) || true
  [[ -n "${aid:-}" ]] && npm_enable_ssl "$aid" "authelia.${ROOT}" || true
fi

for entry in "${APPS[@]:-}"; do
  [[ -z "$entry" ]] && continue
  ptype="${entry%%|*}"; spec="${entry#*|}"
  IFS=':' read -r sub host port <<< "$spec"
  protect=false; [[ "$ptype" == "two_factor" ]] && protect=true
  fqdn="${sub}.${ROOT}"
  hid=$(npm_add_host "$fqdn" "$host" "$port" "$protect") || true
  [[ -n "${hid:-}" ]] && npm_enable_ssl "$hid" "$fqdn" || true
done

printf "\n${C_G}${C_B}Done.${C_RST} %s is attached.\n" "$ROOT"
printf "  • Existing domain(s) untouched. Re-run anytime — it's idempotent.\n"
printf "  • If a cert says 'failed', DNS wasn't pointed yet: re-run after *.%s resolves here,\n" "$ROOT"
printf "    or issue it in the NPM UI (Hosts -> the host -> SSL -> Request a new certificate).\n"
$DO_AUTHELIA && printf "  • Protected apps redirect to https://authelia.%s for 2FA.\n" "$ROOT"
printf "  • Remove the OLD domain later in the NPM UI (delete its hosts + certs), then drop its\n"
printf "    Authelia cookies/rules block and restart authelia. Non-destructive, do it whenever.\n"
