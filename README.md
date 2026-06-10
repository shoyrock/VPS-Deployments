# VPS Deployment Scripts

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

One-shot, hardened deployment scripts for fresh VPS instances. Every script includes **Nginx Proxy Manager** (main reverse proxy + SSL), **CrowdSec** (IP firewall with NPM-aware collections), and **firewall rules**.

---

## Quick Reference

### Menu Options

| # | Option | What It Deploys | Notes |
|---|--------|----------------|-------|
| 1 | Portainer | NPM + Portainer | Visual container management |
| 2 | Dockge | NPM + Dockge | Compose stack manager |
| 3 | Coolify | NPM + Coolify | PaaS — **native 2FA** |
| 4 | Dokploy | NPM + Dokploy | PaaS — **native 2FA** |
| 5 | CasaOS | NPM + CasaOS | Home server with app store |
| 6 | Runtipi | NPM + Runtipi | Home server + 300 apps |
| 7 | Cosmos | NPM + Cosmos | All-in-one homelab suite |
| 8 | YunoHost | NPM + YunoHost | Debian server distro (Debian 12 only) |
| 9 | FreedomBox | NPM + FreedomBox | Debian home server (Debian 12 only) |
| 10 | **Harden** | **Full system hardening** | Run after deployment — see below |

**All scripts expose only 3 ports: 80 (HTTP), 443 (HTTPS), 81 (NPM admin).** Individual tool containers have **no host ports** — they communicate internally via Docker's `proxy` network using their container hostnames (see table below).

---

## Container Hostnames

All containers connect to the `proxy` Docker network and are reachable by hostname from NPM:

| Container | Hostname | NPM Proxy Host Forward |
|-----------|----------|----------------------|
| Nginx Proxy Manager | `npm` | (is the proxy) |
| Portainer | `portainer` | `http://portainer:9000` |
| Dockge | `dockge` | `http://dockge:5001` |
| Coolify | `coolify` | `http://coolify:8000` |
| Dokploy | `dokploy` | `http://dokploy:3000` |
| CasaOS | `casaos` | `http://casaos:8080` |
| Runtipi | `runtipi` | `http://runtipi:80` |
| Cosmos | `cosmos-server` | `http://cosmos-server:80` |
| Authelia | `authelia` | `http://authelia:9091` (internal-only, not exposed) |

**No tool container exposes ports directly to the host.** All traffic flows through NPM on ports 80/443.

---

## How to Use

### Option 1: Use the Menu (Recommended)

```bash
curl -fsSL -o deploy.sh https://raw.githubusercontent.com/shoyrock/VPS-Deployments/main/deploy.sh
chmod +x deploy.sh
./deploy.sh
```

Pick your tool from the menu and follow the prompts.

### Option 2: Direct Deploy

```bash
./deploy.sh portainer    # Deploy Portainer
./deploy.sh dockge       # Deploy Dockge
./deploy.sh coolify      # Deploy Coolify
./deploy.sh dokploy      # Deploy Dokploy
./deploy.sh casaos       # Deploy CasaOS
./deploy.sh harden       # Harden the system
```

### Option 3: Direct Script Download (skip menu)

```bash
curl -fsSL -o deploy-portainer.sh https://raw.githubusercontent.com/shoyrock/VPS-Deployments/main/deploy-portainer.sh
chmod +x deploy-portainer.sh
./deploy-portainer.sh
```

**Supported OS:** Ubuntu 20.04+, Debian 11+, Rocky/AlmaLinux 8/9, Fedora 35+, CentOS 7/8

**Debian 12 only:** `deploy-yunohost.sh` and `deploy-freedombox.sh` (reject Ubuntu)

**Requirements:** Root access, internet connectivity, 2GB+ free disk

---

## Architecture

### Docker Compose Stacks

Each deployment uses **Docker Compose** — but the structure depends on the tool type:

| Tier | Tools | Compose Structure | Why |
|------|-------|-------------------|-----|
| **Unified Stack** | Portainer, Dockge, Cosmos | **Single** `docker-compose.yml` with both NPM + tool | Pure Docker containers — can coexist in one compose file |
| **Hybrid** | Coolify, Dokploy, CasaOS, Runtipi | NPM in compose + tool via `curl \| bash` installer | Tool requires systemd services, custom networking, or non-Docker components |
| **OS Distro** | YunoHost, FreedomBox | NPM in compose + full Debian OS install | These are complete Debian server distributions, not just containers |

