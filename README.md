# VPS Deployment Scripts

One-shot, hardened deployment scripts for fresh VPS instances. Each script installs Docker, a reverse proxy / container management tool, Fail2Ban, and firewall rules.

> **Current date: 2025-06-07**

---

## Scripts Overview

| Script | Stack | Reverse Proxy | Best For |
|--------|-------|---------------|----------|
| `deploy-vps.sh` | Docker + NPM + Portainer + Fail2Ban | Nginx Proxy Manager | Visual container management + proxy |
| `deploy-dockge.sh` | Docker + NPM + Dockge + Fail2Ban | Nginx Proxy Manager | Compose stack management + proxy |
| `deploy-coolify.sh` | Docker + Coolify + Fail2Ban | Traefik (built-in) | PaaS / Heroku alternative |
| `deploy-dokploy.sh` | Docker + Dokploy + Fail2Ban | Traefik (built-in) | PaaS / Vercel alternative |
| `deploy-cosmos.sh` | Docker + Cosmos + Fail2Ban | Cosmos (built-in) | All-in-one homelab / server suite |

---

## Quick Start

```bash
# Download any script
curl -fsSL -o deploy.sh https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/deploy-dockge.sh
chmod +x deploy.sh
sudo ./deploy.sh
```

**Supported OS:** Ubuntu 20.04+, Debian 11+, Rocky/AlmaLinux 8/9, Fedora 35+, CentOS 7/8, Oracle Linux, Amazon Linux 2023

**Requirements:** Root access, internet connectivity, 2GB+ free disk space

---

## deploy-vps.sh — NPM + Portainer

The original full-stack deployment.

```bash
sudo ./deploy-vps.sh
```

| Service | Access | Notes |
|---------|--------|-------|
| NPM Admin | `http://VPS_IP:81` | Default: `admin@example.com` / `changeme` |
| Portainer | Via NPM proxy | Add proxy host → `http://portainer:9000` |

