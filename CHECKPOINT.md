# CHECKPOINT — KNOWN-GOOD STATE (do not regress)

**Status: GREEN.** Validated on a fresh Oracle VPS (`129.80.45.220`) on 2026-06-25:
deploy exit `code 0`, **harden `19/19` first-run**, external surface `22/80/443` only,
all security controls active. This was the first box to come up fully clean first-try
after a long fix cycle.

> **READ THIS BEFORE EDITING ANY SCRIPT.** Every item below is a bug that was already
> found, fixed, and verified live. Re-introducing any of them is a regression. If you
> "fix" something and it breaks an item here, it is NOT a fix — revert and rethink.
> When you change a script, re-verify the affected invariant with the command shown.

---

## How this project ships (critical gotcha)
`install.sh` downloads `deploy.sh` + `harden.sh` **from the GitHub repo** into
`/opt/vps-deploy/`. **GitHub is the source of truth at runtime.** Fixing a file
locally does nothing until it's pushed to GitHub — this caused repeated "fixed it
again" loops where the box kept pulling a stale script. **After any change: push to
GitHub.** When auditing a "still broken" box, first check the box's copy actually has
the fix (`grep` the marker), don't assume it ran your latest.

---

## INVARIANTS — must stay true (with the bug each prevents + how to verify)

### Deploy (`deploy-dockhand-authentik.sh` + the 11 siblings)
1. **NPM 2.15 first-user via API.** NPM ≥2.15 ships `setup:false`, NO `admin@example.com/changeme`. First admin is created with an UNAUTHENTICATED `POST /api/users`. Read `.setup` RAW (`jq -r '.setup'`, NOT `// empty` — that returns empty for boolean false). In **all 12** deploy scripts. *Verify:* deploy creates the admin + saves `${STACK_DIR}/.npm_admin_password`; login works.
2. **Authentik proxy provider sends `invalidation_flow`** (required AK 2024.x) or POST 400s → no forward-auth.
3. **Forward-auth snippet uses the CURRENT Authentik pattern.** `error_page 401 = @goauthentik_proxy_signin;` + a named location `@goauthentik_proxy_signin { return 302 /outpost.goauthentik.io/start?rd=$request_uri; }` + `$auth_cookie` propagation. **NEVER** the old `auth_request_set $redirect_url $upstream_http_location; error_page 401 =302 $redirect_url;` — AK 2024.12's `/auth/nginx` 401 returns NO `Location` header → blank 302 → dockhand dead-ends. *Verify:* `curl -I http://dockhand.<domain>` (via NPM) → `302` with `Location: .../outpost.goauthentik.io/start?rd=/` (non-empty).
4. **MFA enforced**, decoupled. `enforce_authentik_mfa` runs AFTER `bootstrap_authentik` (not inside it — early returns skipped it). *Verify:* mfa-validation stage `not_configured_action == configure`.
5. **`authentik-worker` has NO `docker.sock`** + deploy DELETEs the "Local Docker" service connection. With the sock removed but the connection present, `outpost_service_connection_state` fails every cycle → DockerException spam. *Verify:* only `dockhand` mounts docker.sock; `docker logs --since 10m authentik-worker | grep -c DockerException` == 0.
6. **NPM admin = its OWN login, NOT Authentik.** Auto-creates `npm.<domain>` proxy host with NPM's native login + 2FA (NPM is the recovery/control plane; must NOT depend on the IdP = no SPOF). Port **81 bound to `127.0.0.1`**. Flags `EXPOSE_NPM_ADMIN` (def 1), `NPM_SKIP_SSL`. *Verify:* `docker port npm 81` → `127.0.0.1`; `npm.<domain>` host has no authentik snippet.
7. **`STACK_DIR=/opt/apps/dockhand-stack`** (infra under `/opt/apps`).
8. **CF worker-bouncer `account_name` sanitized** (`tr -cd` — an apostrophe FATALs the bouncer → wedges dpkg). In all 12. Worker bouncer needs CF **Workers Analytics Engine** (manual); if disabled the deploy removes the pkg + warns (expected, not a failure).
9. **`printf '%s\n'` for separators**, not `printf "${C_B}---..."` (errors `printf: --:` when color empty/non-TTY).

