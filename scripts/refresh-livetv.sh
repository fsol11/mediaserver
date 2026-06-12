#!/usr/bin/env bash
# ============================================================
# refresh-livetv.sh — curated Live TV playlist + EPG for Jellyfin
#
# Free IPTV playlists are full of dead and geo-blocked streams.
# This script:
#   1. Fetches the source playlists and probes every stream with
#      Jellyfin's own ffmpeg (so "working" = "Jellyfin can play it")
#   2. Matches working channels by name against the free epgshare01
#      XMLTV guides and rewrites their tvg-id to the guide's id
#   3. Writes the channels to  config/jellyfin/livetv-canada.m3u
#      and a merged, filtered guide to config/jellyfin/livetv-epg.xml.gz
#      (Jellyfin reads both as local files under /config/)
#   4. Ensures the Jellyfin tuner + XMLTV listing provider exist
#      and refreshes the guide
#
# Run manually any time, or via cron (install.sh sets up a daily
# run at 04:30). Takes a few minutes — streams are probed live.
# ============================================================
set -uo pipefail
STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$STACK_DIR/.env"
OUT_M3U="$STACK_DIR/config/jellyfin/livetv-canada.m3u"
OUT_EPG="$STACK_DIR/config/jellyfin/livetv-epg.xml.gz"
TUNER_PATH="/config/livetv-canada.m3u"    # OUT_M3U as seen inside the container
EPG_PATH="/config/livetv-epg.xml.gz"      # OUT_EPG as seen inside the container

# Source playlists to merge and filter (add more URLs here if wanted)
SOURCES=(
    "https://raw.githubusercontent.com/Free-TV/IPTV/master/playlists/playlist_canada.m3u8"
    "https://iptv-org.github.io/iptv/countries/ca.m3u"
)
# epgshare01.online XMLTV guides to match channels against, in priority order
EPG_SOURCES=(
    "https://epgshare01.online/epgshare01/epg_ripper_CA2.xml.gz"
    "https://epgshare01.online/epgshare01/epg_ripper_US2.xml.gz"
    "https://epgshare01.online/epgshare01/epg_ripper_PLEX1.xml.gz"
    "https://epgshare01.online/epgshare01/epg_ripper_DISTROTV1.xml.gz"
)

docker ps --format '{{.Names}}' | grep -q '^jellyfin$' || { echo "jellyfin container not running"; exit 1; }

SOURCES_CSV=$(IFS=,; echo "${SOURCES[*]}")
EPG_CSV=$(IFS=,; echo "${EPG_SOURCES[*]}")
python3 - "$SOURCES_CSV" "$EPG_CSV" "$OUT_M3U" "$OUT_EPG" <<'PYEOF'
import gzip, re, subprocess, sys, urllib.request
from concurrent.futures import ThreadPoolExecutor

sources, epg_sources = sys.argv[1].split(","), sys.argv[2].split(",")
out_m3u, out_epg = sys.argv[3], sys.argv[4]
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"

def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    return urllib.request.urlopen(req, timeout=120).read()

# ── 1. Collect channels from source playlists ───────────────
channels, seen = [], set()
for src in sources:
    try:
        lines = fetch(src).decode().splitlines()
    except Exception as e:
        print(f"  WARN: could not fetch {src}: {e}")
        continue
    for i, line in enumerate(lines):
        if line.startswith("#EXTINF") and i + 1 < len(lines) and lines[i + 1].startswith("http"):
            url = lines[i + 1].strip()
            if url not in seen and "[Geo-blocked]" not in line:
                seen.add(url)
                channels.append((line, url))
print(f"Probing {len(channels)} unique channels...")

# ── 2. Probe every stream with Jellyfin's ffmpeg ────────────
def probe(ch):
    cmd = ["docker", "exec", "jellyfin", "timeout", "20",
           "/usr/lib/jellyfin-ffmpeg/ffprobe", "-v", "error",
           "-user_agent", UA, "-select_streams", "v",
           "-show_entries", "stream=codec_name", "-of", "csv=p=0", ch[1]]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        return ch if r.returncode == 0 and r.stdout.strip() else None
    except Exception:
        return None

with ThreadPoolExecutor(max_workers=12) as ex:
    working = [c for c in ex.map(probe, channels) if c]
print(f"  {len(working)} working channels")

# ── 3. Match channels against the EPG guides by name ────────
def norm(s):
    s = re.sub(r'\((720p|1080p|480p|540p|360p|576p|240p|4k)\)|\[.*?\]', '', s, flags=re.I)
    return re.sub(r'[^a-z0-9]', '', s.lower().replace('&', 'and'))
def slim(s):
    return re.sub(r'(tv|hd|channel|network|canada)$', '', s)