**Features:**
- Nginx Proxy Manager for reverse proxy + SSL (Let's Encrypt)
- Portainer CE for container management
- Custom fail2ban `npm-access` filter (catches bots scanning NPM's custom log format)
- 4 active jails: `sshd`, `npm-auth`, `npm-forceful-browsing`, `npm-botsearch`
- UFW with Docker-compatible `DEFAULT_FORWARD_POLICY=ACCEPT`

---

## deploy-dockge.sh — NPM + Dockge

Same as `deploy-vps.sh` but replaces Portainer with [Dockge](https://github.com/louislam/dockge) — a fancy, reactive, Compose stack manager.

```bash
sudo ./deploy-dockge.sh
```

| Service | Access | Notes |
|---------|--------|-------|
| NPM Admin | `http://VPS_IP:81` | Default: `admin@example.com` / `changeme` |
| Dockge | Direct: `http://VPS_IP:5001` | Or proxy via NPM → `http://dockge:5001` |

**Dockge features:**
- Edit `docker-compose.yml` files in a slick web UI
- Start/stop/restart stacks with one click
- Terminal integration for each stack
- Stacks stored as plain files in `/opt/stacks/`

**vs Portainer:** Dockge is simpler and file-based (Compose files live on disk, not in a DB). Portainer has more features like registry management, user teams, and RBAC.

---

## deploy-coolify.sh — Coolify PaaS

Deploys [Coolify](https://coolify.io) — an open-source, self-hostable Heroku/Netlify/Vercel alternative.

```bash
sudo ./deploy-coolify.sh
```

| Service | Access | Notes |
|---------|--------|-------|
| Coolify UI | `http://VPS_IP:8000` | First visitor becomes admin |

**Architecture:**
- Coolify manages its own Traefik reverse proxy (ports 80/443)
- Includes PostgreSQL and Redis for its database/queues
- No NPM — Coolify's Traefik handles SSL and proxying
- Fail2Ban simplified to `sshd` + `recidive` only

**Best for:** Deploying apps from Git with CI/CD, managing databases, running scheduled jobs.

---

## deploy-dokploy.sh — Dokploy PaaS

Deploys [Dokploy](https://dokploy.com) — an open-source alternative to Heroku, Vercel, and Netlify.

```bash
sudo ./deploy-dokploy.sh
```

| Service | Access | Notes |
|---------|--------|-------|
| Dokploy UI | `http://VPS_IP:3000` | First visitor becomes admin |
| Apps | `http://VPS_IP` / `https://VPS_IP` | Via Dokploy's built-in Traefik |

**Architecture:**
- Uses Docker Swarm (initialized by the installer)
- Built-in Traefik on ports 80/443
- Includes PostgreSQL and Redis
- No NPM — Dokploy's Traefik handles everything
- Fail2Ban simplified to `sshd` + `recidive`

**Best for:** Multi-server deployments, Docker Swarm orchestration, Git-based deployments.

---

## deploy-cosmos.sh — Cosmos Server

Deploys [Cosmos Server](https://github.com/azukaar/cosmos-server) — an all-in-one homelab/server management platform.

```bash
sudo ./deploy-cosmos.sh
```

| Service | Access | Notes |
|---------|--------|-------|
| Cosmos UI | `http://VPS_IP` / `https://VPS_IP` | Built-in reverse proxy |
| VPN | UDP port 4242 | Constellation VPN |

**Architecture:**
- Uses `network_mode: host` — binds directly to host ports 80/443
- **IS** the reverse proxy (no NPM, no Traefik needed)
- Includes MongoDB (auto-deployed), VPN server, URL forwarding
- Privileged container for full system integration
- Fail2Ban simplified to `sshd` + `recidive`

**Best for:** Homelab dashboard, container management, VPN access, serving as your main reverse proxy.

---

## Common Features (All Scripts)

| Feature | Status |
|---------|--------|
| Idempotent (safe to re-run) | ✅ |
| OS detection (Debian/RHEL families) | ✅ |
| Docker CE + Compose v2 plugin | ✅ |
| Fail2Ban with SSH protection | ✅ |
| UFW (Debian) / firewalld (RHEL) | ✅ |
| Docker + firewall compatibility fix | ✅ |
| Colored output with timestamps | ✅ |
| Deployment log at `/var/log/vps-deploy.log` | ✅ |
| Internet + disk space preflight checks | ✅ |
| Container health checks | ✅ |

---

## Post-Deployment Steps

### All Scripts

1. **Register admin account immediately** — First visitor to the web UI gets full admin access
2. **Set up SSH key auth** — Disable password auth after confirming keys work:
   ```bash
   sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
   sudo systemctl restart sshd
   ```

### NPM Scripts (deploy-vps.sh, deploy-dockge.sh)

1. **Open NPM Admin** at `http://VPS_IP:81`
2. **Change default password** immediately
3. **Add Proxy Hosts** for your services:
   - Domain: `portainer.yourdomain.com` → `http://portainer:9000`
   - Domain: `dockge.yourdomain.com` → `http://dockge:5001`
4. **Request SSL** via Let's Encrypt in the SSL tab
5. **Secure port 81** after domain setup:
   ```bash
   sudo ufw delete allow 81/tcp && sudo ufw reload
   ```

### Fail2Ban Verification

```bash
# Check all jails
sudo fail2ban-client status

# Check specific jail
sudo fail2ban-client status npm-forceful-browsing   # NPM scripts only

# Test filter against logs (NPM scripts)
sudo fail2ban-regex -v /opt/npm/data/logs/proxy-host-1_access.log /etc/fail2ban/filter.d/npm-access.conf
```

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `Permission denied to socket` | Use `sudo` for all `fail2ban-client` commands |
| Containers unreachable | Verify `DEFAULT_FORWARD_POLICY="ACCEPT"` in `/etc/default/ufw` |
| Port 80/443 conflict | Check `ss -tlnp \| grep ':80 '` — stop apache2/nginx if running |
| NPM UI not loading | `docker logs npm --tail 50` |
| Coolify/Dokploy timeout | Installer may take 3-5 min; check `docker ps` |
| Cosmos not responding | `docker logs cosmos-server --tail 50` |

---

## Security Notes

- **Port 81** (NPM admin) is exposed to the internet by default — restrict it via UFW after setting up a domain
- **Dockge port 5001** is exposed — proxy through NPM and restrict direct access
- **Coolify/Dokploy port 8000/3000** — these are admin UIs; consider restricting to VPN/SSH tunnel after setup
- All scripts configure Fail2Ban with automatic IP banning on brute-force attempts
- Scripts are idempotent — re-running wipes Docker data and starts fresh (dangerous on production systems!)

---

## File Layout

```
.
├── deploy-vps.sh       # Docker + NPM + Portainer + Fail2Ban
├── deploy-dockge.sh    # Docker + NPM + Dockge + Fail2Ban
├── deploy-coolify.sh   # Docker + Coolify + Fail2Ban
├── deploy-dokploy.sh   # Docker + Dokploy + Fail2Ban
├── deploy-cosmos.sh    # Docker + Cosmos + Fail2Ban
└── README.md           # This file
```

---

## License

MIT
