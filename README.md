# Media Server

A fully automated, self-hosted media server stack that deploys 14 Docker containers and wires them all together with a single command. It handles downloading, organizing, streaming, and subtitling movies, TV shows, and audiobooks — no manual configuration needed.

| Container        | Role                                            |
|------------------|-------------------------------------------------|
| **Jellyfin**     | Media streaming server                          |
| **Jellyseerr**   | Media request & discovery UI                    |
| **Radarr**       | Movie management & automation                   |
| **Sonarr**       | TV show management & automation                 |
| **Bazarr**       | Subtitle management                             |
| **Prowlarr**     | Indexer manager for Radarr & Sonarr              |
| **FlareSolverr** | Bypass Cloudflare protection for indexers        |
| **qBittorrent**  | Torrent download client                         |
| **Recyclarr**    | TRaSH quality profile sync                      |
| **Unpackerr**    | Auto-extracts downloaded archives               |
| **Homepage**     | Dashboard with service widgets                  |
| **Uptime Kuma**  | Service uptime monitoring                       |
| **Audiobookshelf** | Audiobook & podcast server                    |
| **Cloudflared**  | Cloudflare Tunnel for remote access (optional)  |

---

## Setup

### 1\. Clone the repository

```bash
git clone <repo-url> mediaserver
cd mediaserver
```

### 2\. Edit the configuration

On first run, `install.sh` generates a `.env` file from the `.env.initial` template. You can also create it ahead of time:

```bash
cp .env.initial .env
```

Open `.env` and set:

-   **`QBIT_USERNAME` / `QBIT_PASSWORD`** — qBittorrent login credentials
-   **`JELLYFIN_ADMIN_USER` / `JELLYFIN_ADMIN_PASSWORD`** — Jellyfin admin account
-   **`DATA_ROOT`** — root path to your media storage drive
-   **`DIR_DOWNLOADS` / `DIR_MOVIES` / `DIR_TV` / `DIR_AUDIOBOOKS`** — media folder paths
-   **`CLOUDFLARE_TUNNEL_TOKEN`** — *(optional)* for remote access via Cloudflare Tunnel
-   **`BAZARR_PROVIDERS`** — comma-separated subtitle providers (see Bazarr UI → Settings → Providers for names)
-   **`PROWLARR_INDEXERS`** — comma-separated public indexers (see Prowlarr UI → Indexers → Add Indexer for names)

API keys are populated automatically — do not edit them manually.

### 3\. Run the installer

```bash
bash install.sh
```

This single command does everything.

### What still needs manual setup

These items require your personal preferences or third-party accounts:

-   **Uptime Kuma** → Create admin account, add monitors for each service
-   **Audiobookshelf** → Create admin account on first visit

---

## Re-running / Updating

Both scripts are **idempotent** — safe to run again at any time:

```bash
bash install.sh
```

When re-run, `install.sh`:

-   **Pulls the latest container images** and recreates any containers that have newer versions
-   **Re-reads `.env`** and applies all settings — if you change credentials, media paths, the indexer list, or subtitle providers, the new values take effect
-   **Skips completed steps** — the Jellyfin wizard, library creation, and other one-time setup are not repeated if already done
-   **Re-wires all service connections** via `configure.sh` to ensure everything stays in sync

You can also run individual parts:

```bash
bash get-api-keys.sh   # re-extract API keys only
bash configure.sh      # re-wire service connections only
```

---

## Service URLs

| Service        | URL                            |
|----------------|--------------------------------|
| Homepage       | <http://localhost:3000>        |
| Jellyfin       | <http://localhost:8096>        |
| Jellyseerr     | <http://localhost:5055>        |
| Radarr         | <http://localhost:7878>        |
| Sonarr         | <http://localhost:8989>        |
| Prowlarr       | <http://localhost:9696>        |
| qBittorrent    | <http://localhost:8080>        |
| Bazarr         | <http://localhost:6767>        |
| Audiobookshelf | <http://localhost:13378>       |
| Uptime Kuma    | <http://localhost:3001>        |
| FlareSolverr   | <http://localhost:8191>        |

---

## Cloudflare Remote Access

See [CLOUDFLARE\_SETUP.md](CLOUDFLARE_SETUP.md) to expose services over the internet  
via Cloudflare Tunnel (no port forwarding needed).