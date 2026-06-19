# Changelog

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
