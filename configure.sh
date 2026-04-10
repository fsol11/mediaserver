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

# ── Re-exec with docker group if not active ────────────────
if ! docker info >/dev/null 2>&1 && getent group docker | grep -q "\b$(whoami)\b"; then
    exec sg docker -c "bash \"$0\" $*"
fi

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
arr_put()  { http PUT  "$1" -H "X-Api-Key: $2" -H "Content-Type: application/json" -d "$3"; }
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
wait_http "http://localhost:8191"           "FlareSolverr" 60 || fail "FlareSolverr not responding — indexers behind Cloudflare may not work"

# ============================================================
# 2. QBITTORRENT — Set default save path and credentials
# ============================================================
section "qBittorrent"

QBIT_COOKIE=$(mktemp)
qbit_logged_in=false

# Try logging in with desired credentials first (idempotent re-run)
login_resp=$(curl -sc "$QBIT_COOKIE" -X POST "http://localhost:8080/api/v2/auth/login" \
    --data-urlencode "username=${ADMIN_USER:-admin}" \
    --data-urlencode "password=${ADMIN_PASSWORD:-adminadmin}" 2>/dev/null)
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
})" "${ADMIN_USER:-admin}" "${ADMIN_PASSWORD:-adminadmin}")
            cred_resp=$(curl -s -o /dev/null -w "%{http_code}" -b "$QBIT_COOKIE" \
                -X POST "http://localhost:8080/api/v2/app/setPreferences" \
                --data-urlencode "json=$prefs_json")
            [[ "$cred_resp" == "200" ]] && ok "Credentials updated to ${ADMIN_USER:-admin}" \
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
    fail "qBittorrent login failed — check ADMIN_USER/ADMIN_PASSWORD in .env"
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
    {"name": "username",             "value": "${ADMIN_USER:-admin}"},
    {"name": "password",             "value": "${ADMIN_PASSWORD:-adminadmin}"},
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

