# VPS Deployment Scripts — v4.5.0-hardened

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
| `deploy-portainer.sh` | NPM + Portainer + Authelia + CrowdSec | `/opt/portainer-stack/` | Visual container management |
| `deploy-dockge.sh` | NPM + Dockge + Authelia + CrowdSec | `/opt/dockge-stack/` | Compose stack manager |
| `deploy-cosmos.sh` | NPM + Cosmos + Authelia + CrowdSec | `/opt/cosmos-stack/` | All-in-one homelab |
| `deploy-coolify.sh` | NPM + Coolify + Authelia + CrowdSec | `/opt/coolify-stack/` | PaaS |
| `deploy-dokploy.sh` | NPM + Dokploy + Authelia + CrowdSec | `/opt/dokploy-stack/` | PaaS |
| `deploy-casaos.sh` | NPM + CasaOS + Authelia + CrowdSec | `/opt/casaos-stack/` | Home server with app store |
| `deploy-runtipi.sh` | NPM + Runtipi + Authelia + CrowdSec | `/opt/runtipi-stack/` | Home server + 300 apps |
| `deploy-yunohost.sh` | NPM + YunoHost + Authelia + CrowdSec | `/opt/yunohost-stack/` | Debian server distro (Debian 12 only) |
| `deploy-freedombox.sh` | NPM + FreedomBox + Authelia + CrowdSec | `/opt/freedombox-stack/` | Debian home server (Debian 12 only) |

**All scripts expose only 2 public ports: 80 (HTTP) and 443 (HTTPS).** The NPM admin panel (**81**) is bound to **`127.0.0.1` only** — it is *not* reachable from the internet and is accessed via an SSH tunnel (see [Accessing the NPM Admin Panel](#accessing-the-npm-admin-panel)). Individual tool containers have **no host ports** — they communicate internally via Docker's `proxy` network using their container hostnames.

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

**Env vars:**
- `FORCE_CLEANUP=1` — skip the destructive-cleanup confirmation (for CI/unattended runs)

**Supported OS:** Ubuntu 20.04+, Debian 11+, Rocky/AlmaLinux 8/9, Fedora 35+, Amazon Linux 2023

**Requirements:** Root access, internet, 2GB+ free disk, a domain pointed at your VPS

---

## What Gets Deployed

Every script deploys the same core stack plus one platform:

| Component | Container | Purpose |
|-----------|-----------|---------|
| **NPM** | `npm` | Reverse proxy on 80/443 (public) + admin UI on 127.0.0.1:81 (SSH tunnel only), Let's Encrypt SSL |
| **Authelia** | `authelia` | SSO login portal + TOTP 2FA on `authelia.YOURDOMAIN.com` |
| **CrowdSec** | `crowdsec` | Log-based intrusion detection, SSH + NPM monitoring |
| **CrowdSec Dashboard** | `crowdsec-dashboard` | Metabase dashboard on `crowdsec.YOURDOMAIN.com` |
| **Firewall Bouncer** | systemd service | IP ban enforcement via iptables/nftables |
| **Your Platform** | varies | e.g. dockhand, portainer, dockge, etc. |

### Automatic NPM Setup (dockhand/portainer/dockge/cosmos)

For scripts with NPM API access, the following is done automatically:
- NPM admin password changed to a random value
- Proxy hosts created for platform, Authelia, and CrowdSec dashboard
- Let's Encrypt SSL certificates requested and enforced
- Authelia auth snippets applied to the platform proxy host

### Credentials

All credentials are **randomly generated**, stored with mode 600 under the stack directory:

| Credential | Source |
|-----------|--------|
| NPM admin | `STACK_DIR/.npm_admin_password` |
| Authelia admin | `STACK_DIR/authelia/.default_password` |
| Metabase (CrowdSec) | `STACK_DIR/.metabase_password` |

---

## Network Flow

```
INTERNET → UFW/Firewalld → NPM (80/443 public) → Docker proxy network
                                                    │
                    ┌───────────────────────────────┼───────────────────────┐
                    │                               │                       │
               dockhand:3000                  authelia:9091          crowdsec-dashboard:3000
               (Authelia 2FA)                 (bypass - login)       (bypass - own auth)

  NPM admin UI :81  ──  bound to 127.0.0.1 only  ──  reach via SSH tunnel (localhost)
```

**Only 2 public ports (80/443).** The admin UI on 81 is localhost-only. All containers communicate via the `proxy` Docker network. NPM is the single public entry point.

---

## Accessing the NPM Admin Panel

The NPM admin UI (port **81**) is bound to `127.0.0.1` and is **not exposed to the internet**. Reach it through an SSH tunnel from your local machine:

```bash
ssh -L 8181:127.0.0.1:81 root@<your-vps-ip>
```

Leave that session open, then browse to **`http://localhost:8181`** locally. Log in with `admin@example.com` and the password stored in `STACK_DIR/.npm_admin_password`.

> **Why localhost-only?** A publicly exposed admin panel is a standing attack surface. Binding to `127.0.0.1` means the panel is unreachable from the network even if a firewall rule is misconfigured — access requires SSH (key) access first. The deployment itself is unaffected: NPM's automation talks to the API over `127.0.0.1` internally.

---

## Authelia 2FA — Protecting Every Subdomain

Authelia is deployed with every script. By default, `authelia.YOURDOMAIN.com` is bypassed (you need to log in), `crowdsec.YOURDOMAIN.com` is bypassed (Metabase has its own login), and **every other subdomain** (`*.YOURDOMAIN.com`) requires 2FA.

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

## CrowdSec — Intrusion Prevention

CrowdSec runs as a Docker container with three collections:
- `crowdsecurity/sshd` — SSH brute force
- `crowdsecurity/nginx-proxy-manager` — NPM attack detection
- `crowdsecurity/linux` — system-wide rules

The **firewall bouncer** runs as a systemd service and enforces bans in real time at the iptables/nftables level, including Docker-published ports via the `DOCKER-USER` chain.

### Dashboard

Access the read-only Metabase dashboard at `https://crowdsec.YOURDOMAIN.com`:
| Field | Value |
|-------|-------|
| Login | `crowdsec@crowdsec.net` |
| Password | Random — stored in `STACK_DIR/.metabase_password` (mode 600) |

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
├── .metabase_password
└── authelia/.default_password
```

### Repository Files

```
.
├── deploy.sh                  ← Unified menu
├── harden.sh                  ← Security hardening (run after deploy)
├── deploy-dockhand.sh         ← NPM + Dockhand + Authelia + CrowdSec
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
| Can't reach NPM admin (:81) | It's localhost-only by design — use the SSH tunnel: `ssh -L 8181:127.0.0.1:81 root@<vps>` then `http://localhost:8181` |
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
