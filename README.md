# VPS Deployment Scripts — v4.6.0-hardened-cloudflare

> ⚠️ **SECURITY DISCLAIMER — READ BEFORE USING**
>
> These scripts are provided as-is for educational and personal use. **Always review the code before executing it on your system.** Running untrusted shell scripts as root can cause irreversible damage, data loss, or security compromise.
>
> - Read each script before running it. Understand what it does.
> - Test in a VM or staging environment before production use.
> - Back up your data before deployment.
> - The author assumes **no responsibility** for any damage, data loss, downtime, or security incidents resulting from the use of these scripts.
> - These scripts wipe existing Docker containers and reconfigure system firewalls — only run on a **fresh VPS**.

---

One-shot, hardened deployment scripts for fresh VPS instances. Every script deploys **Nginx Proxy Manager** (reverse proxy + SSL), **Authelia** (SSO + 2FA on every subdomain), **CrowdSec** (IPS with NPM-aware collections + firewall bouncer), and **firewall rules**.

---

## Quick Reference

### Available Scripts

| Script | Deploys | Stack Dir | Notes |
|--------|---------|-----------|-------|
| `deploy-dockhand.sh` | NPM + Dockhand + Authelia + CrowdSec | `/opt/dockhand-stack/` | Docker manager with host file access |
| `deploy-netbird.sh` | Traefik + Authentik + NetBird + Dockhand + CrowdSec | `/opt/netbird-stack/` | ⚠️ Zero-trust variant (Authentik IdP + NetBird mesh). **Staging — test in a VM first** |
| `deploy-portainer.sh` | NPM + Portainer + Authelia + CrowdSec | `/opt/portainer-stack/` | Visual container management |
| `deploy-dockge.sh` | NPM + Dockge + Authelia + CrowdSec | `/opt/dockge-stack/` | Compose stack manager |
| `deploy-cosmos.sh` | NPM + Cosmos + Authelia + CrowdSec | `/opt/cosmos-stack/` | All-in-one homelab |
| `deploy-coolify.sh` | NPM + Coolify + Authelia + CrowdSec | `/opt/coolify-stack/` | PaaS |
| `deploy-dokploy.sh` | NPM + Dokploy + Authelia + CrowdSec | `/opt/dokploy-stack/` | PaaS |
| `deploy-casaos.sh` | NPM + CasaOS + Authelia + CrowdSec | `/opt/casaos-stack/` | Home server with app store |
| `deploy-runtipi.sh` | NPM + Runtipi + Authelia + CrowdSec | `/opt/runtipi-stack/` | Home server + 300 apps |
| `deploy-yunohost.sh` | NPM + YunoHost + Authelia + CrowdSec | `/opt/yunohost-stack/` | Debian server distro (Debian 12 only) |
| `deploy-freedombox.sh` | NPM + FreedomBox + Authelia + CrowdSec | `/opt/freedombox-stack/` | Debian home server (Debian 12 only) |

**All scripts expose only 3 ports: 80 (HTTP), 443 (HTTPS), 81 (NPM admin).** Individual tool containers have **no host ports** — they communicate internally via Docker's `proxy` network using their container hostnames.

> **Note on port 81:** the NPM admin panel is published on `0.0.0.0:81` so you can reach it at `http://<vps-ip>:81` right after deploy to finish configuration. `harden.sh` leaves it exposed **by default** (`LOCKDOWN_NPM_ADMIN=0`) because it's needed during setup. To bind it to `127.0.0.1` (SSH-tunnel-only) once your proxy hosts are set up, run `LOCKDOWN_NPM_ADMIN=1 ./harden.sh`, then reach it via `ssh -L 8181:127.0.0.1:81 root@<vps>` → `http://localhost:8181`. Re-running with the other value flips it back (idempotent).

---

## How to Use

### Option 1: Menu (Recommended)

```bash
curl -fsSL -o deploy.sh https://raw.githubusercontent.com/shoyrock/VPS-Deployments/main/deploy.sh
chmod +x deploy.sh
./deploy.sh
```

### Option 2: Direct Deploy

