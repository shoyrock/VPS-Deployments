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

| # | Script | What It Deploys | NPM Port | Notes |
|---|--------|----------------|----------|-------|
| — | **`deploy.sh`** | **Unified menu** — pick any tool interactively or via CLI | — | Run this for the menu |
| 1 | `deploy-portainer.sh` | NPM + Portainer | 80/443/81 | Visual container management |
| 2 | `deploy-dockge.sh` | NPM + Dockge | 80/443/81 | Compose stack manager |
| 3 | `deploy-coolify.sh` | NPM + Coolify | 80/443/81 | PaaS — Traefik disabled, proxied via NPM |
| 4 | `deploy-dokploy.sh` | NPM + Dokploy | 80/443/81 | PaaS — Traefik disabled, proxied via NPM |
| 5 | `deploy-dokku.sh` | NPM + Dokku | 81 | PaaS — Dokku's nginx stays on 80/443 |
| 6 | `deploy-runtipi.sh` | NPM + Runtipi | 80/443/81 | Runtipi Traefik moved to 8080/8443 |
| 7 | `deploy-casaos.sh` | NPM + CasaOS | 80/443/81 | CasaOS gateway moved to 8080 |
| 8 | `deploy-cosmos.sh` | NPM + Cosmos | 80/443/81 | Cosmos moved to bridge mode 8080/8443 |
| 9 | `deploy-caprover.sh` | NPM + CapRover | 81 | CapRover's nginx stays on 80/443 |
| 10 | `deploy-yunohost.sh` | NPM + YunoHost | 81 | YunoHost's nginx stays on 80/443 (Debian 12) |
| 11 | `deploy-freedombox.sh` | NPM + FreedomBox | 81 | FreedomBox's Apache stays on 80/443 (Debian 12) |

**Tools with NPM on 80/443/81 (primary proxy)**: Portainer, Dockge, Coolify, Dokploy, CasaOS, Runtipi, Cosmos — their built-in proxies are disabled/reconfigured so NPM handles all HTTP/S traffic.

**Tools with NPM on 81 only (supplementary proxy)**: CapRover, Dokku, YunoHost, FreedomBox — their built-in web servers are essential to their core functionality and cannot be disabled. NPM runs on port 81 for proxying additional services.

---

## How to Use

### Option 1: Unified Menu (Recommended)

```bash
curl -fsSL -o deploy.sh https://raw.githubusercontent.com/shoyrock/VPS-Deployments/main/deploy.sh
chmod +x deploy.sh
./deploy.sh              # Interactive menu — pick a number
./deploy.sh portainer    # Direct deploy, skip menu
./deploy.sh dockge       # Direct deploy
./deploy.sh coolify      # Direct deploy
```

### Option 2: Individual Scripts

```bash
curl -fsSL -o deploy-tool.sh https://raw.githubusercontent.com/shoyrock/VPS-Deployments/main/deploy-tool.sh
chmod +x deploy-tool.sh
sudo ./deploy-tool.sh
```

**Supported OS:** Ubuntu 20.04+, Debian 11+, Rocky/AlmaLinux 8/9, Fedora 35+, CentOS 7/8

**Debian 12 only:** `deploy-yunohost.sh` and `deploy-freedombox.sh` (reject Ubuntu)

**Requirements:** Root access, internet connectivity, 2GB+ free disk

---

## Architecture

Every script follows this pattern:

```
INTERNET ──► UFW/Firewalld ──► NPM (80/443/81 or 81 only) ──► Dashboard Tool
                                          │
                                    Fail2Ban (log monitoring)
                                          │
                                    UFW blocks banned IPs
```

**Fail2Ban** (all scripts) includes:
- `sshd` jail — SSH brute force protection
- `npm-auth` — NPM login brute force
- `npm-forceful-browsing` — Bot/scanner detection (custom filter for NPM's log format)
- `npm-botsearch` — Admin panel enumeration detection

### How Built-in Proxies Are Handled

| Tool | Built-in Proxy | What Script Does |
|------|---------------|-----------------|
| **Coolify** | Traefik on 80/443 | Stopped after install (`docker stop coolify-proxy`) |
| **Dokploy** | Traefik on 80/443 | Stopped after install (`docker stop dokploy-traefik`) |
| **CasaOS** | Gateway on 80 | Reconfigured to port 8080 |
| **Runtipi** | Traefik on 80/443 | Reconfigured to port 8080/8443 |
| **Cosmos** | Host mode on 80/443 | Changed to bridge mode with ports 8080/8443 |
| **CapRover** | nginx on 80/443 | **Cannot be disabled** — essential for app routing |
| **Dokku** | nginx on 80/443 | **Cannot be disabled** — essential for app routing |
| **YunoHost** | nginx on 80/443 | **Cannot be disabled** — essential for app routing |
| **FreedomBox** | Apache on 80/443 | **Cannot be disabled** — essential for app routing |

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
├── deploy.sh                  ← Unified menu (run this)
├── deploy-portainer.sh        ← NPM + Portainer
├── deploy-dockge.sh           ← NPM + Dockge
├── deploy-coolify.sh          ← NPM + Coolify (Traefik disabled)
├── deploy-dokploy.sh          ← NPM + Dokploy (Traefik disabled)
├── deploy-cosmos.sh           ← NPM + Cosmos (bridge mode)
├── deploy-casaos.sh           ← NPM + CasaOS (port 8080)
├── deploy-runtipi.sh          ← NPM + Runtipi (Traefik on 8080)
├── deploy-caprover.sh         ← NPM (81) + CapRover
├── deploy-dokku.sh            ← NPM (81) + Dokku
├── deploy-yunohost.sh         ← NPM (81) + YunoHost (Debian 12)
├── deploy-freedombox.sh       ← NPM (81) + FreedomBox (Debian 12)
└── README.md                  ← This file
```

---

## License

MIT — Use at your own risk. See the security disclaimer at the top of this file.
