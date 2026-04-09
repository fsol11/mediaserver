# Cloudflare Tunnel Setup Guide

Cloudflare Tunnel (cloudflared) creates an **outbound-only** encrypted connection
from your server to Cloudflare's edge. No port forwarding or open firewall rules needed.

---

## Prerequisites

- A **Cloudflare account** (free tier works)
- A **domain** with its DNS managed by Cloudflare (nameservers pointing to Cloudflare)

---

## Step 1 — Create the Tunnel

1. Go to [Cloudflare Zero Trust](https://one.dash.cloudflare.com)
   - If prompted, create a Zero Trust organization (free plan is fine)
2. Navigate to **Networks → Tunnels → Create a tunnel**
3. Choose **Cloudflared** as the connector type
4. Name your tunnel (e.g., `mediaserver`) → **Save tunnel**
5. On the next screen, copy the **token** from the install command:
   ```
   cloudflared service install eyJhIjoiABC...
   ```
   The token is the long string after `service install`
6. Paste it into `install.env`:
   ```
   CLOUDFLARE_TUNNEL_TOKEN=eyJhIjoiABC...
   ```
7. Click **Next** — you'll configure hostnames in Step 3

---

## Step 2 — Start Cloudflared

```bash
cd /media/john/DATA/mediaserver
docker compose up -d cloudflared
```

Wait ~30 seconds, then check the tunnel is connected:

```bash
docker logs cloudflared
```

You should see: `Registered tunnel connection` in the output.

In the Zero Trust dashboard, the tunnel status should show **Healthy** (green dot).

---

## Step 3 — Configure Public Hostnames

In the Zero Trust dashboard → **Networks → Tunnels → your tunnel → Public Hostnames → Add a public hostname**.

Configure one entry per service you want exposed. Use the container names as the backend URL — they resolve on the internal Docker network.

### Recommended hostnames

| Subdomain | Domain | Backend URL | Notes |
|-----------|--------|-------------|-------|
| `jellyfin` | yourdomain.com | `http://jellyfin:8096` | Has its own login |
| `requests` | yourdomain.com | `http://jellyseerr:5055` | Has its own login |
| `books` | yourdomain.com | `http://audiobookshelf:80` | Has its own login |
| `home` | yourdomain.com | `http://homepage:3000` | Protect with Access (Step 4) |
| `status` | yourdomain.com | `http://uptime-kuma:3001` | Protect with Access (Step 4) |
| `radarr` | yourdomain.com | `http://radarr:7878` | Protect with Access (Step 4) |
| `sonarr` | yourdomain.com | `http://sonarr:8989` | Protect with Access (Step 4) |
| `prowlarr` | yourdomain.com | `http://prowlarr:9696` | Protect with Access (Step 4) |
| `qbit` | yourdomain.com | `http://qbittorrent:8080` | Protect with Access (Step 4) |
| `bazarr` | yourdomain.com | `http://bazarr:6767` | Protect with Access (Step 4) |

**Type** is always `HTTP` for all of these.

Cloudflare automatically provisions TLS certificates for every hostname — HTTPS is handled at the edge with no extra config.

---

## Step 4 — Protect Admin Services with Cloudflare Access

Services like Radarr, Sonarr, qBittorrent, Homepage, and Prowlarr should not be
open to the public internet. Cloudflare Access adds a login gate in front of them.

### Create an Access Policy

1. Go to **Access → Applications → Add an application**
2. Choose **Self-hosted**
3. Fill in:
   - **Application name**: `Media Admin`
   - **Session duration**: 24 hours (or your preference)
   - **Application domain**: Add one entry per admin service:
     ```
     home.yourdomain.com
     status.yourdomain.com
     radarr.yourdomain.com
     sonarr.yourdomain.com
     prowlarr.yourdomain.com
     qbit.yourdomain.com
     bazarr.yourdomain.com
     ```
4. Click **Next** → Add a policy:
   - **Policy name**: `Owner only`
   - **Action**: Allow
   - **Include rule**: `Emails` → your email address
5. Save the application

Now when you visit any of those subdomains, Cloudflare will send a one-time login
code to your email before showing the service.

---

## Step 5 — Jellyfin Extra Config (Reverse Proxy Headers)

Jellyfin needs to trust the forwarded headers from Cloudflare. In Jellyfin:

1. **Dashboard → Networking**
2. Set **Known proxies** to: `172.16.0.0/12` (covers all Docker bridge networks)
3. Enable **Allow remote connections to this server**
4. Save and restart Jellyfin

---

## Step 6 — Verify Everything

Test each public hostname in your browser:

```
https://jellyfin.yourdomain.com     ← should show Jellyfin login
https://requests.yourdomain.com     ← should show Jellyseerr
https://books.yourdomain.com        ← should show Audiobookshelf
https://home.yourdomain.com         ← should prompt Cloudflare Access email
https://radarr.yourdomain.com       ← should prompt Cloudflare Access email
```

---

## Architecture Overview

```
Internet → Cloudflare Edge (TLS) → Cloudflare Tunnel → cloudflared container
                                                              ↓
                                                   Docker mediaserver network
                                                   ┌──────────────────────┐
                                                   │ jellyfin:8096        │
                                                   │ jellyseerr:5055      │
                                                   │ audiobookshelf:80    │
                                                   │ homepage:3000        │
                                                   │ uptime-kuma:3001     │
                                                   │ radarr:7878          │
                                                   │ sonarr:8989          │
                                                   │ prowlarr:9696        │
                                                   │ qbittorrent:8080     │
                                                   │ bazarr:6767          │
                                                   └──────────────────────┘
```

No ports are exposed on your router. All traffic flows outbound through the tunnel.

---

## Troubleshooting

**Tunnel shows Unhealthy / not connected**
```bash
docker logs cloudflared --tail 50
```
Verify the token in `install.env` is correct and complete.

**502 Bad Gateway on a hostname**
- Check the backend URL in the Zero Trust dashboard matches the container name exactly
- Verify the target container is running: `docker compose ps`

**Jellyfin streams are slow or buffering**
- Cloudflare free plan has no bandwidth limit for tunnels, but video streaming
  may be against Cloudflare ToS on some plans. Consider using a paid plan or
  exposing Jellyfin on a dedicated port if streaming large files.

**Cloudflare Access loop (keeps asking for email)**
- Clear cookies for `yourdomain.cloudflareaccess.com`
- Make sure the email you enter matches the one in your Access policy exactly
