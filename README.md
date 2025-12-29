# Raspberry Pi 44Net Secure Portal
### Traefik + Authelia + Node-RED Gateway (with Optional LAN Lockdown)

This project builds a **secure web portal** on a Raspberry Pi that’s reachable from the 44Net / public internet.  
It uses **Traefik** for reverse-proxy and automatic TLS via Let’s Encrypt, and **Authelia** to enforce login before forwarding traffic to a private backend (like a Node-RED dashboard on `192.168.x.x`). It allows you to have users access your ham radio network or remote station web resources without needing a VPN.  This application is good for large clubs or anyone who does not want to deal with the free account limitations of commercial VPN products.

---

## Warning

Just a reminder, since this portal sits out on the open internet, use best practices of segmenting your network, hardening your Rpi with SSH key login only, closing all ports except 22, 80 and 443, and installing fail2ban. Make sure to always use strong portal passwords as well.

---

## Architecture

```ascii
                 ┌─────────────────────────────┐ 
                 │        Internet / 44Net     │
                 └──────────────┬──────────────┘
                                │
                                ▼
                     ┌────────────────────┐
                     │      Traefik       │
                     │  (HTTPS + ACME LE) │
                     └───────┬────────────┘
                             │
        ┌────────────────────┴────────────────────┐
        │                                         │
┌──────────────────────┐              ┌──────────────────────────┐
│   Authelia Login     │              │   Backend (Node-RED,     │
│ auth.yourdomain.com  │              │   Grafana, etc.)         │
└──────────────────────┘              └──────────────────────────┘
```

- **Traefik** terminates HTTPS, requests certificates automatically from Let’s Encrypt, and forwards requests.
- **Authelia** provides authentication and authorization (`https://auth.yourdomain.com`).
- **Backend** is your internal service (e.g., `http://192.168.50.100:1880`) only reachable after login.

---

## Features

- Fully automated install on Raspberry Pi OS (Debian Bookworm / Trixie).  
- Docker-based (Traefik v2.11 + Authelia v4).  
- Automatic Let’s Encrypt certificates.  
- Secure login with bcrypt-hashed credentials.  
- Persistent configuration under `/opt/portal-docker`.  
- Optional Authelia bad login banning  
- Single command setup script.

---

## Installation

