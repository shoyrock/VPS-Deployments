#!/usr/bin/env bash
# Repo self-test: syntax + shellcheck + offline smoke tests of the entry points.
# Runs in tests/Dockerfile (no network, no Docker daemon, no real VPS needed).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# deploy.sh ALWAYS re-downloads a tool from GitHub and overwrites the local copy
# when it can reach raw.githubusercontent.com. Never let the smoke tests touch the
# real checkout: run them from a throwaway copy (and prefer --network none).
SRC="$PWD"; WORK="$(mktemp -d)"; cp -a "$SRC"/. "$WORK"/; trap 'rm -rf "$WORK"' EXIT
ONLINE=0; curl -sf --max-time 5 -o /dev/null https://raw.githubusercontent.com/ 2>/dev/null && ONLINE=1
SNAP_BEFORE="$(cat "$SRC"/*.sh | sha256sum)"

fails=0; total=0
pass() { total=$((total+1)); printf '  [PASS] %s\n' "$*"; }
skip() { printf '  [SKIP] %s\n' "$*"; }
fail() { total=$((total+1)); fails=$((fails+1)); printf '  [FAIL] %s\n' "$*"; }

echo "== 1. bash -n (syntax)"
for f in *.sh; do
  if bash -n "$f" 2>/tmp/err; then pass "$f"; else fail "$f: $(cat /tmp/err)"; fi
done

echo "== 2. shellcheck (warning level, repo-wide noise excluded)"
# SC2059 printf-with-color-vars and SC2015 A&&B||C are deliberate house style.
if shellcheck -S warning -e SC2059,SC2015,SC2034,SC2155 *.sh; then
  pass "shellcheck clean"
else
  fail "shellcheck reported warnings"
fi

echo "== 3. no CRLF line endings"
if grep -l $'\r' *.sh >/dev/null 2>&1; then fail "CRLF found: $(grep -l $'\r' *.sh | tr '\n' ' ')"; else pass "all LF"; fi

echo "== 4. deploy.sh menu wiring"
# every menu tool must map to a script that exists in the repo
missing=""
for n in portainer dockge dockhand dockhand-authentik arcane-authentik netbird coolify \
         dokploy casaos runtipi cosmos yunohost freedombox; do
  [[ -f "deploy-$n.sh" ]] || missing="$missing deploy-$n.sh"
done
for s in harden.sh add-domain.sh verify-stack.sh audit.sh; do [[ -f "$s" ]] || missing="$missing $s"; done
[[ -z "$missing" ]] && pass "all menu tools have a script" || fail "menu scripts missing:$missing"

echo "== 4b. CrowdSec Console enrollment: key-based flow everywhere, no key-less --auto"
# `cscli console enroll --auto` (no key) always fails; every CrowdSec script must
# honour CROWDSEC_ENROLL_KEY and actually call setup_crowdsec_console from main().
bad=""
for f in deploy-*.sh; do
  grep -q "setup_crowdsec_console() {" "$f" || continue   # legacy scripts without CrowdSec
  grep -vE '^[[:space:]]*#' "$f" | grep -q 'cscli console enroll --auto' && bad="$bad $f(--auto)"
  grep -q 'CROWDSEC_ENROLL_KEY' "$f" || bad="$bad $f(no-key-var)"
  awk '/^main\(\) \{/,/^\}/' "$f" | grep -q '^  setup_crowdsec_console$' || bad="$bad $f(not-called-from-main)"
done
[[ -z "$bad" ]] && pass "console enrollment consistent across CrowdSec scripts" || fail "console enrollment:$bad"

echo "== 4c. every function defined in a deploy script is referenced at least once"
dead=""
for f in deploy-*.sh; do
  for fn in $(grep -oE '^[a-z_]+\(\)' "$f" | tr -d '()' | sort -u); do
    [[ "$fn" == "main" ]] && continue
    c=$(grep -cE "(^|[^a-zA-Z0-9_])${fn}([^a-zA-Z0-9_(]|$)" "$f")
    [[ $c -eq 0 ]] && dead="$dead $f:$fn"   # definition line itself never matches (followed by '(')
  done
done
[[ -z "$dead" ]] && pass "no dead functions" || fail "defined but never called:$dead"