matched = {}            # channel index -> epg id
epg_out = []            # filtered <channel> + <programme> xml blocks
pending = {i: (norm(extinf.split(",")[-1])) for i, (extinf, _) in enumerate(working)}

for url in epg_sources:
    if not pending:
        break
    try:
        text = gzip.decompress(fetch(url)).decode(errors="replace")
    except Exception as e:
        print(f"  WARN: could not fetch {url}: {e}")
        continue
    split = text.find("<programme")
    head = text[:split] if split != -1 else text
    name_to_id, ids_here = {}, {}
    for cid, dname in re.findall(r'<channel id="([^"]+)">.*?<display-name[^>]*>([^<]+)</display-name>', head, re.S):
        key = norm(dname)
        if key and key not in name_to_id:
            name_to_id[key] = cid
    slim_map = {}
    for k, v in name_to_id.items():
        slim_map.setdefault(slim(k), v)
    hit_ids = set()
    for i, key in list(pending.items()):
        cid = name_to_id.get(key) or slim_map.get(slim(key))
        if cid:
            matched[i] = cid
            hit_ids.add(cid)
            del pending[i]
    if hit_ids:
        pat = "|".join(re.escape(c) for c in hit_ids)
        epg_out += re.findall(rf'<channel id="(?:{pat})">.*?</channel>', head, re.S)
        epg_out += re.findall(rf'<programme [^>]*channel="(?:{pat})".*?</programme>', text[split:] if split != -1 else "", re.S)
print(f"  {len(matched)} channels matched to guide data")

# ── 4. Write playlist (tvg-id rewritten to guide ids) ───────
out = []
for i, (extinf, url) in enumerate(working):
    if i in matched:
        cid = matched[i]
        if 'tvg-id="' in extinf:
            extinf = re.sub(r'tvg-id="[^"]*"', f'tvg-id="{cid}"', extinf)
        else:
            extinf = extinf.replace("#EXTINF:-1", f'#EXTINF:-1 tvg-id="{cid}"', 1)
    out.append((extinf, url))
out.sort(key=lambda c: c[0].split(",")[-1].lower())
with open(out_m3u, "w") as f:
    f.write("#EXTM3U\n")
    for extinf, url in out:
        f.write(f"{extinf}\n{url}\n")
print(f"  playlist written to {out_m3u}")

# ── 5. Write merged, filtered guide ─────────────────────────
xml = ('<?xml version="1.0" encoding="utf-8"?>\n<tv generator-info-name="refresh-livetv.sh">\n'
       + "\n".join(epg_out) + "\n</tv>\n")
with gzip.open(out_epg, "wt") as f:
    f.write(xml)
print(f"  guide written to {out_epg}")
PYEOF

# ── Ensure the Jellyfin tuner + guide exist, refresh guide ──
JF_KEY=$(grep -m1 '^JELLYFIN_API_KEY=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)
[[ -z "$JF_KEY" ]] && { echo "JELLYFIN_API_KEY not set — skipping tuner setup"; exit 0; }
AUTH="Authorization: MediaBrowser Token=\"$JF_KEY\""
JF="http://localhost:8096"
LIVETV_CONF=$(curl -s "$JF/System/Configuration/livetv" -H "$AUTH")

if ! echo "$LIVETV_CONF" | grep -q "$TUNER_PATH"; then
    curl -s -o /dev/null -X POST "$JF/LiveTv/TunerHosts" -H "$AUTH" \
        -H 'Content-Type: application/json' -d "{
        \"Url\": \"$TUNER_PATH\", \"Type\": \"m3u\",
        \"ImportFavoritesOnly\": false, \"AllowHWTranscoding\": false,
        \"AllowFmp4TranscodingContainer\": false, \"AllowStreamSharing\": true,
        \"FallbackMaxStreamingBitrate\": 30000000, \"EnableStreamLooping\": false,
        \"TunerCount\": 0, \"IgnoreDts\": true, \"ReadAtNativeFramerate\": true}"
    echo "Tuner added for $TUNER_PATH"
fi

if ! echo "$LIVETV_CONF" | grep -q "$EPG_PATH"; then
    curl -s -o /dev/null -X POST "$JF/LiveTv/ListingProviders" -H "$AUTH" \
        -H 'Content-Type: application/json' -d "{
        \"Type\": \"xmltv\", \"Path\": \"$EPG_PATH\", \"EnableAllTuners\": true}"
    echo "XMLTV listing provider added for $EPG_PATH"
fi

TASK=$(curl -s "$JF/ScheduledTasks" -H "$AUTH" | python3 -c \
    "import json,sys; print(next(t['Id'] for t in json.load(sys.stdin) if t.get('Key')=='RefreshGuide'))" 2>/dev/null)
[[ -n "$TASK" ]] && curl -s -o /dev/null -X POST "$JF/ScheduledTasks/Running/$TASK" -H "$AUTH" \
    && echo "Guide refresh triggered"
