#!/usr/bin/env bash
# ============================================================
# configure.sh — Wire all services together via REST APIs
#
# Requires all API keys to be populated in .env
# (run get-api-keys.sh first, or let install.sh call this)
#
# Idempotent: checks before creating, safe to re-run.
# Usage:  bash configure.sh
# ============================================================

set -uo pipefail

ERROR_COUNT=0
ERRORS=()

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$STACK_DIR/.env"

# ── PUID/PGID/TZ from current system ───────────────────────
export PUID="$(id -u)"
export PGID="$(id -g)"
export TZ
TZ=$(timedatectl show --property=Timezone --value 2>/dev/null) \
    || TZ=$(cat /etc/timezone 2>/dev/null) \
    || TZ=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||') \
    || TZ="UTC"

# ── Load .env ──────────────────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then echo "ERROR: $ENV_FILE not found"; exit 1; fi
set -o allexport; source "$ENV_FILE"; set +o allexport

# ── Colours / helpers ──────────────────────────────────────
GRN='\033[0;32m'; YLW='\033[1;33m'; RED='\033[0;31m'; BLD='\033[1m'; NC='\033[0m'
ok()      { echo -e "  ${GRN}✓${NC}  $*"; }
skip()    { echo -e "  ${YLW}–${NC}  $*"; }
fail()    { echo -e "  ${RED}✗${NC}  $*"; ERROR_COUNT=$((ERROR_COUNT + 1)); ERRORS+=("$*"); }
section() { echo -e "\n${BLD}── $* ${NC}$(printf '─%.0s' $(seq 1 $((50 - ${#1}))))"; }
die()     { echo -e "${RED}FATAL:${NC} $*"; exit 1; }

# Check a key isn't still a placeholder
is_placeholder() { local v; v=$(grep -m1 "^${1}=" "$ENV_FILE" | cut -d= -f2-); [[ -z "$v" || "$v" == *"your_"* ]]; }

# ── JSON helpers (python3 primary, jq fallback, grep last resort) ──
json_get() {
    local json="$1" key="$2"
    python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('${key}',''))" "$json" 2>/dev/null \
        || echo "$json" | jq -r ".${key} // empty" 2>/dev/null \
        || echo "$json" | grep -oP "(?<=\"${key}\":\")[^\"]+" | head -1
}

# Generic HTTP call; returns "BODY\nHTTP_CODE"
http() {
    local method="$1" url="$2"; shift 2
    curl -s -w "\n%{http_code}" -X "$method" "$url" "$@"
}
body()  { echo "$1" | head -n -1; }
code()  { echo "$1" | tail -n 1; }
ok_code() { [[ "$(code "$1")" == "2"* ]]; }

# ── Wait for HTTP endpoint ─────────────────────────────────
wait_http() {
    local url="$1" label="$2" max="${3:-120}"
    local i=0
    echo -ne "  Waiting for ${label}"
    while (( i < max )); do
        curl -sf --max-time 2 "$url" &>/dev/null && { echo ""; return 0; }
        sleep 3; i=$((i+3)); echo -n "."
    done
    echo ""; return 1
}

# ── API helpers ────────────────────────────────────────────
arr_get()  { http GET  "$1" -H "X-Api-Key: $2" -H "Content-Type: application/json"; }
arr_post() { http POST "$1" -H "X-Api-Key: $2" -H "Content-Type: application/json" -d "$3"; }
arr_exists() {
    # Check if an arr response array contains a field=value match
    local resp="$1" field="$2" value="$3"
    echo "$(body "$resp")" | python3 -c "
import json,sys
try:
    items = json.load(sys.stdin)
    found = any(str(i.get('${field}','')).lower() == '${value}'.lower() for i in items)
    sys.exit(0 if found else 1)
except: sys.exit(1)
" 2>/dev/null
}
is_already_exists() {
    # Check if an API error response means the resource already exists
    local resp_body="$1"
    echo "$resp_body" | grep -qiE "already configured|should be unique|already exists"
}

# ── Validate API keys ──────────────────────────────────────
echo ""
echo "============================================================"
echo " Media Server — Service Configuration"
echo "============================================================"

MISSING=()
for key in SONARR_API_KEY RADARR_API_KEY PROWLARR_API_KEY BAZARR_API_KEY; do
    is_placeholder "$key" && MISSING+=("$key")
done

