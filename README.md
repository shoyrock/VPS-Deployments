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

One-shot, hardened deployment scripts for fresh VPS instances. Every script includes **Nginx Proxy Manager** (main reverse proxy + SSL), **Fail2Ban** (with custom filters for NPM's log format), and **firewall rules**.

---

## Quick Reference

### Menu Options

| # | Option | What It Deploys | Notes |
|---|--------|----------------|-------|
| **0** | **Light Bundle** | **NPM + Portainer** only | Minimal setup (~200MB RAM). Add more dashboards later. |
| 1 | Portainer | NPM + Portainer | Visual container management |
| 2 | Dockge | NPM + Dockge | Compose stack manager |
| 3 | Coolify | NPM + Coolify | PaaS — **native 2FA** — Coolify Traefik disabled |
| 4 | Dokploy | NPM + Dokploy | PaaS — **native 2FA** — Dokploy Traefik disabled |
| 5 | Dokku | NPM + Dokku | PaaS — uses Dokku's own nginx |
| 6 | Runtipi | NPM + Runtipi | Home server + 300 apps |
| 7 | CasaOS | NPM + CasaOS | Home server with app store |
| 8 | Cosmos | NPM + Cosmos | All-in-one homelab suite |
| 9 | YunoHost | NPM + YunoHost | Debian server distro (Debian 12 only) |
| 10 | FreedomBox | NPM + FreedomBox | Debian home server (Debian 12 only) |
| 11 | **Authelia** | **SSO + TOTP 2FA portal** | Optional — adds 2FA login to ALL dashboards |
| 12 | **Harden** | **Full system hardening** | Run after deployment — see below |

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

### Option 1: Light Bundle (Recommended for Fresh VPS)

The fastest way to get started. Deploys **NPM + Portainer** only — minimal resource usage, expand later.

```bash
curl -fsSL -o deploy.sh https://raw.githubusercontent.com/shoyrock/VPS-Deployments/main/deploy.sh
chmod +x deploy.sh
./deploy.sh              # Pick [0] Light Bundle from the menu
# Or directly: ./deploy.sh light
```

**After deploy:**
1. Access NPM at `http://YOUR_VPS_IP:81` (default: admin@example.com / changeme)
2. Add proxy host for Portainer: `portainer.yourdomain.com` → `http://portainer:9000`
3. Request SSL certificate
4. **Add more dashboards anytime:** `./deploy.sh` → pick another tool

### Option 2: Deploy with 2FA (Authelia)

For full protection, deploy Authelia after the light bundle. It adds a login gate with TOTP 2FA (Google/Microsoft Authenticator) to **all** your dashboards.

```bash
./deploy.sh light        # Step 1: deploy minimal setup
./deploy.sh authelia     # Step 2: add 2FA portal
```

**After Authelia deploy:**
1. Add DNS: `authelia.yourdomain.com` → your VPS IP
2. In NPM, add proxy host: `authelia.yourdomain.com` → `http://authelia:9091`
3. Visit `https://authelia.yourdomain.com`, login with default credentials
4. Register your Authenticator app (scan QR code)
5. For each dashboard proxy host, add the forward-auth config from `/opt/authelia/authelia-configure.sh`

### Option 3: Deploy Individual Tools

```bash
./deploy.sh portainer    # Deploy Portainer
./deploy.sh dockge       # Deploy Dockge
./deploy.sh coolify      # Deploy Coolify (has native 2FA toggle)
./deploy.sh dokploy      # Deploy Dokploy (has native 2FA toggle)
./deploy.sh authelia     # Deploy Authelia 2FA portal
./deploy.sh harden       # Harden the system
```

### Option 4: Direct Script Download (skip menu)

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

**Only 3 ports are exposed to the internet.** All tool containers are internal-only:

```
INTERNET ──► UFW/Firewalld ──► NPM (80/443/81) ──► Docker proxy network
                                                        │
                              ┌─────────────────────────┼─────────────────────────┐
                              │                         │                         │
                           portainer                 dockge                   coolify
                           (hostname)               (hostname)               (hostname)
                           :9000                    :5001                    :8000
```

Tool containers have **no host ports exposed**. They communicate with NPM via Docker's internal `proxy` network using their hostnames. NPM is the single entry point for all HTTP/HTTPS traffic.

**Fail2Ban** (all scripts) includes:
- `sshd` jail — SSH brute force protection
- `npm-auth` — NPM login brute force
- `npm-forceful-browsing` — Bot/scanner detection (custom filter for NPM's log format)
- `npm-botsearch` — Admin panel enumeration detection

### How Built-in Proxies Are Handled

| Tool | Built-in Proxy | Status | What Script Does |
|------|---------------|--------|-----------------|
| **Coolify** | Traefik | ✅ Disabled | Stopped, tool proxied via NPM at `http://coolify:8000` |
| **Dokploy** | Traefik | ✅ Disabled | Stopped, tool proxied via NPM at `http://dokploy:3000` |
| **CasaOS** | Gateway | ✅ Disabled | Moved to internal port 8080, proxied via NPM |
| **Runtipi** | Traefik | ✅ Disabled | Moved to internal ports 8080/8443, proxied via NPM |
| **Cosmos** | Host mode | ✅ Disabled | Changed to bridge mode, proxied via NPM |
| **Dokku** | nginx | ℹ️ Own proxy | Keeps 80/443 for app routing, NPM on port 81 |
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
| **Dokku** | nginx on 80/443 | **Cannot be disabled** — essential for app routing |
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
./deploy.sh authelia       # After deploying your dashboards
```

**Best for:** If you use multiple dashboards (Portainer, Dockge, CasaOS, etc.) and want one login with 2FA for all of them.

**Can be added anytime later** — it does not modify or break existing containers.

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
| `Permission denied to socket` | Use `sudo` for `fail2ban-client` |
| Containers unreachable | `grep DEFAULT_FORWARD_POLICY /etc/default/ufw` — should be `ACCEPT` |
| Port 80/443 conflict | `ss -tlnp \| grep ':80 '` — another service may still be bound |
| Fail2Ban not catching | `sudo fail2ban-regex -v /opt/npm/data/logs/proxy-host-1_access.log /etc/fail2ban/filter.d/npm-access.conf` |
| Script failed | Check `/var/log/vps-deploy.log` |

---

## File Layout

```
.
├── deploy.sh                  ← Unified menu (run this first)
├── harden.sh                  ← 🔒 Security hardening (run after deploy)
├── deploy-authelia.sh         ← 🔐 Optional SSO + TOTP 2FA portal
├── deploy-portainer.sh        ← NPM + Portainer (light bundle default)
├── deploy-dockge.sh           ← NPM + Dockge
├── deploy-coolify.sh          ← NPM + Coolify (native 2FA, Traefik disabled)
├── deploy-dokploy.sh          ← NPM + Dokploy (native 2FA, Traefik disabled)
├── deploy-cosmos.sh           ← NPM + Cosmos (bridge mode)
├── deploy-casaos.sh           ← NPM + CasaOS (port 8080)
├── deploy-runtipi.sh          ← NPM + Runtipi (Traefik on 8080)
├── deploy-dokku.sh            ← NPM (81) + Dokku
├── deploy-yunohost.sh         ← NPM (81) + YunoHost (Debian 12)
├── deploy-freedombox.sh       ← NPM (81) + FreedomBox (Debian 12)
└── README.md                  ← This file
```

---

## License

MIT — Use at your own risk. See the security disclaimer at the top of this file.