echo "== 4d. Docker-manager UIs can read/edit the stacks WITHOUT running as root"
bad=""
# Arcane: unprivileged uid 65532 + a host group (setup_manager_access) that owns
# exactly the compose/env files; PROJECTS_DIRECTORY at the identical path; one
# folder per project with a standard compose.yaml. Never PUID=0, never cgroup: host.
f=deploy-arcane-authentik.sh
for want in 'PUID=${MGR_UID}' 'PGID=${MGR_GID}' "PROJECTS_DIRECTORY=/opt/apps" "/opt/apps:/opt/apps" "setup_manager_access() {" 'chmod 3770 "${STACK_DIR}/${d}"' 'chown "${MGR_UID}:${MGR_GROUP}" "${STACK_DIR}/${d}/compose.yaml"'; do grep -qF -- "$want" "$f" || bad="$bad $f(missing:$want)"; done
for m in deploy-arcane-authentik.sh deploy-dockhand-authentik.sh deploy-dockhand.sh deploy-netbird.sh; do
  grep -qE '^\s+- PUID=0\s*$' "$m" && bad="$bad $m(RUNS-AS-ROOT:PUID=0)"
  grep -qE '^\s+cgroup: host' "$m" && bad="$bad $m(cgroup-host)"
  grep -q 'setup_manager_access() {' "$m" || bad="$bad $m(no-setup_manager_access)"
  grep -qF 'readonly MGR_UID=65532' "$m" || bad="$bad $m(no-MGR_UID)"
done
grep -q 'docker-compose\.[a-z-]*\.yml' "$f" && bad="$bad $f(flat-compose-layout-leftover)"
# crowdsec/ and authentik/ are addressed through their DIR variables in the script
for pat in 'npm/compose\.yaml' '(crowdsec|CROWDSEC_DIR\})/compose\.yaml' '(authentik|AUTHENTIK_DIR\})/compose\.yaml' 'arcane/compose\.yaml' 'crowdsec-webui/compose\.yaml'; do
  grep -qE "$pat" "$f" || bad="$bad $f(no-project:$pat)"
done
# Dockhand: unprivileged PUID/PGID from the same group model; stack dir mounted RW at the same path.
for f in deploy-dockhand-authentik.sh deploy-dockhand.sh deploy-netbird.sh; do
  for want in 'PUID=${MGR_UID}' 'PGID=${MGR_GID}'; do grep -qF -- "- $want" "$f" || bad="$bad $f(missing:$want)"; done
done
grep -q -- "- /opt/apps:/opt/apps" deploy-dockhand-authentik.sh || bad="$bad dockhand-authentik(no-identical-mount)"
grep -q -- "- /opt/dockhand-stack:/opt/dockhand-stack" deploy-dockhand.sh || bad="$bad dockhand(no-identical-mount)"
grep -q -- "- /opt/netbird-stack:/opt/netbird-stack" deploy-netbird.sh || bad="$bad netbird(no-identical-mount)"
[[ -z "$bad" ]] && pass "manager UIs: unprivileged uid + group model, identical-path mounts, Arcane per-project layout" || fail "manager UI config:$bad"

echo "== 4e. generated Arcane compose files parse and keep relative paths inside the stack"
# Extract each heredoc exactly as the script writes it and validate with docker compose
# when available (the test image has none, so fall back to a structural check).
tmp=$(mktemp -d); f=deploy-arcane-authentik.sh
ext() { awk -v m="$1" 'index($0, "<< \x27"m"\x27")||index($0, "<< "m)&&!/^[A-Z_]+$/ {g=1; next} $0==m {g=0} g' "$f"; }
mkdir -p "$tmp"/{npm,crowdsec,authentik,arcane,crowdsec-webui}
ext COMPOSE_NPM > "$tmp/npm/compose.yaml"; ext COMPOSE_CROWDSEC > "$tmp/crowdsec/compose.yaml"
ext COMPOSE_AUTHENTIK > "$tmp/authentik/compose.yaml"; ext COMPOSE_ARCANE > "$tmp/arcane/compose.yaml"; ext COMPOSE_WEBUI > "$tmp/crowdsec-webui/compose.yaml"
bad=""
for pdir in npm crowdsec authentik arcane crowdsec-webui; do
  [[ -s "$tmp/$pdir/compose.yaml" ]] || bad="$bad $pdir(empty)"
  grep -q '^services:' "$tmp/$pdir/compose.yaml" || bad="$bad $pdir(no-services)"
  # no path may escape the stack dir (max one '..' segment, never '../..')
  grep -q '\.\./\.\.' "$tmp/$pdir/compose.yaml" && bad="$bad $pdir(escapes-stack-dir)"