### Unified Stack (Portainer, Dockge, Cosmos)

These scripts create a **single directory** and **single `docker-compose.yml`**:

```
/opt/portainer-stack/
├── docker-compose.yml     ← npm + portainer services together
├── data/                  ← NPM data
├── letsencrypt/           ← NPM SSL certificates
└── ...

/opt/dockge-stack/
├── docker-compose.yml     ← npm + dockge services together
├── ...

/opt/cosmos-stack/
├── docker-compose.yml     ← npm + cosmos-server services together
├── ...
```

One `docker compose up -d` starts both NPM and the dashboard. Both services attach to the external `proxy` network automatically.

### Hybrid Stack (Coolify, Dokploy, CasaOS, Runtipi)

These tools use their official `curl | bash` installers which set up systemd services, custom Docker networks, and non-container components. The script:

1. Creates `/opt/npm/docker-compose.yml` for Nginx Proxy Manager
2. Runs the tool's official installer
3. Disables the tool's built-in proxy to prevent port conflicts
4. Connects the tool's container to the `proxy` network

### OS Distro (YunoHost, FreedomBox)

These are full Debian server distributions. The script:

1. Installs the Debian-based OS/distro on the VPS
2. Creates `/opt/npm/docker-compose.yml` for Nginx Proxy Manager (on port 81)
3. The distro keeps its own web server on ports 80/443

### Network Flow

```
INTERNET ──► UFW/Firewalld ──► NPM (80/443/81) ──► Docker proxy network
                                                        │
                              ┌─────────────────────────┼─────────────────────────┐
                              │                         │                         │
                           portainer                 dockge                   coolify
                           (hostname)               (hostname)               (hostname)
                           :9000                    :5001                    :8000
```

**Only 3 ports are exposed to the internet.** All tool containers are internal-only — no host ports. They communicate with NPM via Docker's internal `proxy` network using their hostnames. NPM is the single entry point for all HTTP/HTTPS traffic.

**CrowdSec** (all scripts) includes:
- `crowdsecurity/sshd` collection — SSH brute force protection
- `crowdsecurity/nginx-proxy-manager` collection — NPM-specific attack detection
- `crowdsecurity/linux` collection — Linux system-wide rules
- `crowdsec-firewall-bouncer-iptables` — Real-time IP blocking via iptables

## Authelia 2FA (Portainer, Dockge, Cosmos)

The three unified stack scripts (Portainer, Dockge, Cosmos) include **Authelia** for two-factor authentication.

### Default Login

| Field | Value |
|-------|-------|
| URL | `https://authelia.YOURDOMAIN.com` |
| Username | `admin` |
| Password | `authelia` |

**Change this password immediately after first login.**

### Identity Verification Codes

Authelia requires a one-time code for sensitive actions (changing password, adding TOTP). Since email is not configured, codes are written to a file:

```bash
# Get your verification code
sudo docker exec authelia cat /config/notifications.txt
```

Paste the code from that file into the "One-Time Code" dialog, then click **Verify**.

### Change Your Password

1. Login to Authelia with `admin` / `authelia`
2. You will be prompted for identity verification — get the code from the command above
3. Go to **Settings** → **Password** → enter new password
4. Authelia will generate a new hash and update `users.yml` automatically

### Set Up TOTP (Two-Factor Authentication)

1. Login to Authelia
2. Go to **Settings** → **Two-Factor Authentication** → **One-Time Password** → **Add**
3. Scan the QR code with your phone's authenticator app (Google Authenticator, Microsoft Authenticator, Authy, etc.)
4. Enter the 6-digit code to confirm
5. Now all your dashboards require 2FA

### Protect Dashboards with Authelia

To require Authelia 2FA before accessing a dashboard:

1. In NPM, edit the proxy host's **Advanced** tab
2. Paste the contents of `/opt/<tool>-stack/authelia/snippets/authelia-authrequest.conf`
3. Save

### How Built-in Proxies Are Handled

