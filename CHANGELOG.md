# Changelog

## v4.9.0 — live-redeploy fixes + GeoIP allowlist + NPM-admin-via-domain

Validated by repeated full redeploys + a security audit on a real VPS.

### deploy-dockhand-authentik.sh
- **Layout:** `STACK_DIR` moved to **`/opt/apps/dockhand-stack`** (everything under `/opt/apps`). Detect/destroy/mount/verify paths + `harden.sh` lockdown path lists updated to match. Dockhand bind-mounts `/opt/apps` (identical path, RW) so host-deployed stacks are adoptable, not "untagged".
- **NPM admin via the domain:** auto-creates **`npm.<domain>`** → NPM admin (NPM's *own* login, no Authentik forward-auth — the control plane must not depend on the IdP). Port **81 published on `127.0.0.1`** by default. Flags: `EXPOSE_NPM_ADMIN` (default 1), `NPM_SKIP_SSL` (HTTP-only hosts).
- **NPM 2.15+ first-user:** NPM dropped the `admin@example.com/changeme` default (`/api/ → "setup":false`); deploy now creates the first admin via the API. (jq gotcha fixed: `'.setup // empty'` returns empty when it IS `false`.)
- **Authentik:** MFA **enforced** during bootstrap (TOTP-on-first-login, fail-safe) + akadmin recovery URL in the summary; proxy provider sends the now-required `invalidation_flow` (AK 2024.x); MFA enforcement decoupled from the provider step so an early return can't skip it.
- Worker-bouncer `account_name` sanitize (apostrophe FATALed it → wedged dpkg → silently broke AIDE). **Ported to all 12 deploy scripts.**
- Cosmetic: `printf "${C_B}---…"` no longer errors (`printf: --:`) when colors are empty (logged output).

### All 12 deploy-*.sh
- **NPM 2.15+ first-user creation ported to every script** (they all deploy NPM and would otherwise fail automation on `changeme`).

### harden.sh
- **GeoIP: default-deny ALLOWLIST with an interactive country picker** (continents → countries by name, auto-pre-allows the connecting country, lockout-guarded) replacing the old cn/ru/kp/ir blocklist. **IPv4 + IPv6** dual-stack (ipdeny v6 zones + ip6tables). Picker needs a TTY; `GEOIP_ALLOW="us,ca"` for non-interactive. `aggregated` zones + `maxelem` so big countries don't truncate.
- NPM-81 lockdown default **ON**; AIDE resilient + non-interactive (removes stale db, `--no-install-recommends` so no postfix on `:25`, excludes `/opt/apps` + container data); rpcbind `mask --now`; postfix loopback-only; honest "not actually active" summary.
- **Bug fixes:** `IFS=$'\n\t'` made unquoted `$PKG_INSTALL` (with spaces) fail every package install on a fresh box → wrapped in `_pkg`. AIDE's "Overwrite [Yn]?" prompt went to the log (invisible hang) → fixed. GeoIP verify check updated for the allowlist (`GEOIP_GATE`/`geoip_allow`).

### VPS Compose (companion app stacks)
- `/opt/apps/<app>/` layout; paperless secrets moved to `.env`; backup-tool repos pinned **outside** `/opt/apps` (no self-backup); duplicacy `docker.sock` removed.

## deploy-dockhand-authentik.sh — 4.7.4 → 4.8.0

### CrowdSec Console auto-enroll fixed (it never worked)
- `setup_crowdsec_console` ran `cscli console enroll --auto` with **no enrollment key**. Console enroll *requires* a per-account key from app.crowdsec.net — `--auto` is not a key — so it failed every time (that's why only the manual flow worked). Now: pass your key via `CROWDSEC_ENROLL_KEY=<key>` to enroll automatically (`cscli console enroll <key>`), otherwise it prints the correct 3-step manual flow. Stale `--auto` instruction in the summary replaced; new env var documented.

### Cloudflare token guidance — minimize by SCOPE, not by dropping perms
- Confirmed against CrowdSec's official docs that the 9 permissions the script already lists ARE the required set (the bouncer's config-generator validates all of them, even for ban-only — so Turnstile/DNS/etc. can't be dropped). The token prompt now tells you to minimize the **scope** instead: restrict *Account Resources* to your one account and *Zone Resources* to your one domain (never "All accounts/zones"). That's the real least-privilege lever.

### Status
- Promoted to the **flagship / recommended** stack in the README: hardened, live-audited on a real VPS (CrowdSec detection + enforcement verified, real attacks banned). Fresh-VPS-only; edge bouncer needs Workers Analytics Engine + DNS-01 certs behind Cloudflare.

## install.sh — NEW one-line bootstrapper

`curl -fsSL https://raw.githubusercontent.com/shoyrock/VPS-Deployments/main/install.sh | bash` (or `wget -qO- ... | bash`). Ensures root (re-execs via sudo, re-fetching since the script arrives over a pipe), installs curl/ca-certificates if missing, downloads `deploy.sh` to `/opt/vps-deploy`, and launches the menu reading from `/dev/tty` (so prompts work behind `curl | bash`). Pass a tool name to skip straight to it: `... | bash -s -- dockhand-authentik`. README gained a Quick Start section.

## deploy.sh — 1.0.0 → 1.1.0 (menu UX + audit entry)

- **PuTTY-friendly UI** — the old header used a full-width Unicode box whose right border drifted out of alignment, and menu rows wrapped past 80 columns. Rewritten with pure-ASCII rules (render in any terminal/charset, any window size), short one-line descriptions (every row now ≤ 72 cols — no wrapping), and an 18-wide name column so even `dockhand-authentik` lines up. Category headers, prompts, and confirmations cleaned up and de-emoji'd.
- **`audit` added to the menu (#16, Security & Utilities)** — `audit.sh` (the NetBird/Traefik stack health+security auditor) was in the repo but unreachable from the menu. Now selectable. Its CLI alias was previously mis-mapped to `verify`; `audit` now resolves to `audit.sh` and `verify` to `verify-stack.sh`. Both flagged read-only.

## ALL 10 non-netbird platform scripts — 4.6.0 → 4.7.0 (production parity)

Brought casaos, coolify, cosmos, dockge, dockhand, dokploy, freedombox, portainer, runtipi, yunohost up to the same production bar as dockhand-authentik. Each was `bash -n` validated and CR-clean. Same 6 fixes ported to all 10 (they share one copy-paste base):

- **CrowdSec SSH/system DETECTION (security hole closed)** — they installed the `sshd`/`linux` collections but had NO auth.log/syslog acquisition, so SSH brute force + host attacks were INVISIBLE. Added `acquis.d/syslog.yaml` (auth.log/syslog/secure/messages), installed + enabled **rsyslog** (Ubuntu 24.04 is journald-only), and `touch` the log files before the CrowdSec restart. The crowdsec container already mounted `/var/log:ro`, so detection now works end-to-end.
- **More community collections** — added `crowdsecurity/base-http-scenarios` (web scanning/probing/traversal/bad-UA). Full set now matches dockhand-authentik.
- **Worker bouncer no longer left half-configured** — same dpkg `iF` fix: when the worker can't run (no Analytics Engine / crash-loop / no token) it's now purged to a clean state so it can't block unattended security updates over a months-long run. Also stops a `Restart=always` crash-loop instead of leaving it spinning.
- **Flaky live-ban verify** — the false-negative `sleep 15`/check-once round-trip now POLLS up to ~36s.
- **Orphan-container warning** — each compose file now runs under its own project (`-p npm|crowdsec|authelia|<platform>`, derived from the filename) instead of one shared project; restart hints updated to match.

NOTE: netbird excluded (uses Traefik, separate ingress). runtipi's own `docker-compose.prod.yml` runs from its own dir (its own project) and was intentionally left alone.

## harden.sh — rpcbind (port 111) disabled (from live VPS audit)

A full audit of a live deployed VPS (Oracle, Ubuntu 24) found `rpcbind`/portmapper enabled and listening on `0.0.0.0:111` + `[::]:111` — a classic DDoS-amplification / info-disclosure surface that nothing on a single-host Docker deploy uses. `harden_misc` now disables + masks `rpcbind`/`rpcbind.socket` (skipped if an NFS mount is present), and `verify_hardening` checks port 111 is closed.

Audit also confirmed (no change needed): external attack surface is just 22/80/443 (Oracle's cloud security list blocks 81/111 regardless of UFW); CrowdSec is actively banning real attackers (thinkphp-CVE, CVE-2017-9841, http-probing, bad-UA) AND detecting SSH brute force via auth.log (the v4.7 detection fix works live); SSH is key-only/no-password/maxauthtries 3; Docker daemon.json hardened; containers non-privileged. The only live wart was the worker bouncer stuck in dpkg `iF` (already fixed for fresh installs by the v4.7.4 purge).

## harden.sh — CrowdSec/firewall conflict fix

Running `harden.sh` on a box that already has a deploy-*.sh stack broke CrowdSec enforcement: the post-harden `verify-stack.sh` flipped "live ban enforced" from PASS to **FAIL**.

- **`ufw --force reset` flushed the bouncer's nftables rules, never restarted.** harden rebuilds the firewall (UFW reset+enable, GeoIP) but never restarted the deploy's `crowdsec-firewall-bouncer`, so its `table ip crowdsec` rules were gone → bans not enforced. `install_crowdsec` now detects the existing bouncer and **restarts it after the firewall step** so its rules are rebuilt.
- **Parallel CrowdSec + wrong bouncer backend.** `install_crowdsec` would install a *second* native CrowdSec and the **iptables** bouncer variant, colliding with the deploy's Dockerized CrowdSec + **nftables** bouncer (two LAPIs, two firewall backends). It now detects an existing CrowdSec (Docker container, bouncer unit, or bouncer config) and skips the parallel install entirely.
- On-box remedy if you already hit this: `sudo systemctl restart crowdsec-firewall-bouncer` then re-run the verifier.

## deploy-dockhand-authentik.sh — 4.7.4

### Production: worker bouncer no longer left half-configured (blocks unattended updates)
- If the Cloudflare Worker bouncer can't run (no Analytics Engine / crash-loop / no token), its apt package was left in dpkg state **`iF` (half-configured)** — the postinst FATALs without AE. A half-configured package makes `apt-get` and **unattended-upgrades** error out, so on a long unattended run **security updates silently stop**. The deploy now **purges** the package to a clean dpkg state in all three can't-run branches (the host firewall bouncer — the real enforcement — is a separate package and is untouched). Re-running the deploy after enabling AE re-adds it.

## deploy-dockhand-authentik.sh — 4.7.3 + verify-stack.sh

### Live-ban check was a flaky FALSE NEGATIVE
- `[FAIL] live ban NOT enforced in firewall` could appear even though enforcement worked perfectly (confirmed on a live box: decision reached LAPI *and* the nft set). Cause: the test did a single `sleep 12`/`sleep 15` then checked once, but the firewall bouncer pulls every 10s — and once it's syncing large CrowdSec **community blocklists** (tens of thousands of decisions per cycle, e.g. after CAPI enrollment) the per-cycle work can push a freshly-added test decision just past that fixed wait. Race → false fail.
- Fix: the live-ban round-trip now **polls** (12 × 3s ≈ up to 36s, breaks as soon as the IP appears) instead of one fixed sleep. Applied in all three places: `verify-stack.sh`, the deploy's in-script `verify_deployment`, and the verifier the deploy installs to `/opt/dockhand-stack/verify-stack.sh`.
- Takeaway: harden.sh did NOT break enforcement (the firewall bouncer enrolled community blocklists and kept working); the test was simply too impatient.

## deploy-dockhand-authentik.sh — 4.7.2

### "Found orphan containers ([dockhand])" warning — permanently fixed
- All four compose files live in `/opt/dockhand-stack`, so Compose gave them ONE shared project name. Bringing up `npm.yml` then saw `dockhand` (from a different file) as an "orphan" of that project. Each stack now runs under its own project: `-p npm`, `-p crowdsec`, `-p authentik`, `-p dockhand`. No more cross-file orphan warnings.
- NOTE: `--remove-orphans` was deliberately NOT used — under the old shared project it would have **deleted** the dockhand/authentik/crowdsec containers whenever npm was brought up. Separate projects is the correct, non-destructive fix.
- Manual commands now take the project flag, e.g. `docker compose -p npm -f /opt/dockhand-stack/docker-compose.npm.yml restart`.

### CrowdSec — more community collections (all free, all applicable)
- Added `crowdsecurity/base-http-scenarios` (generic web attacks: scanning, probing, path traversal, bad UAs, crawlers). Full set now: `sshd`, `linux`, `nginx-proxy-manager`, `base-http-scenarios`, `http-cve`, `http-dos`, `whitelist-good-actors` — every collection that has a live acquisition source on this box (auth.log, syslog, NPM web logs).
- Deliberately left out (would log nothing / need extra wiring): `iptables` (no nftables log feed), `appsec-*` (needs the AppSec/WAF engine + a forwarding bouncer), mail/db collections (no such service).

### Two remediation components — both present, status clarified
- Both bouncers are still wired: the host **firewall bouncer** (nftables, enforces bans locally) and the **Cloudflare Worker bouncer** (blocks at Cloudflare's edge). If `cscli bouncers list` shows `cloudflarebouncer` registered but with no "Last API pull"/version, the worker isn't running — that is the **Cloudflare Workers Analytics Engine** prerequisite (must be enabled on the CF account; no API for it), not a missing component.

## deploy-dockhand-authentik.sh — 4.7.1

### Container terminal WebSocket dropped ("Connection error. Disconnected.")
- Opening a container shell from the Dockhand UI connected (shell banner showed) then immediately dropped. Root cause: NPM's default `proxy_read_timeout` is 60s, so the long-lived terminal WebSocket was killed. The dockhand proxy host now sets `proxy_read_timeout 86400s; proxy_send_timeout 86400s;` in its advanced config (alongside the Authentik forward-auth includes). WebSocket upgrade headers were already present (`allow_websocket_upgrade: true`); auth_request is kept on the host (removing it = unauthenticated root shell).

### Distribution / upload set
- `vps-deploy-fixes.zip` now includes `deploy.sh` (the master menu that deploys every script), `harden.sh`, and `add-domain.sh` — previously missing, so the menu referenced scripts that weren't in the upload set.

### deploy.sh — `verify` added to the menu
- `verify-stack.sh` was installed on the box but had no entry in the master menu. Added as item #15 under **Security & Utilities** (`./deploy.sh verify`, aliases: verify-stack/check/audit). It's flagged read-only (changes nothing but a self-test ban it adds then deletes).

## deploy-dockhand-authentik.sh — 4.6.0 → 4.7.0

Fully audited and hardened. Highlights:

### CrowdSec DETECTION + on-box verifier (4.7.0)
- **SSH + system attacks were INVISIBLE** — the script installed the `sshd` and `linux` collections but only ever configured an acquisition for NPM web logs. No SSH/auth or syslog source → brute force and host attacks were never detected (a box could sit an hour with zero hits). Now writes `acquis.d/syslog.yaml` (auth.log/secure + syslog/messages, type syslog).
- **No log file on modern distros** — Ubuntu 24.04 ships journald-only, so `/var/log/auth.log` didn't exist. Now installs + enables **rsyslog**, and touches the files so CrowdSec tails them from restart.
- **Deploy now proves DETECTION, not just enforcement** — `verify_deployment` injects a synthetic ssh-bf burst (reserved 198.51.100.66) into auth.log and confirms CrowdSec parses it into a decision, then cleans up.
- **Verifier installed on the host** — the deploy writes `verify-stack.sh` to `/opt/dockhand-stack/verify-stack.sh` (mode 755), re-runnable any time: `sudo bash /opt/dockhand-stack/verify-stack.sh`. It now includes a "CrowdSec detection" section (acquisition present, auth.log present, live ssh-bf detection).

### Correctness / functional
- **Verify container loop broken by IFS** — global `IFS=$'\n\t'` has no space, so `for c in $want` (space-separated string) never split. Changed to a bash array → all 7 container checks run.
- **Authentik forward-auth never worked** — bootstrap created a *new standalone* outpost (no running instance) instead of attaching the provider to the built-in **embedded** outpost (`managed=goauthentik.io/outposts/embedded`). Now finds and merges into the embedded outpost.
- **Embedded outpost `authentik_host` unset** — caused "authentik domain is not configured. Authentication will not work." The PATCH now also sets `config.authentik_host` (merged, non-clobbering).
- **Authentik bootstrap bailed early** — the akadmin token is created slightly after the health endpoint goes ready; a single probe got 403 → "Could not resolve flow". Now retries auth up to ~2 min, plus flow-slug fallback (implicit → explicit → any authorization flow).
- **NPM token gave up on first try** — the firewall step restarts Docker just before NPM automation, so NPM briefly rejected the default login. Now retries 8×5s.
- **Verify real-IP false negative** — checked `http.conf` for `CF-Connecting-IP`, which lives in the container's `nginx.conf`. Now checks both files where the values actually are.

### CrowdSec Cloudflare Worker bouncer
- **30-minute dpkg hang** — the worker `apt-get install` could stop on an interactive conffile prompt. Now `DEBIAN_FRONTEND=noninteractive timeout 300 ... --force-confold --force-confdef ... </dev/null`.
- **False "ACTIVE"** — `systemctl is-active` caught the brief up-window of a `Restart=always` crash-loop. Now checks `SubState=running` + steady `NRestarts`.
- **Stale binary / purged unit** — `command -v` short-circuit skipped reinstall when the unit was gone. Now gates on the unit file too.
- **Analytics Engine** — detects the `unable to deploy infra: You need to enable Analytics Engine` crash-loop and tells the user to enable it (no API to do it automatically).
- **captcha action** — requires `turnstile.enabled: true` or the config FATALs; now auto-enables for captcha, rejects bad `CF_BOUNCER_ACTION` values.

## deploy-dockhand.sh — 4.6.0
- Worker bouncer dpkg-hang fix (noninteractive + confold/confdef). No version bump.

## deploy-netbird.sh — 4.7.1
- No change (the worker install was already hardened).

## Dockhand stack tracking — documented method, NOT baked into the scripts
An earlier attempt mounted `/opt/apps:/opt/apps` (identical path, Dockge's model). That is **wrong for Dockhand** and was reverted: Dockhand looks for stacks in its data dir at **`/app/data/stacks`**, not an identical host path, so the apps showed as empty/untracked. The documented method (Dockhand discussion #178) is to mount the host apps dir onto Dockhand's stacks folder:
```yaml
volumes:
  - /opt/apps:/app/data/stacks   # host apps dir -> Dockhand's internal stacks dir
```
then use Dockhand's **Adopt / Scan Folder** button. Caveat from the same thread: editing an adopted stack can create an env-named subfolder beside the original. Left OUT of the scripts pending live verification.

## Worker dpkg-hang fix only — casaos, coolify, cosmos, dockge, dokploy, freedombox, portainer, runtipi, yunohost
- The worker-bouncer `apt-get install` line was copy-pasted across all of them with the same ~30-min hang. Patched to `DEBIAN_FRONTEND=noninteractive ... --force-confold --force-confdef`. These still lack the full worker hardening (false-ACTIVE / stale-unit / AE detection) — port from dockhand-authentik before production use.

## verify-stack.sh — NEW
Health + security auditor for the Dockhand/Authentik/NPM/CrowdSec stack. Run `sudo bash verify-stack.sh` on the VPS. Checks containers, service health, CrowdSec enforcement (live ban round-trip), and security posture (default creds rejected, firewall active, LAPI/Authentik localhost-only, host fs read-only, Authentik gate on the dockhand proxy host, credential file perms).

## Known external prerequisites (not script bugs)
- **Cloudflare Worker bouncer** needs Workers **Analytics Engine** enabled on the account (manual).
- **NPM Let's Encrypt** behind Cloudflare: use the **DNS-01** challenge with a Cloudflare token (HTTP-01 fails when the record is proxied/orange-cloud).
- Forward-auth snippets must use the real outpost host **`authentik-server`**, not Authentik's docs placeholder `authentik.company` (a bad upstream breaks every nginx reload → NPM "Internal Error").
