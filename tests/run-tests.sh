#!/usr/bin/env bash
# Repo self-test: syntax + shellcheck + offline smoke tests of the entry points.
# Runs in tests/Dockerfile (no network, no Docker daemon, no real VPS needed).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fails=0; total=0
pass() { total=$((total+1)); printf '  [PASS] %s\n' "$*"; }
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

echo "== 5. deploy.sh CLI: unknown tool exits 1 and lists tools"
out=$(bash deploy.sh not-a-real-tool 2>&1); rc=$?
if [[ $rc -eq 1 && "$out" == *"Unknown tool"* && "$out" == *"dockhand-authentik"* ]]; then
  pass "unknown tool -> rc=1 + tool list"
else fail "unknown tool: rc=$rc out=$out"; fi

echo "== 6. deploy.sh CLI: known tool, GitHub unreachable, falls back to local copy, 'N' cancels"
# No network in the test image: curl fails -> must fall back to the local script
# and then honour the confirmation prompt (N) without running anything.
out=$(printf 'n\n' | bash deploy.sh harden 2>&1); rc=$?
if [[ "$out" == *"Using local harden.sh"* && "$out" == *"Cancelled"* ]]; then
  pass "offline fallback + cancel honoured (rc=$rc)"
else fail "offline fallback: rc=$rc out=$out"; fi

echo "== 7. deploy.sh CLI: aliases resolve"
for alias in npm tipi ynh fbx nb security check audit-netbird; do
  out=$(printf 'n\n' | bash deploy.sh "$alias" 2>&1)
  [[ "$out" != *"Unknown tool"* ]] && pass "alias $alias" || fail "alias $alias -> Unknown tool"
done

echo "== 8. deploy.sh interactive menu: 'q' quits 0, bad input rejected"
out=$(printf 'q\n' | bash deploy.sh 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"Bye."* ]] && pass "q quits" || fail "q: rc=$rc"
out=$(printf '99\nq\n' | bash deploy.sh 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"Not a valid choice"* ]] && pass "invalid choice rejected" || fail "invalid choice: rc=$rc out=$out"

echo "== 9. add-domain.sh --help exits 0"
out=$(bash add-domain.sh --help 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"sage"* ]] && pass "add-domain --help" || fail "add-domain --help rc=$rc out=$out"

echo "== 10. install.sh offline: fails cleanly (no partial state)"
out=$(bash install.sh 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"Failed to download deploy.sh"* ]] && pass "install.sh dies with clear message (rc=$rc)" \
  || fail "install.sh offline: rc=$rc out=$out"

echo
printf '%d/%d checks passed\n' "$((total-fails))" "$total"
[[ $fails -eq 0 ]]