### Harden (`harden.sh`)
10. **rpcbind: SIGPIPE-safe detection + PURGE.** THE bug: under `set -o pipefail`, `systemctl list-unit-files | grep -q '^rpcbind'` → `grep -q` closes the pipe on first match → SIGPIPE kills systemctl (exit 141) → pipefail makes the condition FALSE → the whole rpcbind block silently never ran (rpcbind stayed up on EVERY box). FIX: capture into a var with `grep` (NO `-q`, drains all input): `_rpc_units=$(systemctl list-unit-files | grep -iE '^rpcbind' || true); ... [[ -n "$_rpc_units" ]]`. Then `apt-get purge nfs-common rpcbind` (mask alone fails — nfs-common Depends on rpcbind). **RULE: never `<long-producer> | grep -q` in a condition under pipefail — capture, or `grep ... >/dev/null` (no -q).** *Verify:* `ss -tlnH | grep -c ':111'` == 0 after harden.
11. **Auto-updates preserved.** apt-lock handling stops ONLY `apt-daily.service apt-daily-upgrade.service` (the lock holders) — **NEVER** the TIMERS, NEVER `unattended-upgrades.service`. Disabling the timers KILLED scheduled security updates (regression that failed the "Auto-updates active" check). `setup_auto_updates` re-`enable --now`s the timers (self-heal). *Verify:* `systemctl is-active unattended-upgrades` == active AND `is-enabled apt-daily-upgrade.timer` == enabled.
12. **apt exit-100 fix = global lock timeout.** `printf 'DPkg::Lock::Timeout "300";' > /etc/apt/apt.conf.d/99deploy-lock-timeout` so every apt-get WAITS for the lock instead of exiting 100 on a fresh boot. (Same in all 12 deploy `system_update`.)
13. **`_pkg` wrapper.** Global `IFS=$'\n\t'` made unquoted `$PKG_INSTALL` (has spaces) fail every install → wrapped in `_pkg() { local IFS=$' \t\n'; $PKG_INSTALL "$@"; }`.
14. **AIDE non-interactive.** `rm` stale db.new + `aideinit -y -f < /dev/null` (its "Overwrite [Yn]?" went to the log = invisible hang). `--no-install-recommends` + postfix loopback (no MTA on :25). Excludes `/opt/apps` + container data.
15. **GeoIP default-deny ALLOWLIST + interactive picker** (continents→countries by NAME, auto-pre-allows the connecting country, lockout-guarded), IPv4+IPv6. Picker needs a TTY; `GEOIP_ALLOW="us,ca"` non-interactive. *Verify:* `iptables -L GEOIP_GATE` exists + your IP `ipset test geoip_allow <ip>` = in set.
16. **NPM-81 lockdown default ON**; rpcbind/postfix/etc closed → host surface `22/80/443` only.

### App composes (`VPS Compose/*/compose.yml`)
17. **ALL volumes are ABSOLUTE `/opt/apps/<app>/...`.** No `./relative`, no named volumes, no `/opt/duplicacy`,`/opt/kopia`,`/opt/backups`,`~`. The compose file ALONE (run anywhere) must create data under `/opt/apps/<app>/` — Docker auto-creates dirs; NO folder/skeleton to copy. Single backup root = `/opt/apps`. Backup tools (kopia/duplicacy/zerobyte/vaultwarden-backup) ALSO under `/opt/apps`; avoid self-snapshot via the tool's OWN exclude rules, NOT by relocating data. *Verify:* every `- ` volume source starts with `/opt/apps/` (or is `/etc/localtime`, `/dev/*`, `/`, `/opt/apps:ro` source).

---

## USER'S FIRM RULES (non-negotiable)
- **No regressions.** "If a fix stops something else from working, that's not a fix."
- **Follow instructions to a T. Do NOT add your own logic / "what I think you want."**
- **NPM must never depend on Authentik** (SPOF avoidance).
- **All container data under `/opt/apps`** (one backup root).
- Fix the **SCRIPTS**, not just the live box. Then **push to GitHub**.
- Test boxes are disposable — never lock yourself out of SSH; don't commit `.env`/secrets.

## KNOWN-PENDING (optional, NOT regressions)
- **SSL is manual/off by design** right now → apps reachable over **`http://`** (browser HTTPS-First/HSTS makes the domain look dead; that's a client cache thing, not the server). `npm_enable_ssl` still needs an update for NPM 2.15's cert API (`meta` no longer takes `letsencrypt_email`/`agree`) before auto-SSL works.
- **CF Workers Analytics Engine** must be enabled (manual, CF dashboard) for the edge worker-bouncer; otherwise it's removed + the host CrowdSec firewall-bouncer is the (active) enforcement.
- Make infra (`/opt/apps/dockhand-stack`) compose paths absolute too (currently relative `./`, resolved correctly because the deploy runs from STACK_DIR).

## Verified-good reference
Box `129.80.45.220` (2026-06-25): deploy `code 0`; harden `19/19`; surface `22/80/443`;
rpcbind off; auto-updates active; GeoIP/AIDE/CrowdSec(enforcing)/MFA/NPM-81-localhost
all green; only `dockhand` holds docker.sock; 0 worker DockerExceptions.