```bash
sudo ./deploy-dockhand.sh     # Deploy Dockhand
sudo ./deploy-portainer.sh    # Deploy Portainer
sudo ./deploy-dockge.sh       # Deploy Dockge
sudo ./deploy-cosmos.sh       # Deploy Cosmos
sudo ./deploy-coolify.sh      # Deploy Coolify
sudo ./deploy-dokploy.sh      # Deploy Dokploy
sudo ./deploy-casaos.sh       # Deploy CasaOS
sudo ./deploy-runtipi.sh      # Deploy Runtipi
sudo ./deploy-yunohost.sh     # Deploy YunoHost (Debian 12 only)
sudo ./deploy-freedombox.sh   # Deploy FreedomBox (Debian 12 only)
```

**Env vars** (all optional):
- `FORCE_CLEANUP=1` — skip the destructive-cleanup confirmation (for CI/unattended runs)
- `CF_API_TOKEN=<token>` — Cloudflare **User** API token; enables the CrowdSec Cloudflare Worker bouncer non-interactively. If unset, the script prompts (blank = configure now, deploy later).
- `CF_BOUNCER_ACTION=ban|captcha` — edge action for banned IPs (default `ban`; `captcha` challenges instead of blocking).
- `LOCK_HTTP_TO_CLOUDFLARE=true` — restrict ports 80/443 to Cloudflare's published IP ranges in the firewall (default `false`; turn on once all DNS is proxied through Cloudflare).

```bash
sudo CF_API_TOKEN=xxxxx ./deploy-dockhand.sh           # non-interactive token
sudo LOCK_HTTP_TO_CLOUDFLARE=true ./deploy-dockhand.sh # also lock 80/443 to CF
sudo CF_BOUNCER_ACTION=captcha ./deploy-dockhand.sh    # challenge instead of block
```

**Supported OS:** Ubuntu 20.04+, Debian 11+, Rocky/AlmaLinux 8/9, Fedora 35+, Amazon Linux 2023

**Requirements:** Root access, internet, 2GB+ free disk, a domain pointed at your VPS

---

## What Gets Deployed

Every script deploys the same core stack plus one platform:

| Component | Container | Purpose |
|-----------|-----------|---------|
| **NPM** | `npm` | Reverse proxy on 80/443/81, Let's Encrypt SSL |
| **Authelia** | `authelia` | SSO login portal + TOTP 2FA on `authelia.YOURDOMAIN.com` |
| **CrowdSec** | `crowdsec` | Log-based intrusion detection, SSH + NPM monitoring; enrolled in the CrowdSec Console (cloud) |
| **Firewall Bouncer** | systemd service | IP ban enforcement via iptables/nftables |
| **Your Platform** | varies | e.g. dockhand, portainer, dockge, etc. |

### Automatic NPM Setup (dockhand/portainer/dockge/cosmos)

For scripts with NPM API access, the following is done automatically:
- NPM admin password changed to a random value
- Proxy hosts created for the platform and Authelia
- Let's Encrypt SSL certificates requested and enforced
- Authelia auth snippets applied to the platform proxy host

### Credentials

All credentials are **randomly generated**, stored with mode 600 under the stack directory:

| Credential | Source |
|-----------|--------|
| NPM admin | `STACK_DIR/.npm_admin_password` |
| Authelia admin | `STACK_DIR/authelia/.default_password` |

---

## Network Flow

```
INTERNET → UFW/Firewalld → NPM (80/443/81) → Docker proxy network
                                                    │
                    ┌───────────────────────────────┴───────────────┐
                    │                                               │
               <platform>:<port>                            authelia:9091
               (Authelia 2FA)                               (bypass - login)

  crowdsec (container)  →  reads NPM/SSH logs, enforces bans, enrolled in CrowdSec Console (cloud)
```

**Only 3 ports exposed.** All containers communicate via the `proxy` Docker network. NPM is the single entry point.

---

## Accessing the NPM Admin Panel

The NPM admin UI is published on port **81**. After deploy, reach it at:

```
http://<your-vps-ip>:81
```

Log in with `admin@example.com` and the password stored in `STACK_DIR/.npm_admin_password`. Use it to add/edit proxy hosts and SSL certs.

