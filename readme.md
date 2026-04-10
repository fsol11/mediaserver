# Media Server

A fully automated, self-hosted media server stack that deploys 14 Docker containers and wires them all together with a single command. It handles downloading, organizing, streaming, and subtitling movies, TV shows, and audiobooks — no manual configuration needed.

**Services included:** qBittorrent, Prowlarr, FlareSolverr, Radarr, Sonarr, Jellyfin, Jellyseerr, Bazarr, Recyclarr, Unpackerr, Homepage, Uptime Kuma, Audiobookshelf, and Cloudflared (optional tunnel).

---

## Setup

### 1. Clone the repository

```bash
git clone <repo-url> mediaserver
cd mediaserver
```

### 2. Edit the configuration

On first run, `install.sh` generates a `.env` file from the `.env.initial` template. You can also create it ahead of time:

```bash
cp .env.initial .env
```

Open `.env` and set:

- **`QBIT_USERNAME` / `QBIT_PASSWORD`** — qBittorrent login credentials
- **`JELLYFIN_ADMIN_USER` / `JELLYFIN_ADMIN_PASSWORD`** — Jellyfin admin account
- **`DATA_ROOT`** — root path to your media storage drive
- **`DIR_DOWNLOADS` / `DIR_MOVIES` / `DIR_TV` / `DIR_AUDIOBOOKS`** — media folder paths
- **`CLOUDFLARE_TUNNEL_TOKEN`** — *(optional)* for remote access via Cloudflare Tunnel
- **`PROWLARR_INDEXERS`** — comma-separated list of public indexers to add automatically

API keys are populated automatically — do not edit them manually.

### 3. Run the installer

```bash
bash install.sh
```

This single command does everything:

| Step | What happens |
| --- | --- |
| Prerequisites | Installs curl, Docker Engine, and Docker Compose if missing |
| System setup | Creates media directories, enables Docker on boot |
| Containers | Pulls images, starts all 14 services |
| API keys | Extracts keys from each service's config |
| Jellyfin | Completes setup wizard, creates admin account, adds media libraries (Movies, TV Shows, Audiobooks), configures FFmpeg |
| Jellyseerr | Links to Jellyfin, initializes settings, creates API key |
| Radarr | Adds qBittorrent as download client, sets root folder |
| Sonarr | Adds qBittorrent as download client, sets root folder |
| Prowlarr | Registers Radarr + Sonarr, adds FlareSolverr proxy, creates public indexers |
| Bazarr | Connects to Radarr + Sonarr for subtitle management |
| Jellyseerr | Adds Radarr + Sonarr with quality profiles |
| Recyclarr | Syncs TRaSH quality profiles |
| Homepage | Restarts with all API keys wired into dashboard widgets |

### What still needs manual setup

These items require your personal preferences or third-party accounts:

- **Bazarr** → Settings → Subtitles → add subtitle providers (e.g., OpenSubtitles)
- **Uptime Kuma** → Create admin account, add monitors for each service
- **Audiobookshelf** → Create admin account on first visit

---

## Re-running / Updating

Both scripts are **idempotent** — safe to run again at any time:

```bash
bash install.sh
```

When re-run, `install.sh`:

- **Pulls the latest container images** and recreates any containers that have newer versions
- **Re-reads `.env`** and applies all settings — if you change credentials, media paths, or the indexer list, the new values take effect
- **Skips completed steps** — the Jellyfin wizard, library creation, and other one-time setup are not repeated if already done
- **Re-wires all service connections** via `configure.sh` to ensure everything stays in sync

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

See [CLOUDFLARE_SETUP.md](CLOUDFLARE_SETUP.md) to expose services over the internet
via Cloudflare Tunnel (no port forwarding needed).