1. **SSH into your Raspberry Pi** that has a 44Net or public IPv4 address. To setup 44Net Cloud over Wireguard see: [https://https://github.com/n3bkv/44net-cloud-wireguard-rpi](https://https://github.com/n3bkv/44net-cloud-wireguard-rpi)  
2. **Download the setup script:**

   ```bash
   curl -fsSL https://raw.githubusercontent.com/n3bkv/44Net-Secure-Portal/main/setup-portal-docker.sh -o setup-portal-docker.sh
   chmod +x setup-portal-docker.sh
   ```

3. **Run as root (or with sudo):**

   ```bash
   sudo ./setup-portal-docker.sh
   ```

4. **Enter prompts:**
   - `Portal domain`: e.g. `portal.example.com`
   - `Auth domain [auth.example.com] `: e.g. `auth.example.com` - default indicated 
   - `Let's Encrypt contact email`: for Let’s Encrypt notifications
   - `Internal server/port URL (e.g. Node-RED)`: e.g. `http://192.168.1.100:1880`
   - `Timezone [America/Los_Angeles]:` - default indicated 
   - `Initial Authelia username [admin]` - default indicated 
   - `Initial Authelia password`
   - `Initial Authelia email`
   - `Wipe existing /opt/portal-docker and containers first? [y/N]:` - default indicated
   - `Enable Authelia login lockout control (regulation)? [Y/n]:`- default indicated
   - `Max retries before lockout [5]:` - default indicated
   - `Find time window (e.g., 2m, 10m, 1h, 6h) [10m]:` - default indicated
   - `Ban time duration (e.g., 5m, 1h, 1d, 1w) [1h]:` - default indicated
   

   The script will:
   - Install Docker, if needed  
   - Generate secrets and a bcrypt password hash  
   - Create all Docker config files under `/opt/portal-docker`  
   - Validate Authelia’s config  
   - Launch Traefik + Authelia containers
   - Install lockdown for too many bad authenication attemps
   
   **Requirements:**
  - Raspberry Pi
  - Internet routable IP (e.g. 44Net)
  - Top level domain (tld e.g. yourcall.org)
  - Opening of ports 80/443 and DNS A records that resolve to your Pi’s public/44Net IP.
  - Access to DNS to create A records for both portal.yourdomain and auth.yourdomain → your server’s IP

---

## Directory Layout

```
/opt/portal-docker/
├── docker-compose.yml
├── traefik/
│   ├── traefik.yml             # Static Traefik config (entrypoints, resolver)
│   ├── dynamic.yml             # Routers, middlewares, backend
│   └── letsencrypt/acme.json   # Certificates (0600)
└── authelia/
    ├── configuration.yml       # Authelia main configuration
    ├── users_database.yml      # Local user DB (bcrypt hashes)
    └── db.sqlite3              # Authelia storage (created on first run)
```

---

## Default Network

Docker creates an isolated bridge network:

```
portal_proxy
├── traefik
└── authelia
```

Your internal service (e.g. Node-RED) stays on the LAN (`192.168.x.x`).

---

## Post-Install Tips

- **Access your portal:**  
  `https://portal.yourdomain.com` → redirects to login at `https://auth.yourdomain.com`.

- **Logs:**  
  ```bash
  sudo docker logs -f portal-docker-traefik-1
  sudo docker logs -f portal-docker-authelia-1
  ```

- **Renewal:**  
  Let’s Encrypt certificates are automatically renewed by Traefik.  
  You can add a weekly cron check if desired:
  ```bash
  @weekly docker exec portal-docker-traefik-1 traefik renew
  ```

- **Adding users:**  
  ***Be careful to make sure your formatting is correct in this file as you add users and make sure not to duplicate passwords or the authentication page will break***
  Edit `/opt/portal-docker/authelia/users_database.yml`, hash a new password:
  ```bash
  docker run --rm authelia/authelia:latest authelia crypto hash generate bcrypt --password 'newpass'
  ```
  Sample '`users_database.yml` file - notice the indentations for users and their associated information.
```bash
users:
  admin:
    displayname: "admin"
    password: "hashed password in quotes"
    email: "email@example.com"
    groups:
      - admins
      - users

  user1:
    displayname: "User1"
    password: "hashed password in quotes"
    email: "email@example.com"
    groups:
      - admins
      - users

  user2:
    displayname: "User2"
    password: "hashed password in quotes"
    email: "email@example.com"
    groups:
       - admins
       - users

  user3:
    displayname: "User3"
    password: "hashed password in quotes"
    email: "email@example.com"
    groups:
       - admins
       - users
  ```
  Then restart Authelia:
  ```bash
  docker compose -f /opt/portal-docker/docker-compose.yml restart authelia
  ```

---

## Maintenance

| Command | Purpose |
|----------|----------|
| `sudo docker compose -f /opt/portal-docker/docker-compose.yml ps` | View running containers |
| `sudo docker compose -f /opt/portal-docker/docker-compose.yml down` | Stop stack |
| `sudo docker compose -f /opt/portal-docker/docker-compose.yml up -d` | Restart stack |
| `sudo docker network ls` | List Docker networks |
| `sudo docker system prune -af` | Clean up unused images/containers |

---

##  Troubleshooting

- **Error `nonexistent resolver: le`**  
  ⇒ means the `certificatesResolvers.le` block was missing in `traefik.yml`. This script fixes that automatically.

- **Error `read-only file system` for users_database.yml**  
  ⇒ Authelia mount is now RW (no `:ro`), fixed in this refactor.

- **401 Unauthorized**  
  ⇒ check `forwardAuth` line includes `?rd=https://auth.yourdomain.com/`.

- **TLS/ACME not issuing certs**  
  ⇒ ensure ports 80/443 are open and DNS A records resolve to your Pi’s public/44Net IP. 
   You can test (on another machine not on the network:  
     ```bash
     curl -I http://portal.yourdomain.com
     ```
  ⇒ Acme will rate throttle you if you request too many certificates in an hour (>5). 
To see any certificate errors run this:  
     ```bash
     docker compose logs -f traefik | egrep -i 'acme|certificate|challenge|letsencrypt|error'
     ```
- **How do I fix a locked out user?**
  
  ⇒ To check if a user is on the lockout list:  
     ```bash
     docker exec -it portal-docker-authelia-1 sh
     authelia storage bans user list
     ```
  ⇒ Then to fix a locked out user, follow the step below:  
     ```bash
     authelia storage bans user revoke <username>
     ```
---

## Fixing Authelia NTP Startup Errors (Important)

Authelia performs its own internal NTP (Network Time Protocol) check at startup.  
This check is **separate from the system clock** (`timedatectl`), and Authelia will fail if:

- The NTP server is unreachable  
- UDP/123 is blocked  
- Docker drops a packet  
- There is jitter or latency during startup  

Common Authelia log errors include:

fatal failures performing startup checks provider=ntp
could not determine the clock offset
i/o timeout

To prevent Authelia from failing on harmless NTP timeouts, the installer now automatically writes this block into `authelia/configuration.yml`:

```yaml
ntp:
  address: "udp://time.cloudflare.com:123"
  version: 4
  max_desync: 10s
  disable_startup_check: false
  disable_failure: true
```

Why this works

Cloudflare’s NTP servers are extremely reliable.

Increasing max_desync reduces false positives.

Authelia still performs NTP checks, but won’t crash if a packet is lost.

Eliminates the “NTP provider fatal error” loop on Raspberry Pi / Docker setups.

Firewall requirement

If you use nftables-firewall-builder, make sure outbound NTP is allowed:

```udp dport 123 accept```

The updated firewall script can prompt for this automatically.
   
---

##  Limitations/Workarounds

***You cannot have the portal redirect to append paths automatically in your setup (e.g. http://192.168.xx.xxx:1880/ui) - the workaround is to append the /ui to you portal login URL (e.g. portal.example.com/ui).***

---

## License

MIT License © 2025 Dave (N3BKV)

---

## Support This Project

If you find this useful, star ⭐ the repo! It helps others discover it.

---

## Resources & Badges

[![Docker](https://img.shields.io/badge/Docker-Ready-blue?logo=docker)](https://www.docker.com/)  
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)  
[![Platform](https://img.shields.io/badge/Platform-RaspberryPi-red)](https://www.raspberrypi.com/)  

###  More Info
- Blog: [https://hamradiohacks.blogspot.com](https://hamradiohacks.blogspot.com)  
- GitHub: [https://github.com/n3bkv](https://github.com/n3bkv)