> **Note — port 81 is public.** While open, the admin panel is reachable from the internet and is a standing attack surface. `harden.sh` leaves 81 exposed **by default** (`LOCKDOWN_NPM_ADMIN=0`) since it's needed during setup. Recommended: finish your proxy-host configuration, then lock it down with **`LOCKDOWN_NPM_ADMIN=1 ./harden.sh`** — its `lockdown_npm_admin` step re-binds 81 to `127.0.0.1`. After that, reach the panel via SSH tunnel: `ssh -L 8181:127.0.0.1:81 root@<vps>` then `http://localhost:8181`. Re-run with `LOCKDOWN_NPM_ADMIN=0` to re-expose. (Note: configuring your *apps* never needs port 81 — they're reached at their own subdomains through NPM.)

---

## Authelia 2FA — Protecting Every Subdomain

Authelia is deployed with every script. By default, `authelia.YOURDOMAIN.com` is bypassed (you need to log in), and **every other subdomain** (`*.YOURDOMAIN.com`) requires 2FA.

### Default Login

| Field | Value |
|-------|-------|
| URL | `https://authelia.YOURDOMAIN.com` |
| Username | `admin` |
| Password | Random — stored in `STACK_DIR/authelia/.default_password` (mode 600) |

### Identity Verification Codes

Authelia requires a one-time code for sensitive actions:

```bash
sudo docker exec authelia cat /config/notifications.txt
```

### Change Password / Set Up TOTP

1. Login to `https://authelia.YOURDOMAIN.com` with `admin` / password from `.default_password`
2. For identity verification, run the command above and paste the code
3. **Settings → Password** to change password
4. **Settings → Two-Factor Authentication → One-Time Password → Add** to set up TOTP

### Protecting a NEW Container

For any new container you deploy after the initial setup:

1. Create an NPM proxy host for it
2. Go to the **Advanced** tab
3. Paste in the Custom Nginx Configuration:
   ```
   include /data/nginx/custom/authelia-location.conf;
   include /data/nginx/custom/authelia-authrequest.conf;
   ```
4. Save

That's it — no YAML edits, no restarts. The `*.YOURDOMAIN.com` wildcard in Authelia's access control covers every subdomain automatically.

---

## Adding Another Domain — `add-domain.sh`

Attach a **second (or third) root domain** to an already-running stack — additively and safely. Two domains can run side by side indefinitely, or you can add the new one, verify it, then delete the old hosts/certs in the NPM UI at your leisure.

```bash
# New domain + its Authelia SSO realm + a protected app, all SSL'd:
sudo ./add-domain.sh newdomain.com --app portainer:portainer:9000

# Public app (no 2FA):
sudo ./add-domain.sh newdomain.com --open status:uptime-kuma:3001

# Domain that doesn't need SSO at all:
sudo ./add-domain.sh newdomain.com --no-authelia --open www:myapp:8080

# Preview only — change nothing:
sudo ./add-domain.sh newdomain.com --app portainer:portainer:9000 --dry-run
```

| Option | Effect |
|--------|--------|
| `--app SUB:HOST:PORT` | Create `SUB.<domain>` → `HOST:PORT`, **Authelia-protected**. Repeatable. |
| `--open SUB:HOST:PORT` | Same, but **public** (no Authelia). Repeatable. |
| `--no-authelia` | Skip wiring an Authelia realm for this domain. |
| `--email ADDR` | Let's Encrypt email (default `admin@<domain>`). |
| `--stack DIR` | NPM stack dir (default: auto-detect under `/opt`). |
| `--dry-run` | Print the plan, change nothing. |

**Safe on a live system by design:** it never purges or edits existing proxy hosts/certs, is idempotent (skips anything already in place), and edits Authelia behind a backup — if the container fails its health check after the edit, the config is **automatically rolled back**. It auto-creates `authelia.<domain>` and reuses the existing domain-agnostic Authelia nginx snippets (no per-domain nginx changes).