| Tool | Built-in Proxy | Status | What Script Does |
|------|---------------|--------|-----------------|
| **Coolify** | Traefik | ✅ Disabled | Stopped, tool proxied via NPM at `http://coolify:8000` |
| **Dokploy** | Traefik | ✅ Disabled | Stopped, tool proxied via NPM at `http://dokploy:3000` |
| **CasaOS** | Gateway | ✅ Disabled | Moved to internal port 8080, proxied via NPM |
| **Runtipi** | Traefik | ✅ Disabled | Moved to internal ports 8080/8443, proxied via NPM |
| **Cosmos** | Host mode | ✅ Disabled | Changed to bridge mode, proxied via NPM |
| **YunoHost** | nginx | ℹ️ Own proxy | Keeps 80/443, NPM on port 81 |
| **FreedomBox** | Apache | ℹ️ Own proxy | Keeps 80/443, NPM on port 81 |

---

## Security Hardening (`harden.sh`)

After deploying any tool, run the hardening script to lock down the VPS. This is **standalone** — no third-party accounts, no Cloudflare, no paid services.

```bash
./deploy.sh harden          # Via unified menu
./deploy.sh                 # Pick option 12 (Harden VPS)
```

**Do NOT run `harden.sh` before deploying.** It does not destroy containers, but it locks down port 81 to localhost-only and enables CrowdSec — you want your dashboards accessible first, then hardened after setup.

### What It Does (all automatic)

| Layer | What | Tool |
|-------|------|------|
| **SSH Lockdown** | Disable root login, key-only auth, protocol 2, connection timeouts | OpenSSH config |
| **Kernel Hardening** | SYN cookies, RP filter, no source routing, ASLR, no ICMP redirects | sysctl |
| **Firewall Rate Limit** | Throttle connections per IP on 22/80/443 | UFW / firewalld |
| **GeoIP Block** | Auto-block CN, RU, KP, IR via free ipdeny.com lists | iptables + cron |
| **Intrusion Detection** | Behavior-based local IDS, SSH + NPM monitoring | CrowdSec (local mode) |
| **File Integrity** | Daily scan of /bin, /sbin, /usr, /etc for unauthorized changes | AIDE |
| **Auto Updates** | Security patches only, 24h delay, auto-reboot in maintenance window | unattended-upgrades |
| **NPM Admin Lockdown** | Port 81 bound to 127.0.0.1 only (access via SSH tunnel) | docker-compose |
| **Docker Security** | Log rotation (10m/3 files), live-restore, userland-proxy off | daemon.json |
| **Daily Backups** | /opt + /etc archived to /backups, 7-day retention | tar + cron |

All config changes are backed up with `.harden-backup-<timestamp>` suffix before modification.

### How Built-in Proxies Are Handled

| Tool | Built-in Proxy | What Script Does |
|------|---------------|-----------------|
| **Coolify** | Traefik on 80/443 | Stopped after install (`docker stop coolify-proxy`) |
| **Dokploy** | Traefik on 80/443 | Stopped after install (`docker stop dokploy-traefik`) |
| **CasaOS** | Gateway on 80 | Reconfigured to port 8080 |
| **Runtipi** | Traefik on 80/443 | Reconfigured to port 8080/8443 |
| **Cosmos** | Host mode on 80/443 | Changed to bridge mode with ports 8080/8443 |
| **YunoHost** | nginx on 80/443 | **Cannot be disabled** — essential for app routing |
| **FreedomBox** | Apache on 80/443 | **Cannot be disabled** — essential for app routing |

---

## Two-Factor Authentication (2FA) Options

### Option A: Native 2FA (Simplest — No Extra Containers)

Some dashboards have built-in 2FA toggles. Just enable them in their settings:

| Dashboard | Has Native 2FA | How to Enable |
|-----------|---------------|---------------|
| **Coolify** | ✅ Yes | Settings → Security → Enable 2FA → scan QR code |
| **Dokploy** | ✅ Yes | Settings → Security → Enable 2FA → scan QR code |
| Portainer, Dockge, CasaOS, Cosmos, Runtipi | ❌ No | Use Option B (Authelia) below |

**Best for:** If you only use Coolify and/or Dokploy as your main platforms.

### Option B: Authelia 2FA (Universal — Protects ALL Dashboards)

Authelia is a separate container that adds a login portal with TOTP 2FA to **every** dashboard behind NPM — even those without native 2FA.

**How it works:**
```
User → portainer.example.com → Authelia login gate → password + 6-digit code → Portainer
```

**Deploy:**
```bash
curl -fsSL -o deploy-authelia.sh https://raw.githubusercontent.com/shoyrock/VPS-Deployments/main/deploy-authelia.sh
chmod +x deploy-authelia.sh
./deploy-authelia.sh
```

**Best for:** Multiple dashboards with one login + 2FA for all. Can be added anytime later.