done
grep -q '^      - \.\./data:/data' "$tmp/npm/compose.yaml" || bad="$bad npm(data-path)"
grep -q '^      - \.\./data/logs:/npm-logs:ro' "$tmp/crowdsec/compose.yaml" || bad="$bad crowdsec(npm-logs-path)"
grep -q 'env_file: \./authentik\.env' "$tmp/authentik/compose.yaml" || bad="$bad authentik(env_file)"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  for pdir in npm crowdsec authentik arcane crowdsec-webui; do
    touch "$tmp/authentik/authentik.env" "$tmp/arcane/.arcane.env" "$tmp/crowdsec-webui/webui.env"
    CF_BOUNCER_KEY=x docker compose -p "t-$pdir" -f "$tmp/$pdir/compose.yaml" config >/dev/null 2>"$tmp/err" || bad="$bad $pdir(compose-config: $(head -c 120 "$tmp/err"))"
  done
fi
rm -rf "$tmp"
[[ -z "$bad" ]] && pass "Arcane project compose files valid" || fail "Arcane compose files:$bad"

echo "== 5. deploy.sh CLI: unknown tool exits 1 and lists tools"
out=$(cd "$WORK" && bash deploy.sh not-a-real-tool 2>&1); rc=$?
if [[ $rc -eq 1 && "$out" == *"Unknown tool"* && "$out" == *"dockhand-authentik"* ]]; then
  pass "unknown tool -> rc=1 + tool list"
else fail "unknown tool: rc=$rc out=$out"; fi

echo "== 6. deploy.sh CLI: known tool, GitHub unreachable, falls back to local copy, 'N' cancels"
# No network in the test image: curl fails -> must fall back to the local script
# and then honour the confirmation prompt (N) without running anything.
if [[ $ONLINE -eq 1 ]]; then skip "offline fallback (GitHub reachable; run with --network none)"; else
out=$(cd "$WORK" && printf 'n\n' | bash deploy.sh harden 2>&1); rc=$?
if [[ "$out" == *"Using local harden.sh"* && "$out" == *"Cancelled"* ]]; then
  pass "offline fallback + cancel honoured (rc=$rc)"
else fail "offline fallback: rc=$rc out=$out"; fi
fi

echo "== 7. deploy.sh CLI: aliases resolve"
for alias in npm tipi ynh fbx nb security check audit-netbird; do
  out=$(cd "$WORK" && printf 'n\n' | bash deploy.sh "$alias" 2>&1)
  [[ "$out" != *"Unknown tool"* ]] && pass "alias $alias" || fail "alias $alias -> Unknown tool"
done

echo "== 8. deploy.sh interactive menu: 'q' quits 0, bad input rejected"
out=$(cd "$WORK" && printf 'q\n' | bash deploy.sh 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"Bye."* ]] && pass "q quits" || fail "q: rc=$rc"
out=$(cd "$WORK" && printf '99\nq\n' | bash deploy.sh 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"Not a valid choice"* ]] && pass "invalid choice rejected" || fail "invalid choice: rc=$rc out=$out"

echo "== 9. add-domain.sh --help exits 0"
out=$(cd "$WORK" && bash add-domain.sh --help 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"sage"* ]] && pass "add-domain --help" || fail "add-domain --help rc=$rc out=$out"

echo "== 10. install.sh offline: fails cleanly (no partial state)"
if [[ $ONLINE -eq 1 ]]; then skip "install.sh offline (GitHub reachable; run with --network none)"; else
out=$(cd "$WORK" && bash install.sh 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"Failed to download deploy.sh"* ]] && pass "install.sh dies with clear message (rc=$rc)" \
  || fail "install.sh offline: rc=$rc out=$out"
fi

echo "== 11. smoke tests did not modify the checkout"
SNAP_AFTER="$(cat "$SRC"/*.sh | sha256sum)"
[[ "$SNAP_BEFORE" == "$SNAP_AFTER" ]] && pass "scripts in the checkout are byte-identical to before the run" \
  || fail "scripts in the checkout CHANGED during the run (deploy.sh re-download clobbered them?)"

echo
printf '%d/%d checks passed\n' "$((total-fails))" "$total"
[[ $fails -eq 0 ]]
