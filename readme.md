# Setup Guide

## Full Automated Setup (recommended)

Run a single script — it handles everything:

```bash
bash install.sh
```

It will ask for three things upfront, then run for ~5 minutes without interruption:

1. **Timezone** — e.g., `America/New_York`
2. **qBittorrent password** — new password to replace the default
3. **Jellyfin admin credentials** — username + password for the media server admin account

### What the script automates

| Step | What happens |
| --- | --- |
| System | Creates directories, enables Docker on boot |
| Containers | Pulls images, starts all 13 services |
| API keys | Reads keys from each service's config file |
| Jellyfin | Completes setup wizard, creates libraries, creates API key |
| Jellyseerr | Links to Jellyfin account, initializes wizard |
| Radarr | Adds qBittorrent as download client, sets `/movies` root folder |
| Sonarr | Adds qBittorrent as download client, sets `/tv` root folder |
| Prowlarr | Registers Radarr + Sonarr apps, triggers indexer sync |
| Bazarr | Connects to Radarr + Sonarr |
| Jellyseerr | Adds Radarr + Sonarr with quality profiles |
| Recyclarr | Triggers initial TRaSH quality-profile sync |
| Homepage | Restarted with all API keys wired into widgets |

### What still needs manual setup

These four items cannot be automated — they require your personal preferences or
accounts on third-party services:

- **Prowlarr** → Add your torrent indexers (private trackers, public indexers)
- **Bazarr** → Settings → Subtitles → add subtitle providers (e.g., OpenSubtitles)
- **Uptime Kuma** → Create admin account, add monitors for each service
- **Audiobookshelf** → Create admin account on first visit

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

---

## Re-running Individual Steps

Each script is idempotent — safe to run multiple times:

```bash
bash get-api-keys.sh        # re-extract API keys only
bash configure.sh           # re-wire services only (after keys are set)
bash install.sh             # full re-run (skips already-done steps)
```

---

## Cloudflare Remote Access

See [CLOUDFLARE_SETUP.md](CLOUDFLARE_SETUP.md) to expose services over the internet
via Cloudflare Tunnel (no port forwarding needed).