# 3c. Authentication
if [[ -n "${ADMIN_USER:-}" && -n "${ADMIN_PASSWORD:-}" ]]; then
    host_resp=$(arr_get "$RADARR_BASE/api/v3/config/host" "$RADARR_KEY")
    host_body=$(body "$host_resp")
    auth_method=$(echo "$host_body" | python3 -c "import json,sys; print(json.load(sys.stdin).get('authenticationMethod','none'))" 2>/dev/null || echo "none")
    if [[ "$auth_method" == "forms" ]]; then
        skip "Authentication already enabled (Forms)"
    else
        host_id=$(echo "$host_body" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',1))" 2>/dev/null || echo "1")
        auth_payload=$(python3 -c "
import json,sys
d=json.loads(sys.argv[1])
d['authenticationMethod']='forms'
d['authenticationRequired']='enabled'
d['username']=sys.argv[2]
d['password']=sys.argv[3]
d['passwordConfirmation']=sys.argv[3]
print(json.dumps(d))" "$host_body" "${ADMIN_USER}" "${ADMIN_PASSWORD}")
        resp=$(arr_put "$RADARR_BASE/api/v3/config/host/$host_id" "$RADARR_KEY" "$auth_payload")
        ok_code "$resp" && ok "Authentication enabled (${ADMIN_USER})" \
            || fail "Failed to set authentication (HTTP $(code "$resp")): $(body "$resp")"
    fi
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
    {"name": "username",           "value": "${ADMIN_USER:-admin}"},
    {"name": "password",           "value": "${ADMIN_PASSWORD:-adminadmin}"},
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

# 4c. Authentication
if [[ -n "${ADMIN_USER:-}" && -n "${ADMIN_PASSWORD:-}" ]]; then
    host_resp=$(arr_get "$SONARR_BASE/api/v3/config/host" "$SONARR_KEY")
    host_body=$(body "$host_resp")
    auth_method=$(echo "$host_body" | python3 -c "import json,sys; print(json.load(sys.stdin).get('authenticationMethod','none'))" 2>/dev/null || echo "none")
    if [[ "$auth_method" == "forms" ]]; then
        skip "Authentication already enabled (Forms)"
    else
        host_id=$(echo "$host_body" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',1))" 2>/dev/null || echo "1")
        auth_payload=$(python3 -c "
import json,sys
d=json.loads(sys.argv[1])
d['authenticationMethod']='forms'
d['authenticationRequired']='enabled'
d['username']=sys.argv[2]
d['password']=sys.argv[3]
d['passwordConfirmation']=sys.argv[3]
print(json.dumps(d))" "$host_body" "${ADMIN_USER}" "${ADMIN_PASSWORD}")
        resp=$(arr_put "$SONARR_BASE/api/v3/config/host/$host_id" "$SONARR_KEY" "$auth_payload")
        ok_code "$resp" && ok "Authentication enabled (${ADMIN_USER})" \
            || fail "Failed to set authentication (HTTP $(code "$resp")): $(body "$resp")"
    fi
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

# 5c. FlareSolverr proxy (for Cloudflare-protected indexers)
proxy_resp=$(arr_get "$PROWLARR_BASE/api/v1/indexerProxy" "$PROWLARR_KEY")
if arr_exists "$proxy_resp" "implementation" "FlareSolverr"; then
    skip "FlareSolverr proxy already configured"
else
    proxy_payload=$(cat <<JSON
{
  "name": "FlareSolverr",
  "fields": [
    {"name": "host",           "value": "http://flaresolverr:8191/"},
    {"name": "requestTimeout", "value": 60}
  ],
  "implementationName": "FlareSolverr",
  "implementation": "FlareSolverr",
  "configContract": "FlareSolverrSettings",
  "tags": []
}
JSON
)
    resp2=$(arr_post "$PROWLARR_BASE/api/v1/indexerProxy" "$PROWLARR_KEY" "$proxy_payload")
    if ok_code "$resp2"; then ok "FlareSolverr proxy added to Prowlarr"
    elif is_already_exists "$(body "$resp2")"; then skip "FlareSolverr proxy already configured"
    else fail "Failed to add FlareSolverr proxy (HTTP $(code "$resp2")): $(body "$resp2")"; fi
fi

# 5d. Authentication
if [[ -n "${ADMIN_USER:-}" && -n "${ADMIN_PASSWORD:-}" ]]; then
    host_resp=$(arr_get "$PROWLARR_BASE/api/v1/config/host" "$PROWLARR_KEY")
    host_body=$(body "$host_resp")
    prowl_user=$(echo "$host_body" | python3 -c "import json,sys; print(json.load(sys.stdin).get('username',''))" 2>/dev/null || echo "")
    if [[ -n "$prowl_user" ]]; then
        skip "Authentication already configured (${prowl_user})"
    else
        host_id=$(echo "$host_body" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',1))" 2>/dev/null || echo "1")
        auth_payload=$(python3 -c "
import json,sys
d=json.loads(sys.argv[1])
d['authenticationMethod']='forms'
d['authenticationRequired']='enabled'
d['username']=sys.argv[2]
d['password']=sys.argv[3]
print(json.dumps(d))" "$host_body" "${ADMIN_USER}" "${ADMIN_PASSWORD}")
        resp=$(arr_put "$PROWLARR_BASE/api/v1/config/host/$host_id" "$PROWLARR_KEY" "$auth_payload")
        ok_code "$resp" && ok "Authentication enabled (${ADMIN_USER})" \
            || fail "Failed to set authentication (HTTP $(code "$resp")): $(body "$resp")"
    fi
fi

# 5e. Add public indexers from PROWLARR_INDEXERS list
if [[ -n "${PROWLARR_INDEXERS:-}" ]]; then
    # Fetch indexer schema for building payloads
    PROWLARR_SCHEMA_FILE=$(mktemp)
    curl -sf "http://localhost:9696/api/v1/indexer/schema" -H "X-Api-Key: $PROWLARR_KEY" > "$PROWLARR_SCHEMA_FILE" 2>/dev/null
    schema_count=$(python3 -c "import json; print(len(json.load(open('$PROWLARR_SCHEMA_FILE'))))" 2>/dev/null || echo 0)

    if (( schema_count == 0 )); then
        fail "Could not fetch Prowlarr indexer schemas — skipping indexer setup"
    else
        existing_indexers=$(arr_get "$PROWLARR_BASE/api/v1/indexer" "$PROWLARR_KEY")
        IFS=',' read -ra INDEXER_LIST <<< "$PROWLARR_INDEXERS"
        added=0; skipped=0; failed_idx=0; cf_blocked=0

        for idx_name in "${INDEXER_LIST[@]}"; do
            # Trim whitespace
            idx_name=$(echo "$idx_name" | xargs)
            [[ -z "$idx_name" ]] && continue

            # Check if already added (match on definitionName)
            if echo "$(body "$existing_indexers")" | python3 -c "
import json,sys
try:
    items=json.load(sys.stdin)
    found=any(str(i.get('definitionName','')).lower()=='${idx_name}'.lower() for i in items)
    sys.exit(0 if found else 1)
except: sys.exit(1)
" 2>/dev/null; then
                skipped=$((skipped + 1))
                continue
            fi

            # Build minimal payload from schema
            payload=$(python3 << PYEOF
import json
with open('$PROWLARR_SCHEMA_FILE') as fh:
    schemas = json.load(fh)
schema = next((s for s in schemas if s.get('definitionName','').lower() == '${idx_name}'.lower()), None)
if not schema:
    print('')
else:
    p = {
        'definitionName': schema['definitionName'],
        'name': schema['definitionName'],
        'implementation': schema.get('implementation', 'Cardigann'),
        'configContract': schema.get('configContract', 'CardigannSettings'),
        'protocol': schema.get('protocol', 'torrent'),
        'enable': True,
        'priority': 25,
        'appProfileId': 1,
        'fields': schema.get('fields', []),
        'tags': []
    }
    print(json.dumps(p))
PYEOF
)

            if [[ -z "$payload" ]]; then
                fail "Indexer '${idx_name}' not found in Prowlarr schema"
                failed_idx=$((failed_idx + 1))
                continue
            fi

            resp2=$(arr_post "$PROWLARR_BASE/api/v1/indexer" "$PROWLARR_KEY" "$payload")
            if ok_code "$resp2"; then
                added=$((added + 1))
            elif is_already_exists "$(body "$resp2")"; then
                skipped=$((skipped + 1))
            elif echo "$(body "$resp2")" | grep -qi "CloudFlare Protection\|blocked by Cloud\|SSL connection could not\|Unable to connect to indexer.*Redirected"; then
                cf_blocked=$((cf_blocked + 1))
            else
                fail "Failed to add indexer '${idx_name}' (HTTP $(code "$resp2")): $(body "$resp2")"
                failed_idx=$((failed_idx + 1))
            fi
        done

        (( added > 0 ))      && ok "${added} indexer(s) added"
        (( skipped > 0 ))    && skip "${skipped} indexer(s) already existed"
        (( cf_blocked > 0 )) && skip "${cf_blocked} indexer(s) blocked by Cloudflare/SSL — add manually via Prowlarr UI"
        (( failed_idx > 0 )) && fail "${failed_idx} indexer(s) failed"
    fi
    rm -f "$PROWLARR_SCHEMA_FILE"
else
    skip "PROWLARR_INDEXERS not set in .env — skipping indexer setup"
fi

# 5f. Trigger full sync
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

# 6c. Authentication
if [[ -n "${ADMIN_USER:-}" && -n "${ADMIN_PASSWORD:-}" ]]; then
    bazarr_auth_type=$(body "$current" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get('auth',{}).get('type') or '')
except: print('')
" 2>/dev/null)
    if [[ -n "$bazarr_auth_type" ]]; then
        skip "Authentication already enabled"
    else
        auth_payload=$(cat <<JSON
{
  "auth": {
    "type": "form",
    "username": "${ADMIN_USER}",
    "password": "${ADMIN_PASSWORD}"
  }
}
JSON
)
        resp=$(http POST "$BAZARR_BASE/api/system/settings" \
            -H "X-API-KEY: $BAZARR_KEY" \
            -H "Content-Type: application/json" \
            -d "$auth_payload")
        ok_code "$resp" && ok "Authentication enabled (${ADMIN_USER})" \
            || fail "Failed to set authentication (HTTP $(code "$resp")): $(body "$resp")"
    fi
fi

# ── Subtitle Providers ──────────────────────────────────────
if [[ -n "${BAZARR_PROVIDERS:-}" ]]; then
    BAZARR_CFG="$STACK_DIR/config/bazarr/config/config.yaml"
    if [[ ! -f "$BAZARR_CFG" ]]; then
        BAZARR_CFG="$STACK_DIR/config/bazarr/config.yaml"
    fi
    if [[ -f "$BAZARR_CFG" ]]; then
        # Read current providers from config
        current_providers=$(grep -A50 'enabled_providers:' "$BAZARR_CFG" \
            | tail -n+2 | sed -n '/^  - /{ s/^  - //; p; }; /^  [a-z]/q')
        # Build desired list from .env
        IFS=',' read -ra DESIRED_PROVS <<< "$BAZARR_PROVIDERS"
        desired_yaml=""
        for p in "${DESIRED_PROVS[@]}"; do
            p=$(echo "$p" | xargs)   # trim whitespace
            desired_yaml+="\n  - $p"
        done
        # Compare sorted lists
        current_sorted=$(echo "$current_providers" | sort)
        desired_sorted=$(printf '%s\n' "${DESIRED_PROVS[@]}" | xargs -n1 | sort)
        if [[ "$current_sorted" == "$desired_sorted" ]]; then
            skip "Subtitle providers already configured"
        else
            # Replace enabled_providers block in config YAML
            # Remove old list items, then insert new ones
            sed -i '/  enabled_providers:/,/^  [a-z]/{/  enabled_providers:/!{/^  [a-z]/!d}}' "$BAZARR_CFG"
            sed -i "s/  enabled_providers:.*/  enabled_providers:$desired_yaml/" "$BAZARR_CFG"
            # Restart Bazarr to pick up config changes (API ignores enabled_providers writes)
            docker restart bazarr &>/dev/null
            ok "Subtitle providers set: ${BAZARR_PROVIDERS}"
        fi
    else
        fail "Bazarr config file not found — cannot set providers"
    fi
else
    skip "BAZARR_PROVIDERS not set in .env — skipping provider setup"
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
# 8. JELLYFIN — Network config (Cloudflare tunnel awareness)
#    Ensures tunnel requests are treated as remote (for transcoding)
# ============================================================
section "Jellyfin Network"

if [[ -z "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]]; then
    skip "No Cloudflare tunnel configured — skipping network tuning"
elif is_placeholder "JELLYFIN_API_KEY"; then
    skip "JELLYFIN_API_KEY not set — skipping Jellyfin network config"
else
    JF_BASE="http://localhost:8096"
    JF_AUTH="Authorization: MediaBrowser Token=\"${JELLYFIN_API_KEY}\""

    # Detect LAN subnet from default gateway
    LAN_SUBNET=$(ip -4 route show default 2>/dev/null \
        | awk '{print $3}' \
        | sed 's/\.[0-9]*$/.0\/24/' \
        | head -1)
    [[ -z "$LAN_SUBNET" ]] && LAN_SUBNET="192.168.1.0/24"

    # Detect Docker network subnet for the mediaserver stack
    DOCKER_SUBNET=$(docker network inspect mediaserver_mediaserver 2>/dev/null \
        | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['IPAM']['Config'][0]['Subnet'])" 2>/dev/null)
    [[ -z "$DOCKER_SUBNET" ]] && DOCKER_SUBNET="172.18.0.0/16"

    JF_NETWORK_XML="$STACK_DIR/config/jellyfin/network.xml"
    if [[ ! -f "$JF_NETWORK_XML" ]]; then
        fail "Jellyfin network.xml not found"
    else
        # Check current LocalNetworkSubnets
        current_local=$(grep -oP '(?<=<string>)[^<]+' <<< "$(sed -n '/<LocalNetworkSubnets>/,/<\/LocalNetworkSubnets>/p' "$JF_NETWORK_XML")" | sort | tr '\n' '|')
        desired_local=$(printf '%s\n' "$LAN_SUBNET" "127.0.0.1/8" | sort | tr '\n' '|')

        current_proxy=$(grep -oP '(?<=<string>)[^<]+' <<< "$(sed -n '/<KnownProxies>/,/<\/KnownProxies>/p' "$JF_NETWORK_XML")" | sort | tr '\n' '|')
        desired_proxy=$(printf '%s\n' "$DOCKER_SUBNET" | sort | tr '\n' '|')

        needs_restart=false

        if [[ "$current_local" == "$desired_local" ]]; then
            skip "LocalNetworkSubnets already set ($LAN_SUBNET, 127.0.0.1/8)"
        else
            # Replace LocalNetworkSubnets block
            python3 -c "
import re, sys
with open(sys.argv[1], 'r') as f:
    content = f.read()
new_block = '''  <LocalNetworkSubnets>
    <string>${LAN_SUBNET}</string>
    <string>127.0.0.1/8</string>
  </LocalNetworkSubnets>'''
content = re.sub(
    r'  <LocalNetworkSubnets>.*?</LocalNetworkSubnets>',
    new_block, content, flags=re.DOTALL)
with open(sys.argv[1], 'w') as f:
    f.write(content)
" "$JF_NETWORK_XML"
            ok "LocalNetworkSubnets set to $LAN_SUBNET + 127.0.0.1/8"
            needs_restart=true
        fi

        if [[ "$current_proxy" == "$desired_proxy" ]]; then
            skip "KnownProxies already set ($DOCKER_SUBNET)"
        else
            # Replace KnownProxies block
            python3 -c "
import re, sys
with open(sys.argv[1], 'r') as f:
    content = f.read()
new_block = '''  <KnownProxies>
    <string>${DOCKER_SUBNET}</string>
  </KnownProxies>'''
content = re.sub(
    r'  <KnownProxies>.*?</KnownProxies>',
    new_block, content, flags=re.DOTALL)
with open(sys.argv[1], 'w') as f:
    f.write(content)
" "$JF_NETWORK_XML"
            ok "KnownProxies set to $DOCKER_SUBNET"
            needs_restart=true
        fi

        if [[ "$needs_restart" == true ]]; then
            docker restart jellyfin &>/dev/null
            ok "Jellyfin restarted to apply network changes"
        fi
    fi
fi

# ============================================================
# 8b. JELLYFIN — Transcoding (NVIDIA GPU + 8 Mbps remote bitrate)
#     If NVIDIA GPU is present in the container, enable NVENC
#     hardware transcoding and set remote bitrate limit to 8 Mbps.
# ============================================================
section "Jellyfin Transcoding"

if is_placeholder "JELLYFIN_API_KEY"; then
    skip "JELLYFIN_API_KEY not set — skipping transcoding config"
else
    JF_BASE="http://localhost:8096"
    JF_AUTH="Authorization: MediaBrowser Token=\"${JELLYFIN_API_KEY}\""
    JF_ENCODING_XML="$STACK_DIR/config/jellyfin/encoding.xml"

    # Check if NVIDIA GPU is accessible inside the Jellyfin container
    HAS_NVIDIA=false
    if docker exec jellyfin test -e /dev/nvidia0 2>/dev/null; then
        HAS_NVIDIA=true
    fi

    if [[ "$HAS_NVIDIA" == true ]]; then
        if [[ ! -f "$JF_ENCODING_XML" ]]; then
            fail "encoding.xml not found — skipping"
        else
            encoding_changed=false

            # Desired state for NVIDIA NVENC transcoding
            declare -A ENCODING_SETTINGS=(
                [HardwareAccelerationType]="nvenc"
                [EnableHardwareEncoding]="true"
                [EnableEnhancedNvdecDecoder]="true"
                [PreferSystemNativeHwDecoder]="true"
                [EnableDecodingColorDepth10Hevc]="true"
                [EnableDecodingColorDepth10Vp9]="true"
                [AllowHevcEncoding]="true"
            )

            for key in "${!ENCODING_SETTINGS[@]}"; do
                desired="${ENCODING_SETTINGS[$key]}"
                current=$(grep -oP "(?<=<${key}>)[^<]+" "$JF_ENCODING_XML" 2>/dev/null || echo "")
                if [[ "$current" != "$desired" ]]; then
                    sed -i "s|<${key}>[^<]*</${key}>|<${key}>${desired}</${key}>|" "$JF_ENCODING_XML"
                    encoding_changed=true
                fi
            done

            # Ensure all common codecs are in HardwareDecodingCodecs
            DESIRED_CODECS=("h264" "hevc" "mpeg2video" "mpeg4" "vc1" "vp8" "vp9" "av1")
            current_codecs=$(sed -n '/<HardwareDecodingCodecs>/,/<\/HardwareDecodingCodecs>/p' "$JF_ENCODING_XML" \
                | grep -oP '(?<=<string>)[^<]+' | sort | tr '\n' '|')
            desired_codecs=$(printf '%s\n' "${DESIRED_CODECS[@]}" | sort | tr '\n' '|')

            if [[ "$current_codecs" != "$desired_codecs" ]]; then
                codec_block="  <HardwareDecodingCodecs>"
                for c in "${DESIRED_CODECS[@]}"; do
                    codec_block+="\n    <string>${c}</string>"
                done
                codec_block+="\n  </HardwareDecodingCodecs>"

                python3 -c "
import re, sys
with open(sys.argv[1], 'r') as f:
    content = f.read()
content = re.sub(
    r'  <HardwareDecodingCodecs>.*?</HardwareDecodingCodecs>',
    sys.argv[2], content, flags=re.DOTALL)
with open(sys.argv[1], 'w') as f:
    f.write(content)
" "$JF_ENCODING_XML" "$(echo -e "$codec_block")"
                encoding_changed=true
            fi

            if [[ "$encoding_changed" == true ]]; then
                ok "NVENC hardware transcoding enabled (all codecs)"
            else
                skip "NVENC transcoding already configured"
            fi
        fi
    else
        skip "No NVIDIA GPU in Jellyfin container — skipping hardware transcoding"
    fi

    # Set server-wide remote client bitrate limit to 8 Mbps
    DESIRED_BITRATE=8000000
    current_config=$(curl -sf "$JF_BASE/System/Configuration" -H "$JF_AUTH" 2>/dev/null)
    current_bitrate=$(echo "$current_config" | python3 -c "import json,sys; print(json.load(sys.stdin).get('RemoteClientBitrateLimit',0))" 2>/dev/null || echo "0")

    if [[ "$current_bitrate" == "$DESIRED_BITRATE" ]]; then
        skip "Remote client bitrate limit already 8 Mbps"
    else
        # Update the config via API
        updated_config=$(echo "$current_config" | python3 -c "
import json, sys
cfg = json.load(sys.stdin)
cfg['RemoteClientBitrateLimit'] = $DESIRED_BITRATE
json.dump(cfg, sys.stdout)
")
        resp=$(curl -sf -X POST "$JF_BASE/System/Configuration" \
            -H "$JF_AUTH" \
            -H "Content-Type: application/json" \
            -d "$updated_config" -w "\n%{http_code}" 2>/dev/null)
        if [[ "$(echo "$resp" | tail -1)" == "204" || "$(echo "$resp" | tail -1)" == "200" ]]; then
            ok "Remote client bitrate limit set to 8 Mbps"
        else
            fail "Failed to set remote bitrate limit (HTTP $(echo "$resp" | tail -1))"
        fi
    fi

    # Restart Jellyfin if encoding settings changed
    if [[ "${encoding_changed:-false}" == true ]]; then
        docker restart jellyfin &>/dev/null
        ok "Jellyfin restarted to apply transcoding changes"
    fi
fi

# ============================================================
# 9. RECYCLARR — Trigger initial sync
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
# 10. UPTIME KUMA — Create account + add monitors
# ============================================================
section "Uptime Kuma"

if python3 -c "import uptime_kuma_api" &>/dev/null; then
    python3 - <<'PYEOF'
import os, sys
try:
    from uptime_kuma_api import UptimeKumaApi, MonitorType
except ImportError:
    print("  \033[1;33m\u2013\033[0m  uptime-kuma-api not installed \u2014 skipping")
    sys.exit(0)

try:
    api = UptimeKumaApi("http://localhost:3001", timeout=10)
except Exception as e:
    print(f"  \033[0;31m\u2717\033[0m  Cannot connect to Uptime Kuma: {e}")
    sys.exit(0)

user = os.environ.get("ADMIN_USER", "admin")
pw = os.environ.get("ADMIN_PASSWORD", "")

# Create admin account if needed
try:
    if api.need_setup():
        if not pw or pw == "changeme":
            print("  \033[1;33m\u2013\033[0m  Skipping Uptime Kuma setup \u2014 set ADMIN_PASSWORD in .env first")
            api.disconnect()
            sys.exit(0)
        api.setup(user, pw)
        print(f"  \033[0;32m\u2713\033[0m  Admin account created: {user}")
except Exception as e:
    print(f"  \033[0;31m\u2717\033[0m  Failed to create account: {e}")
    api.disconnect()
    sys.exit(0)

# Login
try:
    api.login(user, pw)
except Exception as e:
    print(f"  \033[1;33m\u2013\033[0m  Cannot login (account may already exist with different creds): {e}")
    api.disconnect()
    sys.exit(0)

# Service monitors to add (container names on the Docker network)
monitors = [
    ("Jellyfin",       "http://jellyfin:8096"),
    ("Jellyseerr",     "http://jellyseerr:5055"),
    ("Radarr",         "http://radarr:7878"),
    ("Sonarr",         "http://sonarr:8989"),
    ("Prowlarr",       "http://prowlarr:9696"),
    ("qBittorrent",    "http://qbittorrent:8080"),
    ("Bazarr",         "http://bazarr:6767"),
    ("Homepage",       "http://homepage:3000"),
    ("Audiobookshelf", "http://audiobookshelf:13378"),
    ("FlareSolverr",   "http://flaresolverr:8191"),
]

existing = {m["name"] for m in api.get_monitors()}
added = 0
for name, url in monitors:
    if name in existing:
        continue
    try:
        api.add_monitor(type=MonitorType.HTTP, name=name, url=url, interval=60, maxretries=3)
        added += 1
    except Exception as e:
        print(f"  \033[0;31m\u2717\033[0m  Failed to add {name}: {e}")

skipped = len(monitors) - added
if added:
    print(f"  \033[0;32m\u2713\033[0m  {added} monitor(s) added")
if skipped == len(monitors):
    print(f"  \033[1;33m\u2013\033[0m  All {skipped} monitors already exist")

api.disconnect()
PYEOF
else
    skip "uptime-kuma-api not installed \u2014 set up Uptime Kuma manually"
fi

# ============================================================
# 11. AUDIOBOOKSHELF — Create admin account
# ============================================================
section "Audiobookshelf"

ABS_URL="http://localhost:13378"
ABS_STATUS=$(curl -s --max-time 10 "$ABS_URL/status" 2>/dev/null) || ABS_STATUS=""

if [[ -z "$ABS_STATUS" ]]; then
    fail "Cannot reach Audiobookshelf at $ABS_URL"
else
    ABS_INIT=$(json_get "$ABS_STATUS" "isInit")
    if [[ "$ABS_INIT" == "True" || "$ABS_INIT" == "true" ]]; then
        ok "Admin account already exists"
    elif [[ -z "$ADMIN_PASSWORD" || "$ADMIN_PASSWORD" == "changeme" ]]; then
        skip "Skipping Audiobookshelf setup — set ADMIN_PASSWORD in .env first"
    else
        ABS_USER="${ADMIN_USER:-admin}"
        ABS_RESP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$ABS_URL/init" \
            -H "Content-Type: application/json" \
            -d "{\"newRoot\":{\"username\":\"$ABS_USER\",\"password\":\"$ADMIN_PASSWORD\"}}")
        if [[ "$ABS_RESP" == "200" ]]; then
            ok "Created admin account ($ABS_USER)"
        else
            fail "Audiobookshelf /init returned HTTP $ABS_RESP"
        fi
    fi

    # Extract API token for Homepage widget
    if is_placeholder "AUDIOBOOKSHELF_API_KEY" && [[ -n "${ADMIN_USER:-}" && -n "${ADMIN_PASSWORD:-}" ]]; then
        abs_login=$(curl -s -X POST "$ABS_URL/login" \
            -H "Content-Type: application/json" \
            -d "{\"username\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_PASSWORD}\"}" 2>/dev/null)
        abs_token=$(echo "$abs_login" | python3 -c "import json,sys; print(json.load(sys.stdin)['user']['token'])" 2>/dev/null)
        if [[ -n "$abs_token" ]]; then
            set_env "AUDIOBOOKSHELF_API_KEY" "$abs_token"
            ok "API token extracted"
        else
            fail "Could not extract Audiobookshelf API token"
        fi
    elif ! is_placeholder "AUDIOBOOKSHELF_API_KEY"; then
        skip "AUDIOBOOKSHELF_API_KEY already set"
    fi
fi

# ============================================================
# 12. CLOUDFLARE TUNNEL — Configure public hostnames
# ============================================================
section "Cloudflare Tunnel"

if [[ -z "${CLOUDFLARE_TUNNEL_TOKEN:-}" || -z "${CF_API_TOKEN:-}" || -z "${CF_DOMAIN:-}" ]]; then
    skip "Skipping — set CLOUDFLARE_TUNNEL_TOKEN, CF_API_TOKEN, and CF_DOMAIN in .env"
else
    # Decode account_id and tunnel_id from the tunnel token (base64 JSON: {"a":..., "t":..., "s":...})
    CF_TOKEN_JSON=$(echo "$CLOUDFLARE_TUNNEL_TOKEN" | base64 -d 2>/dev/null) || CF_TOKEN_JSON=""
    CF_ACCOUNT_ID=$(echo "$CF_TOKEN_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['a'])" 2>/dev/null)
    CF_TUNNEL_ID=$(echo "$CF_TOKEN_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['t'])" 2>/dev/null)

    if [[ -z "$CF_ACCOUNT_ID" || -z "$CF_TUNNEL_ID" ]]; then
        fail "Could not decode account/tunnel ID from CLOUDFLARE_TUNNEL_TOKEN"
    else
        CF_API="https://api.cloudflare.com/client/v4"
        cf_headers=(-H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")

        # Build ingress rules — order: specific hostnames first, catch-all last
        INGRESS=$(cat <<ENDJSON
[
  {"hostname": "jellyfin.${CF_DOMAIN}",  "service": "http://jellyfin:8096"},
  {"hostname": "requests.${CF_DOMAIN}",  "service": "http://jellyseerr:5055"},
  {"hostname": "books.${CF_DOMAIN}",     "service": "http://audiobookshelf:80"},
  {"hostname": "homepage.${CF_DOMAIN}",  "service": "http://homepage:3000"},
  {"hostname": "status.${CF_DOMAIN}",    "service": "http://uptime-kuma:3001"},
  {"hostname": "radarr.${CF_DOMAIN}",    "service": "http://radarr:7878"},
  {"hostname": "sonarr.${CF_DOMAIN}",    "service": "http://sonarr:8989"},
  {"hostname": "prowlarr.${CF_DOMAIN}",  "service": "http://prowlarr:9696"},
  {"hostname": "qbit.${CF_DOMAIN}",      "service": "http://qbittorrent:8080"},
  {"hostname": "bazarr.${CF_DOMAIN}",    "service": "http://bazarr:6767"},
  {"service": "http_status:404"}
]
ENDJSON
)

        PAYLOAD=$(python3 -c "
import json, sys
ingress = json.loads(sys.argv[1])
print(json.dumps({'config': {'ingress': ingress}}))
" "$INGRESS")

        # Fetch current config to check if update is needed
        CURRENT=$(curl -s "${cf_headers[@]}" \
            "$CF_API/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$CF_TUNNEL_ID/configurations" 2>/dev/null)
        CURRENT_SUCCESS=$(echo "$CURRENT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('success', False))" 2>/dev/null)

        if [[ "$CURRENT_SUCCESS" == "True" ]]; then
            # Compare current ingress hostnames with desired
            CURRENT_HOSTS=$(echo "$CURRENT" | python3 -c "
import json, sys
cfg = json.load(sys.stdin)
ingress = cfg.get('result', {}).get('config', {}).get('ingress', [])
hosts = sorted([r.get('hostname','') for r in ingress if r.get('hostname')])
print(','.join(hosts))
" 2>/dev/null)
            DESIRED_HOSTS=$(echo "$INGRESS" | python3 -c "
import json, sys
ingress = json.load(sys.stdin)
hosts = sorted([r.get('hostname','') for r in ingress if r.get('hostname')])
print(','.join(hosts))
" 2>/dev/null)

            if [[ "$CURRENT_HOSTS" == "$DESIRED_HOSTS" ]]; then
                ok "Tunnel hostnames already configured (${CF_DOMAIN})"
            else
                # Apply the configuration
                RESP=$(curl -s -X PUT "${cf_headers[@]}" \
                    "$CF_API/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$CF_TUNNEL_ID/configurations" \
                    -d "$PAYLOAD" 2>/dev/null)
                RESP_OK=$(echo "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('success', False))" 2>/dev/null)
                if [[ "$RESP_OK" == "True" ]]; then
                    ok "Tunnel hostnames configured for ${CF_DOMAIN}"
                else
                    RESP_ERR=$(echo "$RESP" | python3 -c "
import json, sys
errors = json.load(sys.stdin).get('errors', [])
print('; '.join(e.get('message','') for e in errors) if errors else 'unknown error')
" 2>/dev/null)
                    fail "Cloudflare API error: $RESP_ERR"
                fi
            fi
        else
            # Can't read current config — just apply
            RESP=$(curl -s -X PUT "${cf_headers[@]}" \
                "$CF_API/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$CF_TUNNEL_ID/configurations" \
                -d "$PAYLOAD" 2>/dev/null)
            RESP_OK=$(echo "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('success', False))" 2>/dev/null)
            if [[ "$RESP_OK" == "True" ]]; then
                ok "Tunnel hostnames configured for ${CF_DOMAIN}"
            else
                RESP_ERR=$(echo "$RESP" | python3 -c "
import json, sys
errors = json.load(sys.stdin).get('errors', [])
print('; '.join(e.get('message','') for e in errors) if errors else 'unknown error')
" 2>/dev/null)
                fail "Cloudflare API error: $RESP_ERR"
            fi
        fi

        # Create DNS CNAME records for each subdomain → tunnel
        CF_TUNNEL_CNAME="${CF_TUNNEL_ID}.cfargotunnel.com"

        # Get zone ID for the domain
        ZONE_RESP=$(curl -s "${cf_headers[@]}" \
            "$CF_API/zones?name=${CF_DOMAIN}" 2>/dev/null)
        CF_ZONE_ID=$(echo "$ZONE_RESP" | python3 -c "
import json, sys
data = json.load(sys.stdin)
zones = data.get('result', [])
print(zones[0]['id'] if zones else '')
" 2>/dev/null)

        if [[ -z "$CF_ZONE_ID" ]]; then
            fail "Could not find Cloudflare zone for ${CF_DOMAIN} — check CF_API_TOKEN permissions"
        else
            SUBDOMAINS=(jellyfin requests books homepage status radarr sonarr prowlarr qbit bazarr)
            DNS_CREATED=0
            DNS_EXISTED=0

            for SUB in "${SUBDOMAINS[@]}"; do
                FQDN="${SUB}.${CF_DOMAIN}"

                # Check if record already exists
                EXISTING=$(curl -s "${cf_headers[@]}" \
                    "$CF_API/zones/$CF_ZONE_ID/dns_records?type=CNAME&name=${FQDN}" 2>/dev/null)
                EXISTING_COUNT=$(echo "$EXISTING" | python3 -c "
import json, sys
print(len(json.load(sys.stdin).get('result', [])))
" 2>/dev/null)

                if [[ "$EXISTING_COUNT" -gt 0 ]]; then
                    DNS_EXISTED=$((DNS_EXISTED + 1))
                else
                    DNS_CREATE_RESP=$(curl -s -X POST "${cf_headers[@]}" \
                        "$CF_API/zones/$CF_ZONE_ID/dns_records" \
                        -d "{\"type\":\"CNAME\",\"name\":\"${SUB}\",\"content\":\"${CF_TUNNEL_CNAME}\",\"proxied\":true}" 2>/dev/null)
                    DNS_OK=$(echo "$DNS_CREATE_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('success', False))" 2>/dev/null)
                    if [[ "$DNS_OK" == "True" ]]; then
                        DNS_CREATED=$((DNS_CREATED + 1))
                    else
                        fail "Failed to create DNS record for ${FQDN}"
                    fi
                fi
            done

            if [[ $DNS_CREATED -gt 0 ]]; then
                ok "Created ${DNS_CREATED} DNS CNAME record(s)"
            fi
            if [[ $DNS_EXISTED -gt 0 ]]; then
                ok "${DNS_EXISTED} DNS record(s) already exist"
            fi
        fi
    fi
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