if (( ${#MISSING[@]} > 0 )); then
    echo ""
    fail "The following API keys are missing in .env:"
    for k in "${MISSING[@]}"; do fail "  $k"; done
    echo ""
    echo "  Run:  bash get-api-keys.sh"
    echo "  Then: bash configure.sh"
    exit 1
fi

# ============================================================
# 1. WAIT FOR ALL SERVICES
# ============================================================
section "Checking services"
wait_http "http://localhost:8080"           "qBittorrent" 120 || fail "qBittorrent not responding — skipping its config"
wait_http "http://localhost:7878/api/v3/system/status?apikey=${RADARR_API_KEY}" "Radarr"       120 || die "Radarr not responding"
wait_http "http://localhost:8989/api/v3/system/status?apikey=${SONARR_API_KEY}" "Sonarr"       120 || die "Sonarr not responding"
wait_http "http://localhost:9696/api/v1/system/status?apikey=${PROWLARR_API_KEY}" "Prowlarr"     120 || die "Prowlarr not responding"
wait_http "http://localhost:6767/api/system/status?apikey=${BAZARR_API_KEY}" "Bazarr" 120 || fail "Bazarr not responding — skipping its config"

# ============================================================
# 2. QBITTORRENT — Set default save path and credentials
# ============================================================
section "qBittorrent"

QBIT_COOKIE=$(mktemp)
qbit_logged_in=false

# Try logging in with desired credentials first (idempotent re-run)
login_resp=$(curl -sc "$QBIT_COOKIE" -X POST "http://localhost:8080/api/v2/auth/login" \
    --data-urlencode "username=${QBIT_USERNAME:-admin}" \
    --data-urlencode "password=${QBIT_PASSWORD:-adminadmin}" 2>/dev/null)
if [[ "$login_resp" == "Ok." ]]; then
    qbit_logged_in=true
    skip "Logged in with configured credentials"
else
    # First run: qBit uses admin + random temp password from logs
    temp_pass=$(docker logs qbittorrent 2>&1 | grep -oP 'temporary password.*: \K.*' | tail -1)
    if [[ -n "$temp_pass" ]]; then
        login_resp=$(curl -sc "$QBIT_COOKIE" -X POST "http://localhost:8080/api/v2/auth/login" \
            --data-urlencode "username=admin" \
            --data-urlencode "password=${temp_pass}" 2>/dev/null)
        if [[ "$login_resp" == "Ok." ]]; then
            qbit_logged_in=true
            # Set desired credentials
            prefs_json=$(python3 -c "
import json, sys
print(json.dumps({
    'web_ui_username': sys.argv[1],
    'web_ui_password': sys.argv[2]
}))" "${QBIT_USERNAME:-admin}" "${QBIT_PASSWORD:-adminadmin}")
            cred_resp=$(curl -s -o /dev/null -w "%{http_code}" -b "$QBIT_COOKIE" \
                -X POST "http://localhost:8080/api/v2/app/setPreferences" \
                --data-urlencode "json=$prefs_json")
            [[ "$cred_resp" == "200" ]] && ok "Credentials updated to ${QBIT_USERNAME:-admin}" \
                || fail "Could not update credentials (HTTP $cred_resp)"
        fi
    fi
fi

if [[ "$qbit_logged_in" == true ]]; then
    prefs_resp=$(curl -s -o /dev/null -w "%{http_code}" -b "$QBIT_COOKIE" \
        -X POST "http://localhost:8080/api/v2/app/setPreferences" \
        --data-urlencode 'json={"save_path":"/downloads","temp_path":"/downloads/incomplete","temp_path_enabled":true,"incomplete_files_ext":true}')
    [[ "$prefs_resp" == "200" ]] && ok "Save path set to /downloads" || fail "Could not set preferences (HTTP $prefs_resp)"
else
    fail "qBittorrent login failed — check QBIT_USERNAME/QBIT_PASSWORD in .env"
fi
rm -f "$QBIT_COOKIE"

# ============================================================
# 3. RADARR — Download client + root folder
# ============================================================
section "Radarr"

RADARR_BASE="http://localhost:7878"
RADARR_KEY="$RADARR_API_KEY"

# 3a. qBittorrent download client
resp=$(arr_get "$RADARR_BASE/api/v3/downloadclient" "$RADARR_KEY")
if arr_exists "$resp" "implementation" "QBittorrent"; then
    skip "qBittorrent download client already configured"
else
    payload=$(cat <<JSON
{
  "enable": true,
  "protocol": "torrent",
  "priority": 1,
  "removeCompletedDownloads": true,
  "removeFailedDownloads": true,
  "name": "qBittorrent",
  "fields": [
    {"name": "host",                 "value": "qbittorrent"},
    {"name": "port",                 "value": 8080},
    {"name": "useSsl",               "value": false},
    {"name": "urlBase",              "value": ""},
    {"name": "username",             "value": "${QBIT_USERNAME:-admin}"},
    {"name": "password",             "value": "${QBIT_PASSWORD:-adminadmin}"},
    {"name": "movieCategory",        "value": "radarr"},
    {"name": "recentMoviePriority",  "value": 0},
    {"name": "olderMoviePriority",   "value": 0},
    {"name": "initialState",         "value": 0},
    {"name": "sequentialOrder",      "value": false},
    {"name": "firstAndLast",         "value": false}
  ],
  "implementationName": "qBittorrent",
  "implementation": "QBittorrent",
  "configContract": "QBittorrentSettings",
  "tags": []
}
JSON
)
    resp=$(arr_post "$RADARR_BASE/api/v3/downloadclient" "$RADARR_KEY" "$payload")
    if ok_code "$resp"; then ok "qBittorrent download client added"
    elif is_already_exists "$(body "$resp")"; then skip "qBittorrent already configured in Radarr"
    else fail "Failed to add qBittorrent to Radarr (HTTP $(code "$resp")): $(body "$resp")"; fi
fi

# 3b. Root folder
resp=$(arr_get "$RADARR_BASE/api/v3/rootfolder" "$RADARR_KEY")
if arr_exists "$resp" "path" "/movies"; then
    skip "Root folder /movies already set"
else
    resp=$(arr_post "$RADARR_BASE/api/v3/rootfolder" "$RADARR_KEY" '{"path":"/movies"}')
    if ok_code "$resp"; then ok "Root folder /movies added"
    elif is_already_exists "$(body "$resp")"; then skip "Root folder /movies already set"
    else fail "Failed to add root folder (HTTP $(code "$resp")): $(body "$resp")"; fi
fi

# ============================================================
# 4. SONARR — Download client + root folder
# ============================================================
section "Sonarr"

SONARR_BASE="http://localhost:8989"
SONARR_KEY="$SONARR_API_KEY"

# 4a. qBittorrent download client
resp=$(arr_get "$SONARR_BASE/api/v3/downloadclient" "$SONARR_KEY")
if arr_exists "$resp" "implementation" "QBittorrent"; then
    skip "qBittorrent download client already configured"
else
    payload=$(cat <<JSON
{
  "enable": true,
  "protocol": "torrent",
  "priority": 1,
  "removeCompletedDownloads": true,
  "removeFailedDownloads": true,
  "name": "qBittorrent",
  "fields": [
    {"name": "host",               "value": "qbittorrent"},
    {"name": "port",               "value": 8080},
    {"name": "useSsl",             "value": false},
    {"name": "urlBase",            "value": ""},
    {"name": "username",           "value": "${QBIT_USERNAME:-admin}"},
    {"name": "password",           "value": "${QBIT_PASSWORD:-adminadmin}"},
    {"name": "tvCategory",         "value": "sonarr"},
    {"name": "recentTvPriority",   "value": 0},
    {"name": "olderTvPriority",    "value": 0},
    {"name": "initialState",       "value": 0},
    {"name": "sequentialOrder",    "value": false},
    {"name": "firstAndLast",       "value": false}
  ],
  "implementationName": "qBittorrent",
  "implementation": "QBittorrent",
  "configContract": "QBittorrentSettings",
  "tags": []
}
JSON
)
    resp=$(arr_post "$SONARR_BASE/api/v3/downloadclient" "$SONARR_KEY" "$payload")
    if ok_code "$resp"; then ok "qBittorrent download client added"
    elif is_already_exists "$(body "$resp")"; then skip "qBittorrent already configured in Sonarr"
    else fail "Failed to add qBittorrent to Sonarr (HTTP $(code "$resp")): $(body "$resp")"; fi
fi

# 4b. Root folder
resp=$(arr_get "$SONARR_BASE/api/v3/rootfolder" "$SONARR_KEY")
if arr_exists "$resp" "path" "/tv"; then
    skip "Root folder /tv already set"
else
    resp=$(arr_post "$SONARR_BASE/api/v3/rootfolder" "$SONARR_KEY" '{"path":"/tv"}')
    if ok_code "$resp"; then ok "Root folder /tv added"
    elif is_already_exists "$(body "$resp")"; then skip "Root folder /tv already set"
    else fail "Failed to add root folder (HTTP $(code "$resp")): $(body "$resp")"; fi
fi

# ============================================================
# 5. PROWLARR — Add Radarr + Sonarr as apps, trigger sync
# ============================================================
section "Prowlarr"

PROWLARR_BASE="http://localhost:9696"
PROWLARR_KEY="$PROWLARR_API_KEY"

resp=$(arr_get "$PROWLARR_BASE/api/v1/applications" "$PROWLARR_KEY")

# 5a. Radarr app
if arr_exists "$resp" "implementation" "Radarr"; then
    skip "Radarr app already registered in Prowlarr"
else
    payload=$(cat <<JSON
{
  "syncLevel": "fullSync",
  "name": "Radarr",
  "fields": [
    {"name": "prowlarrUrl",     "value": "http://prowlarr:9696"},
    {"name": "baseUrl",         "value": "http://radarr:7878"},
    {"name": "apiKey",          "value": "${RADARR_API_KEY}"},
    {"name": "syncCategories",  "value": [2000,2010,2020,2030,2035,2040,2045,2050,2060,2070,2080]}
  ],
  "implementationName": "Radarr",
  "implementation": "Radarr",
  "configContract": "RadarrSettings",
  "tags": []
}
JSON
)
    resp2=$(arr_post "$PROWLARR_BASE/api/v1/applications" "$PROWLARR_KEY" "$payload")
    if ok_code "$resp2"; then ok "Radarr app added to Prowlarr"
    elif is_already_exists "$(body "$resp2")"; then skip "Radarr app already registered in Prowlarr"
    else fail "Failed to add Radarr app (HTTP $(code "$resp2")): $(body "$resp2")"; fi
fi

# 5b. Sonarr app
resp=$(arr_get "$PROWLARR_BASE/api/v1/applications" "$PROWLARR_KEY")
if arr_exists "$resp" "implementation" "Sonarr"; then
    skip "Sonarr app already registered in Prowlarr"
else
    payload=$(cat <<JSON
{
  "syncLevel": "fullSync",
  "name": "Sonarr",
  "fields": [
    {"name": "prowlarrUrl",         "value": "http://prowlarr:9696"},
    {"name": "baseUrl",             "value": "http://sonarr:8989"},
    {"name": "apiKey",              "value": "${SONARR_API_KEY}"},
    {"name": "syncCategories",      "value": [5000,5010,5020,5030,5040,5045,5050,5060,5070,5080]},
    {"name": "animeSyncCategories", "value": [5070]}
  ],
  "implementationName": "Sonarr",
  "implementation": "Sonarr",
  "configContract": "SonarrSettings",
  "tags": []
}
JSON
)
    resp2=$(arr_post "$PROWLARR_BASE/api/v1/applications" "$PROWLARR_KEY" "$payload")
    if ok_code "$resp2"; then ok "Sonarr app added to Prowlarr"
    elif is_already_exists "$(body "$resp2")"; then skip "Sonarr app already registered in Prowlarr"
    else fail "Failed to add Sonarr app (HTTP $(code "$resp2")): $(body "$resp2")"; fi
fi

# 5c. Trigger full sync
resp=$(arr_post "$PROWLARR_BASE/api/v1/command" "$PROWLARR_KEY" '{"name":"ApplicationIndexerSync"}')
ok_code "$resp" && ok "Indexer sync triggered" \
    || fail "Sync trigger failed (HTTP $(code "$resp"))"

# ============================================================
# 6. BAZARR — Connect to Radarr & Sonarr
# ============================================================
section "Bazarr"

BAZARR_BASE="http://localhost:6767"
BAZARR_KEY="$BAZARR_API_KEY"

# Get current Bazarr settings to check existing config
current=$(http GET "$BAZARR_BASE/api/system/settings" -H "X-API-KEY: $BAZARR_KEY")

radarr_enabled=$(body "$current" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get('radarr',{}).get('enabled', False))
except: print(False)
" 2>/dev/null)

sonarr_enabled=$(body "$current" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get('sonarr',{}).get('enabled', False))
except: print(False)
" 2>/dev/null)

if [[ "$radarr_enabled" == "True" ]]; then
    skip "Radarr already connected in Bazarr"
else
    payload=$(cat <<JSON
{
  "radarr": {
    "enabled": true,
    "host": "radarr",
    "port": 7878,
    "apikey": "${RADARR_API_KEY}",
    "ssl": false,
    "base_url": "/",
    "movies_sync": 60,
    "only_monitored": false,
    "sync_only_monitored_movies": false
  }
}
JSON
)
    resp=$(http POST "$BAZARR_BASE/api/system/settings" \
        -H "X-API-KEY: $BAZARR_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload")
    ok_code "$resp" && ok "Radarr connected in Bazarr" \
        || fail "Failed to connect Radarr (HTTP $(code "$resp")): $(body "$resp")"
fi

if [[ "$sonarr_enabled" == "True" ]]; then
    skip "Sonarr already connected in Bazarr"
else
    payload=$(cat <<JSON
{
  "sonarr": {
    "enabled": true,
    "host": "sonarr",
    "port": 8989,
    "apikey": "${SONARR_API_KEY}",
    "ssl": false,
    "base_url": "/",
    "series_sync": 60,
    "only_monitored": false,
    "sync_only_monitored_series": false
  }
}
JSON
)
    resp=$(http POST "$BAZARR_BASE/api/system/settings" \
        -H "X-API-KEY: $BAZARR_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload")
    ok_code "$resp" && ok "Sonarr connected in Bazarr" \
        || fail "Failed to connect Sonarr (HTTP $(code "$resp")): $(body "$resp")"
fi

# ============================================================
# 7. JELLYSEERR — Add Radarr + Sonarr
#    (only runs if wizard is complete and API key is set)
# ============================================================
section "Jellyseerr"

if is_placeholder "JELLYSEERR_API_KEY"; then
    skip "JELLYSEERR_API_KEY not set — complete the Jellyseerr wizard first, then re-run"
else
    JS_BASE="http://localhost:5055"
    JS_KEY="$JELLYSEERR_API_KEY"

    # Check if Jellyseerr wizard is complete
    public_resp=$(http GET "$JS_BASE/api/v1/settings/public" -H "X-Api-Key: $JS_KEY")
    initialized=$(body "$public_resp" | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('initialized', False))
except: print(False)
" 2>/dev/null)

    if [[ "$initialized" != "True" ]]; then
        # Try to finalize the wizard (auth was already done in install.sh)
        init_resp=$(http POST "$JS_BASE/api/v1/settings/initialize" -H "X-Api-Key: $JS_KEY" -H "Content-Type: application/json")
        if ok_code "$init_resp"; then
            ok "Jellyseerr wizard finalized"
            initialized="True"
        else
            skip "Jellyseerr wizard not yet complete — run install.sh or complete it at http://localhost:5055"
        fi
    fi

    if [[ "$initialized" != "True" ]]; then
        : # already warned above
    else
        # Get Radarr quality profiles
        radarr_profiles=$(arr_get "http://localhost:7878/api/v3/qualityprofile" "$RADARR_API_KEY")
        radarr_profile_id=$(body "$radarr_profiles" | python3 -c "
import json,sys
try:
    ps=json.load(sys.stdin)
    p=next((x for x in ps if x['name']=='Any'), ps[0] if ps else None)
    print(p['id'] if p else 1)
except: print(1)
" 2>/dev/null)
        radarr_profile_name=$(body "$radarr_profiles" | python3 -c "
import json,sys
try:
    ps=json.load(sys.stdin)
    p=next((x for x in ps if x['name']=='Any'), ps[0] if ps else None)
    print(p['name'] if p else 'Any')
except: print('Any')
" 2>/dev/null)

        # Get Sonarr quality profiles
        sonarr_profiles=$(arr_get "http://localhost:8989/api/v3/qualityprofile" "$SONARR_API_KEY")
        sonarr_profile_id=$(body "$sonarr_profiles" | python3 -c "
import json,sys
try:
    ps=json.load(sys.stdin)
    p=next((x for x in ps if x['name']=='Any'), ps[0] if ps else None)
    print(p['id'] if p else 1)
except: print(1)
" 2>/dev/null)
        sonarr_profile_name=$(body "$sonarr_profiles" | python3 -c "
import json,sys
try:
    ps=json.load(sys.stdin)
    p=next((x for x in ps if x['name']=='Any'), ps[0] if ps else None)
    print(p['name'] if p else 'Any')
except: print('Any')
" 2>/dev/null)

        # Check existing Radarr servers
        existing_radarr=$(http GET "$JS_BASE/api/v1/settings/radarr" -H "X-Api-Key: $JS_KEY")
        if echo "$(body "$existing_radarr")" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d else 1)" 2>/dev/null; then
            skip "Radarr already configured in Jellyseerr"
        else
            payload=$(cat <<JSON
{
  "name": "Radarr",
  "hostname": "radarr",
  "port": 7878,
  "apiKey": "${RADARR_API_KEY}",
  "useSsl": false,
  "baseUrl": "",
  "activeProfileId": ${radarr_profile_id:-1},
  "activeProfileName": "${radarr_profile_name:-Any}",
  "activeDirectory": "/movies",
  "minimumAvailability": "released",
  "is4k": false,
  "isDefault": true,
  "enableSeasonFolders": false,
  "externalUrl": "",
  "syncEnabled": false,
  "preventSearch": false
}
JSON
)
            resp=$(http POST "$JS_BASE/api/v1/settings/radarr" \
                -H "X-Api-Key: $JS_KEY" \
                -H "Content-Type: application/json" \
                -d "$payload")
            ok_code "$resp" && ok "Radarr added to Jellyseerr (profile: ${radarr_profile_name:-Any})" \
                || fail "Failed to add Radarr (HTTP $(code "$resp")): $(body "$resp")"
        fi

        # Check existing Sonarr servers
        existing_sonarr=$(http GET "$JS_BASE/api/v1/settings/sonarr" -H "X-Api-Key: $JS_KEY")
        if echo "$(body "$existing_sonarr")" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d else 1)" 2>/dev/null; then
            skip "Sonarr already configured in Jellyseerr"
        else
            payload=$(cat <<JSON
{
  "name": "Sonarr",
  "hostname": "sonarr",
  "port": 8989,
  "apiKey": "${SONARR_API_KEY}",
  "useSsl": false,
  "baseUrl": "",
  "activeProfileId": ${sonarr_profile_id:-1},
  "activeProfileName": "${sonarr_profile_name:-Any}",
  "activeDirectory": "/tv",
  "is4k": false,
  "isDefault": true,
  "enableSeasonFolders": true,
  "externalUrl": "",
  "syncEnabled": false,
  "preventSearch": false
}
JSON
)
            resp=$(http POST "$JS_BASE/api/v1/settings/sonarr" \
                -H "X-Api-Key: $JS_KEY" \
                -H "Content-Type: application/json" \
                -d "$payload")
            ok_code "$resp" && ok "Sonarr added to Jellyseerr (profile: ${sonarr_profile_name:-Any})" \
                || fail "Failed to add Sonarr (HTTP $(code "$resp")): $(body "$resp")"
        fi
    fi
fi

# ============================================================
# 8. RECYCLARR — Trigger initial sync
# ============================================================
section "Recyclarr"

if is_placeholder "SONARR_API_KEY" || is_placeholder "RADARR_API_KEY"; then
    skip "API keys missing — skipping Recyclarr sync"
else
    sync_out=$(docker compose -f "$STACK_DIR/docker-compose.yml" \
        exec -T recyclarr recyclarr sync 2>&1) && \
        ok "Recyclarr sync successful" || \
        fail "Recyclarr sync had issues (check config/recyclarr/recyclarr.yml):\n    $sync_out"
fi

# ============================================================
# Done
# ============================================================
echo ""
if (( ERROR_COUNT > 0 )); then
    echo "============================================================"
    echo -e " ${RED}Configuration completed with ${ERROR_COUNT} error(s)${NC}"
    echo "============================================================"
    echo ""
    echo "  Errors:"
    for e in "${ERRORS[@]}"; do
        echo -e "   ${RED}✗${NC}  $e"
    done
else
    echo "============================================================"
    echo -e " ${GRN}Configuration complete${NC}"
    echo "============================================================"
fi
echo ""
echo "  Still manual (can't be automated):"
echo "   • Prowlarr → Indexers: add your trackers/indexers"
echo "   • Bazarr → Settings → Subtitles: add providers"
echo "   • Uptime Kuma → create account and add monitors"
echo "   • Audiobookshelf → create admin account"
echo ""
