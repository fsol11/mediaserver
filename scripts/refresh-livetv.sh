#!/usr/bin/env bash
# ============================================================
# refresh-livetv.sh — curated Live TV playlist for Jellyfin
#
# Free IPTV playlists are full of dead and geo-blocked streams.
# This script fetches the source playlists, probes every stream
# with Jellyfin's own ffmpeg (so "working" means "Jellyfin can
# play it"), and writes only the live channels to
#   config/jellyfin/livetv-canada.m3u
# which Jellyfin reads as an M3U tuner at /config/livetv-canada.m3u.
# It then makes sure that tuner exists and refreshes the guide.
#
# Run manually any time, or via cron (install.sh sets up a daily
# run at 04:30). Takes a few minutes — streams are probed live.
# ============================================================
set -uo pipefail
STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$STACK_DIR/.env"
OUT_FILE="$STACK_DIR/config/jellyfin/livetv-canada.m3u"
TUNER_PATH="/config/livetv-canada.m3u"   # OUT_FILE as seen inside the container

# Source playlists to merge and filter (add more URLs here if wanted)
SOURCES=(
    "https://raw.githubusercontent.com/Free-TV/IPTV/master/playlists/playlist_canada.m3u8"
    "https://iptv-org.github.io/iptv/countries/ca.m3u"
)

docker ps --format '{{.Names}}' | grep -q '^jellyfin$' || { echo "jellyfin container not running"; exit 1; }

echo "Probing streams from ${#SOURCES[@]} source playlists..."
SOURCES_CSV=$(IFS=,; echo "${SOURCES[*]}")
python3 - "$SOURCES_CSV" "$OUT_FILE" <<'PYEOF'
import subprocess, sys, urllib.request
from concurrent.futures import ThreadPoolExecutor

sources, out_file = sys.argv[1].split(","), sys.argv[2]
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"

channels, seen = [], set()
for src in sources:
    try:
        text = urllib.request.urlopen(src, timeout=30).read().decode()
    except Exception as e:
        print(f"  WARN: could not fetch {src}: {e}")
        continue
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if line.startswith("#EXTINF") and i + 1 < len(lines) and lines[i + 1].startswith("http"):
            url = lines[i + 1].strip()
            if url not in seen and "[Geo-blocked]" not in line:
                seen.add(url)
                channels.append((line, url))
print(f"  {len(channels)} unique channels to probe")

def probe(ch):
    extinf, url = ch
    cmd = ["docker", "exec", "jellyfin", "timeout", "20",
           "/usr/lib/jellyfin-ffmpeg/ffprobe", "-v", "error",
           "-user_agent", UA, "-select_streams", "v",
           "-show_entries", "stream=codec_name", "-of", "csv=p=0", url]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        return ch if r.returncode == 0 and r.stdout.strip() else None
    except Exception:
        return None

with ThreadPoolExecutor(max_workers=12) as ex:
    working = [c for c in ex.map(probe, channels) if c]

working.sort(key=lambda c: c[0].split(",")[-1].lower())
with open(out_file, "w") as f:
    f.write("#EXTM3U\n")
    for extinf, url in working:
        f.write(f"{extinf}\n{url}\n")
print(f"  {len(working)} working channels written to {out_file}")
PYEOF

# ── Ensure the Jellyfin tuner exists and refresh the guide ──
JF_KEY=$(grep -m1 '^JELLYFIN_API_KEY=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)
[[ -z "$JF_KEY" ]] && { echo "JELLYFIN_API_KEY not set — skipping tuner setup"; exit 0; }
AUTH="Authorization: MediaBrowser Token=\"$JF_KEY\""
JF="http://localhost:8096"

if ! curl -s "$JF/System/Configuration/livetv" -H "$AUTH" | grep -q "$TUNER_PATH"; then
    curl -s -o /dev/null -X POST "$JF/LiveTv/TunerHosts" -H "$AUTH" \
        -H 'Content-Type: application/json' -d "{
        \"Url\": \"$TUNER_PATH\", \"Type\": \"m3u\",
        \"ImportFavoritesOnly\": false, \"AllowHWTranscoding\": false,
        \"AllowFmp4TranscodingContainer\": false, \"AllowStreamSharing\": true,
        \"FallbackMaxStreamingBitrate\": 30000000, \"EnableStreamLooping\": false,
        \"TunerCount\": 0, \"IgnoreDts\": true, \"ReadAtNativeFramerate\": true}"
    echo "Tuner added for $TUNER_PATH"
fi

TASK=$(curl -s "$JF/ScheduledTasks" -H "$AUTH" | python3 -c \
    "import json,sys; print(next(t['Id'] for t in json.load(sys.stdin) if t.get('Key')=='RefreshGuide'))" 2>/dev/null)
[[ -n "$TASK" ]] && curl -s -o /dev/null -X POST "$JF/ScheduledTasks/Running/$TASK" -H "$AUTH" \
    && echo "Guide refresh triggered"