---

## Post-Deployment Steps

### 1. Access NPM Admin
```
http://YOUR_VPS_IP:81
Default: admin@example.com / changeme
→ Change password immediately
```

### 2. Add Proxy Host for Your Tool
In NPM → Hosts → Proxy Hosts → Add:
- **Domain Names**: `your-domain.com`
- **Scheme**: `http`
- **Forward Hostname/IP**: `toolname` (e.g., `portainer`, `coolify`, `dockge`)
- **Forward Port**: The tool's port (e.g., 9000, 8000, 5001, 3000)
- **Websockets**: ON (if needed)

### 3. Request SSL
NPM → SSL Certificates → Add → Let's Encrypt

### 4. Secure Port 81
```bash
# After you have a domain pointing to NPM
sudo ufw delete allow 81/tcp && sudo ufw reload
```

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `Permission denied to socket` | Use `sudo` for `docker` commands |
| Containers unreachable | `grep DEFAULT_FORWARD_POLICY /etc/default/ufw` — should be `ACCEPT` |
| Port 80/443 conflict | `ss -tlnp \| grep ':80 '` — another service may still be bound |
| CrowdSec not catching | `sudo cscli metrics && sudo cscli decisions list` |
| Script failed | Check `/var/log/vps-deploy.log` |

### Restarting Stacks

**Unified stacks** (Portainer, Dockge, Cosmos):
```bash
cd /opt/portainer-stack && docker compose restart   # Restart NPM + Portainer
cd /opt/dockge-stack && docker compose restart      # Restart NPM + Dockge
cd /opt/cosmos-stack && docker compose restart      # Restart NPM + Cosmos
```

**Hybrid stacks** (Coolify, Dokploy, CasaOS, Runtipi):
```bash
cd /opt/npm && docker compose restart               # Restart NPM only
docker restart coolify                              # Restart Coolify only
docker restart dokploy                              # Restart Dokploy only
```

---

## File Layout

### Repository Files

```
.
├── deploy.sh                  ← Unified menu (run this first)
├── harden.sh                  ← 🔒 Security hardening (run after deploy)
├── deploy-portainer.sh        ← Unified compose: NPM + Portainer
├── deploy-dockge.sh           ← Unified compose: NPM + Dockge
├── deploy-cosmos.sh           ← Unified compose: NPM + Cosmos
├── deploy-coolify.sh          ← Hybrid: NPM compose + Coolify installer
├── deploy-dokploy.sh          ← Hybrid: NPM compose + Dokploy installer
├── deploy-casaos.sh           ← Hybrid: NPM compose + CasaOS installer
├── deploy-runtipi.sh          ← Hybrid: NPM compose + Runtipi installer
├── deploy-yunohost.sh         ← OS distro: NPM (81) + YunoHost
├── deploy-freedombox.sh       ← OS distro: NPM (81) + FreedomBox
├── deploy-authelia.sh         ← Optional 2FA portal (manual install)
└── README.md                  ← This file
```

### Runtime Directories

After deployment, you'll find:

| Script | Directory | What's Inside |
|--------|-----------|---------------|
| `deploy-portainer.sh` | `/opt/portainer-stack/` | `docker-compose.yml` with `npm` + `portainer` |
| `deploy-dockge.sh` | `/opt/dockge-stack/` | `docker-compose.yml` with `npm` + `dockge` |
| `deploy-cosmos.sh` | `/opt/cosmos-stack/` | `docker-compose.yml` with `npm` + `cosmos-server` |
| `deploy-coolify.sh` | `/opt/npm/` + `/data/coolify/` | NPM compose + Coolify's own files |
| `deploy-dokploy.sh` | `/opt/npm/` + `/etc/dokploy/` | NPM compose + Dokploy's own files |
| `deploy-casaos.sh` | `/opt/npm/` + `/casaos/` | NPM compose + CasaOS's own files |
| `deploy-runtipi.sh` | `/opt/npm/` + `~/runtipi/` | NPM compose + Runtipi's own files |
| `deploy-yunohost.sh` | `/opt/npm/` | NPM compose only (YunoHost is system-level) |
| `deploy-freedombox.sh` | `/opt/npm/` | NPM compose only (FreedomBox is system-level) |
| `deploy-authelia.sh` | `/opt/authelia/` | Authelia compose + config + snippets |

---

## License

MIT — Use at your own risk. See the security disclaimer at the top of this file.