> **DNS first:** point `*.newdomain.com → <vps-ip>` before running, so Let's Encrypt can validate. If DNS isn't ready, the host is created HTTP-only and warns you — re-run later (idempotent) or finish SSL in the NPM UI.
>
> Wiring Authelia restarts the `authelia` container (~3-5s); existing sessions re-validate — not an outage. `--no-authelia` avoids it. Each cookie domain is its own SSO realm (a login on domain A does not carry to domain B — cookies can't cross domains).

---

## CrowdSec — Intrusion Prevention

CrowdSec runs as a Docker container with these free, log-based hub collections:
- `crowdsecurity/sshd` — SSH brute force
- `crowdsecurity/nginx-proxy-manager` — NPM attack detection (probing/sqli/xss/traversal)
- `crowdsecurity/linux` — system-wide rules
- `crowdsecurity/http-cve` — known-CVE exploit probing (Log4j etc.)
- `crowdsecurity/http-dos` — L7 HTTP flood/DoS detection
- `crowdsecurity/whitelist-good-actors` — avoids banning legit crawlers (Google/Bing/etc.)

> AppSec (inline WAF) collections are intentionally **not** included: they need CrowdSec's AppSec component (an in-band listener + reverse-proxy forwarding) that NPM does not provide out of the box. The free **Cloudflare Managed WAF ruleset** covers the inline-filtering role for traffic behind Cloudflare.

The **firewall bouncer** runs as a systemd service and enforces bans in real time at the iptables/nftables level, including Docker-published ports via the `DOCKER-USER` chain.

### Cloudflare edge enforcement (optional, free)

Set `CF_API_TOKEN` (a Cloudflare **User** API token) and the deploy installs the **CrowdSec Cloudflare Worker bouncer**, blocking banned IPs at Cloudflare's edge before traffic reaches the VPS. NPM is also configured to restore the real visitor IP from `CF-Connecting-IP` (so bans key on the true client, not Cloudflare). All free, no subscription.

**Automated for you:** token discovery of zone/account IDs, the bouncer config + LAPI key, the systemd service, the Worker + KV + route deploy, real-IP restoration in NPM, and (with `LOCK_HTTP_TO_CLOUDFLARE=true`) the 80/443 origin lockdown.

**No token at the prompt?** The script still installs the bouncer and writes its config, skips the live Cloudflare deploy, and prints exactly how to finish later. Nothing breaks.

**Still your hands** (no Cloudflare API exists for these — the script prompts/prints them as an end-of-run checklist):
1. **Create the User API token** (My Profile → API Tokens, *not* an Account token) with the perms the prompt lists.
2. **Worker Route → Fail open**: `${DOMAIN} > Workers Routes > the crowdsec route > Edit > Request limit failure mode > Fail open`. Without it, a worker error shows visitors a CF 1027 page.
3. **Enable the free Managed WAF ruleset**: `${DOMAIN} > Security > WAF > Managed rules > enable` (inline OWASP-style filtering, free plan).

To deploy the bouncer on an **already-running** stack without redeploying, set the token + zone/account IDs in `/etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml`, then `systemctl enable --now crowdsec-cloudflare-worker-bouncer`.

### Console (cloud)

Each deploy enrolls the CrowdSec instance in the **CrowdSec Console** via `cscli console enroll --auto`. View alerts, decisions, and metrics at [app.crowdsec.net](https://app.crowdsec.net) — accept the pending enrollment there. If enrollment was skipped (LAPI not ready at deploy time), run:

```bash
docker exec crowdsec cscli console enroll --auto
```

Local CLI inspection is also available any time:

```bash
docker exec crowdsec cscli alerts list
docker exec crowdsec cscli decisions list
```

---

## Post-Deploy Verification

Every script includes a `verify_deployment()` stage that runs automatically before declaring success. It checks:

- All containers running
- NPM API responding
- NPM default credentials rejected (password was changed)
- Authelia health endpoint OK
- nginx config valid
- Authelia snippets present in NPM's custom dir
- CrowdSec LAPI responding
- Acquisition label is `nginx-proxy-manager`
- `crowdsecurity/nginx-proxy-manager` collection installed
- Bouncer registered in LAPI
- Firewall bouncer service ACTIVE
- **Live end-to-end ban test** — bans a test IP and verifies it appears in firewall rules

Failures are non-fatal (warn level) with exact debug commands printed.

---

## Architecture

### Runtime Directories

| Script | Directory |
|--------|-----------|
| `deploy-dockhand.sh` | `/opt/dockhand-stack/` |
| `deploy-portainer.sh` | `/opt/portainer-stack/` |
| `deploy-dockge.sh` | `/opt/dockge-stack/` |
| `deploy-cosmos.sh` | `/opt/cosmos-stack/` |
| `deploy-coolify.sh` | `/opt/coolify-stack/` |
| `deploy-dokploy.sh` | `/opt/dokploy-stack/` |
| `deploy-casaos.sh` | `/opt/casaos-stack/` |
| `deploy-runtipi.sh` | `/opt/runtipi-stack/` |
| `deploy-yunohost.sh` | `/opt/yunohost-stack/` |
| `deploy-freedombox.sh` | `/opt/freedombox-stack/` |

Each stack directory contains:
```
STACK_DIR/
├── docker-compose.npm.yml
├── docker-compose.authelia.yml
├── docker-compose.crowdsec.yml
├── docker-compose.<platform>.yml   (if applicable)
├── data/               ← NPM data
├── letsencrypt/        ← SSL certificates
├── crowdsec/           ← CrowdSec data + config
├── authelia/           ← Authelia config + secrets + snippets
│   ├── config/
│   ├── secrets/
│   └── snippets/
├── .npm_admin_password
└── authelia/.default_password
```

### Repository Files

```
.
├── deploy.sh                  ← Unified menu
├── harden.sh                  ← Security hardening (run after deploy; LOCKDOWN_NPM_ADMIN toggle)
├── add-domain.sh              ← Additively attach another domain (NPM hosts + Authelia realm)
├── deploy-dockhand.sh         ← NPM + Dockhand + Authelia + CrowdSec
├── deploy-netbird.sh          ← Traefik + Authentik + NetBird + Dockhand (zero-trust; staging)
├── deploy-portainer.sh        ← NPM + Portainer + Authelia + CrowdSec
├── deploy-dockge.sh           ← NPM + Dockge + Authelia + CrowdSec
├── deploy-cosmos.sh           ← NPM + Cosmos + Authelia + CrowdSec
├── deploy-coolify.sh          ← NPM + Coolify + Authelia + CrowdSec
├── deploy-dokploy.sh          ← NPM + Dokploy + Authelia + CrowdSec
├── deploy-casaos.sh           ← NPM + CasaOS + Authelia + CrowdSec
├── deploy-runtipi.sh          ← NPM + Runtipi + Authelia + CrowdSec
├── deploy-yunohost.sh         ← NPM + YunoHost + Authelia + CrowdSec
├── deploy-freedombox.sh       ← NPM + FreedomBox + Authelia + CrowdSec
├── .gitattributes             ← Forces LF endings (CRLF breaks bash on Linux)
└── README.md                  ← This file
```

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Containers unreachable | `grep DEFAULT_FORWARD_POLICY /etc/default/ufw` — should be `ACCEPT` |
| Containers unreachable after `harden.sh` | `sysctl net.ipv4.ip_forward` — **must be `1`** (Docker needs IP forwarding; fixed in harden.sh) |
| Can't reach NPM admin (:81) | Check `ss -tlnp \| grep ':81'`. If you ran `harden.sh` with `LOCKDOWN_NPM_ADMIN=1`, 81 is localhost-only — use the SSH tunnel: `ssh -L 8181:127.0.0.1:81 root@<vps>` then `http://localhost:8181`. Re-expose with `LOCKDOWN_NPM_ADMIN=0 ./harden.sh` |
| Port 80/443 conflict | `ss -tlnp \| grep ':80 '` — another service may still be bound |
| New subdomain gets 403 | Verify the two include lines are in NPM's Advanced tab |
| CrowdSec not catching | `docker exec crowdsec cscli metrics && docker exec crowdsec cscli decisions list` |
| Bouncer not active | `journalctl -u crowdsec-firewall-bouncer -n 50` |
| Script failed | Check `/var/log/vps-deploy.log` |
| Authelia crash-looping | `docker logs authelia` — usually missing `users.yml` |

### Restarting

```bash
cd /opt/<platform>-stack
docker compose -f docker-compose.npm.yml restart
docker compose -f docker-compose.authelia.yml restart
docker compose -f docker-compose.crowdsec.yml restart
```

---

## License

MIT — Use at your own risk. See the security disclaimer at the top of this file.
