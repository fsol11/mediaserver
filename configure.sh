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

# ── Normalize CF_DOMAIN to lowercase (DNS is case-insensitive) ────────────────
# Prevents Homepage host-validation failures when the domain is entered with
# mixed case (e.g. "Farshid.ca" → host header arrives as "farshid.ca").
if [[ -n "${CF_DOMAIN:-}" && "${CF_DOMAIN}" != "${CF_DOMAIN,,}" ]]; then
    set_env "CF_DOMAIN" "${CF_DOMAIN,,}"
    CF_DOMAIN="${CF_DOMAIN,,}"
    ok "CF_DOMAIN normalized to lowercase in .env: $CF_DOMAIN"
fi

# ── Map PREFERRED_QUALITY → Radarr/Sonarr profile name ────
case "${PREFERRED_QUALITY:-1080p}" in
    720p)       QP_PROFILE_NAME="HD-720p"  ;;
    4k|2160p)   QP_PROFILE_NAME="Ultra-HD" ;;
    *)          QP_PROFILE_NAME="HD-1080p" ;;  # default: 1080p
esac
# Terms to block in release titles (cam/screener quality)
CAM_IGNORE="CAM,TELESYNC,TELECINE,WORKPRINT,CAMRIP,HDCAM,DVDSCR,SCREENER,PDVD"

# ── Colours / helpers ──────────────────────────────────────
GRN='\033[0;32m'; YLW='\033[1;33m'; RED='\033[0;31m'; BLD='\033[1m'; NC='\033[0m'
ok()      { echo -e "  ${GRN}✓${NC}  $*"; }
skip()    { echo -e "  ${YLW}–${NC}  $*"; }
fail()    { echo -e "  ${RED}✗${NC}  $*"; ERROR_COUNT=$((ERROR_COUNT + 1)); ERRORS+=("$*"); }
section() { echo -e "\n${BLD}── $* ${NC}$(printf '─%.0s' $(seq 1 $((50 - ${#1}))))"; }
die()     { echo -e "${RED}FATAL:${NC} $*"; exit 1; }

# Check a key isn't still a placeholder
is_placeholder() { local v; v=$(grep -m1 "^${1}=" "$ENV_FILE" | cut -d= -f2-); [[ -z "$v" || "$v" == *"your_"* ]]; }

# Write a key=value into .env and update the current shell variable
set_env() { sed -i "s|^${1}=.*|${1}=${2}|" "$ENV_FILE"; export "${1}=${2}"; }

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
if ! is_placeholder "JELLYSEERR_API_KEY"; then
    wait_http "http://localhost:5055/api/v1/settings/public" "Jellyseerr" 120 || fail "Jellyseerr not responding — skipping its config"
fi

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
            if [[ "$cred_resp" == "200" ]]; then
                ok "Credentials updated to ${ADMIN_USER:-admin}"
                # Re-authenticate with the new credentials so the cookie stays valid
                login_resp=$(curl -sc "$QBIT_COOKIE" -X POST "http://localhost:8080/api/v2/auth/login" \
                    --data-urlencode "username=${ADMIN_USER:-admin}" \
                    --data-urlencode "password=${ADMIN_PASSWORD:-adminadmin}" 2>/dev/null)
                [[ "$login_resp" == "Ok." ]] || fail "Re-login with new credentials failed"
            else
                fail "Could not update credentials (HTTP $cred_resp)"
            fi
        fi
    fi
fi

if [[ "$qbit_logged_in" == true ]]; then
    # Bind qBittorrent to the VPN interface (tun0) so libtorrent sources ALL
    # peer/DHT traffic through Gluetun's WireGuard tunnel. Without this, libtorrent
    # binds to the Docker bridge (eth0/172.18.0.x); Gluetun's policy routing
    # (ip rule "from 172.18.0.2 lookup 200") then pushes that traffic out eth0,
    # where the kill switch drops it. Symptom: connection status "firewalled",
    # dht_nodes stuck at 0, and no torrents download despite the VPN being up.
    vpn_if=$(docker exec gluetun sh -c 'ip -o link show 2>/dev/null | grep -oE "tun[0-9]+|wg[0-9]+" | head -1')
    vpn_if=${vpn_if:-tun0}
    prefs_json=$(python3 -c "
import json, sys
print(json.dumps({
    'save_path': '/downloads',
    'temp_path': '/downloads/incomplete',
    'temp_path_enabled': True,
    'incomplete_files_ext': True,
    'current_network_interface': sys.argv[1],
    'current_interface_address': ''
}))" "$vpn_if")
    prefs_resp=$(curl -s -o /dev/null -w "%{http_code}" -b "$QBIT_COOKIE" \
        -X POST "http://localhost:8080/api/v2/app/setPreferences" \
        --data-urlencode "json=$prefs_json")
    [[ "$prefs_resp" == "200" ]] \
        && ok "Save path set to /downloads; bound to VPN interface ($vpn_if)" \
        || fail "Could not set preferences (HTTP $prefs_resp)"
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
    # Client exists — always sync credentials so they stay consistent with .env
    _dc_id=$(body "$resp" | python3 -c "
import json,sys
items=json.load(sys.stdin)
m=next((i for i in items if i.get('implementation','').lower()=='qbittorrent'),None)
print(m['id'] if m else '')" 2>/dev/null || echo "")
    if [[ -n "$_dc_id" ]]; then
        _dc_body=$(curl -sf "$RADARR_BASE/api/v3/downloadclient/$_dc_id" -H "X-Api-Key: $RADARR_KEY" 2>/dev/null)
        _dc_updated=$(echo "$_dc_body" | python3 -c "
import json,sys
c=json.load(sys.stdin); u,pw=sys.argv[1],sys.argv[2]
for f in c['fields']:
    if f['name']=='username': f['value']=u
    if f['name']=='password': f['value']=pw
print(json.dumps(c))" "${ADMIN_USER:-admin}" "${ADMIN_PASSWORD:-adminadmin}" 2>/dev/null)
        _dc_resp=$(echo "$_dc_updated" | curl -s -o /dev/null -w "%{http_code}" -X PUT \
            "$RADARR_BASE/api/v3/downloadclient/$_dc_id" \
            -H "X-Api-Key: $RADARR_KEY" -H "Content-Type: application/json" -d @-)
        [[ "$_dc_resp" =~ ^2 ]] && ok "qBittorrent credentials synced in Radarr" \
            || fail "Failed to sync qBittorrent credentials in Radarr (HTTP $_dc_resp)"
    else
        skip "qBittorrent already configured in Radarr (could not get ID)"
    fi
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
    {"name": "host",                 "value": "gluetun"},
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

# 3c. Authentication — always sync credentials so .env changes take effect
if [[ -n "${ADMIN_USER:-}" && -n "${ADMIN_PASSWORD:-}" ]]; then
    host_resp=$(arr_get "$RADARR_BASE/api/v3/config/host" "$RADARR_KEY")
    host_body=$(body "$host_resp")
    host_id=$(echo "$host_body" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',1))" 2>/dev/null || echo "1")
    _cur_user=$(echo "$host_body" | python3 -c "import json,sys; print(json.load(sys.stdin).get('username',''))" 2>/dev/null)
    _cur_method=$(echo "$host_body" | python3 -c "import json,sys; print(json.load(sys.stdin).get('authenticationMethod','none'))" 2>/dev/null)
    # Always PUT to keep credentials in sync; passwordConfirmation triggers a hash update
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
    ok_code "$resp" && ok "Authentication synced (${ADMIN_USER})" \
        || fail "Failed to set authentication (HTTP $(code "$resp")): $(body "$resp")"
fi

# 3d. Quality profile — apply only when PREFERRED_QUALITY is set and all movies are still
# on the default 'Any' profile (i.e. never customised via the UI).
if [[ -z "${PREFERRED_QUALITY:-}" ]]; then
    skip "PREFERRED_QUALITY not set — skipping Radarr quality profile"
else
    _radarr_qp_body=$(body "$(arr_get "$RADARR_BASE/api/v3/qualityprofile" "$RADARR_KEY")")
    _qp_id=$(echo "$_radarr_qp_body" | python3 -c "
import json,sys
ps=json.load(sys.stdin)
p=next((x for x in ps if x['name']=='${QP_PROFILE_NAME}'), None)
print(p['id'] if p else '')" 2>/dev/null)
    _any_id=$(echo "$_radarr_qp_body" | python3 -c "
import json,sys
ps=json.load(sys.stdin)
p=next((x for x in ps if x['name']=='Any'), None)
print(p['id'] if p else '0')" 2>/dev/null)
    if [[ -z "$_qp_id" ]]; then
        skip "Quality profile '${QP_PROFILE_NAME}' not found in Radarr — skipping"
    else
        _radarr_movies_body=$(body "$(arr_get "$RADARR_BASE/api/v3/movie" "$RADARR_KEY")")
        _all_on_default=$(echo "$_radarr_movies_body" | python3 -c "
import json,sys
ms=json.load(sys.stdin)
any_id=int('${_any_id:-0}' or 0)
print('yes' if all(m.get('qualityProfileId')==any_id for m in ms) else 'no')" 2>/dev/null)
        if [[ "$_all_on_default" != "yes" ]]; then
            skip "Radarr quality profiles already customised — skipping to preserve UI changes"
        else
            _movie_ids=$(echo "$_radarr_movies_body" | python3 -c "
import json,sys
ms=json.load(sys.stdin)
print(' '.join(str(m['id']) for m in ms))" 2>/dev/null)
            if [[ -z "$_movie_ids" ]]; then
                skip "No movies in Radarr yet — nothing to update"
            else
                _ids_json=$(echo "$_movie_ids" | python3 -c "import sys; print('['+','.join(sys.stdin.read().split())+']')")
                resp=$(arr_put "$RADARR_BASE/api/v3/movie/editor" "$RADARR_KEY" \
                    "{\"movieIds\":${_ids_json},\"qualityProfileId\":${_qp_id}}")
                ok_code "$resp" && ok "Radarr: quality profile set to '${QP_PROFILE_NAME}' for all movies" \
                    || fail "Failed to update Radarr quality profile (HTTP $(code "$resp"))"
            fi
        fi
    fi
fi

# 3e. Block cam/pre-release sources via Custom Format (Radarr v3)
_cf_resp=$(arr_get "$RADARR_BASE/api/v3/customformat" "$RADARR_KEY")
if body "$_cf_resp" | python3 -c "
import json,sys
items=json.load(sys.stdin)
print('found' if any(i.get('name')=='Cam/Screener' for i in items) else 'missing')
" 2>/dev/null | grep -q "found"; then
    skip "Cam/Screener custom format already in Radarr"
else
    _cf_payload=$(cat <<'CFEOF'
{
  "name": "Cam/Screener",
  "includeCustomFormatWhenRenaming": false,
  "specifications": [{
    "name": "Cam/Screener Patterns",
    "implementation": "ReleaseTitleSpecification",
    "negate": false,
    "required": false,
    "fields": [{"name": "value", "value": "(?i)\\b(CAM|CAMRIP|HDCAM|TELESYNC|TELECINE|WORKPRINT|DVDSCR|SCREENER|PDVD)\\b"}]
  }]
}
CFEOF
)
    _cf_create=$(arr_post "$RADARR_BASE/api/v3/customformat" "$RADARR_KEY" "$_cf_payload")
    if ok_code "$_cf_create"; then
        _cf_id=$(body "$_cf_create" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])" 2>/dev/null)
        # Apply score of -9999 to this CF on the quality profile
        _prof_resp=$(arr_get "$RADARR_BASE/api/v3/qualityprofile/${_qp_id:-4}" "$RADARR_KEY")
        _updated_prof=$(body "$_prof_resp" | python3 -c "
import json,sys
p=json.load(sys.stdin)
p['formatItems'].append({'format': ${_cf_id:-0}, 'name': 'Cam/Screener', 'score': -9999})
print(json.dumps(p))" 2>/dev/null)
        if [[ -n "$_updated_prof" && -n "${_cf_id:-}" ]]; then
            arr_put "$RADARR_BASE/api/v3/qualityprofile/${_qp_id:-4}" "$RADARR_KEY" "$_updated_prof" >/dev/null
        fi
        ok "Radarr: Cam/Screener custom format added (score -9999 on ${QP_PROFILE_NAME})"
    else
        fail "Failed to add Radarr custom format (HTTP $(code "$_cf_create")): $(body "$_cf_create")"
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
    # Client exists — always sync credentials so they stay consistent with .env
    _dc_id=$(body "$resp" | python3 -c "
import json,sys
items=json.load(sys.stdin)
m=next((i for i in items if i.get('implementation','').lower()=='qbittorrent'),None)
print(m['id'] if m else '')" 2>/dev/null || echo "")
    if [[ -n "$_dc_id" ]]; then
        _dc_body=$(curl -sf "$SONARR_BASE/api/v3/downloadclient/$_dc_id" -H "X-Api-Key: $SONARR_KEY" 2>/dev/null)
        _dc_updated=$(echo "$_dc_body" | python3 -c "
import json,sys
c=json.load(sys.stdin); u,pw=sys.argv[1],sys.argv[2]
for f in c['fields']:
    if f['name']=='username': f['value']=u
    if f['name']=='password': f['value']=pw
print(json.dumps(c))" "${ADMIN_USER:-admin}" "${ADMIN_PASSWORD:-adminadmin}" 2>/dev/null)
        _dc_resp=$(echo "$_dc_updated" | curl -s -o /dev/null -w "%{http_code}" -X PUT \
            "$SONARR_BASE/api/v3/downloadclient/$_dc_id" \
            -H "X-Api-Key: $SONARR_KEY" -H "Content-Type: application/json" -d @-)
        [[ "$_dc_resp" =~ ^2 ]] && ok "qBittorrent credentials synced in Sonarr" \
            || fail "Failed to sync qBittorrent credentials in Sonarr (HTTP $_dc_resp)"
    else
        skip "qBittorrent already configured in Sonarr (could not get ID)"
    fi
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
    {"name": "host",               "value": "gluetun"},
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

# 4c. Authentication — always sync credentials so .env changes take effect
if [[ -n "${ADMIN_USER:-}" && -n "${ADMIN_PASSWORD:-}" ]]; then
    host_resp=$(arr_get "$SONARR_BASE/api/v3/config/host" "$SONARR_KEY")
    host_body=$(body "$host_resp")
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
    ok_code "$resp" && ok "Authentication synced (${ADMIN_USER})" \
        || fail "Failed to set authentication (HTTP $(code "$resp")): $(body "$resp")"
fi

# 4d. Quality profile — apply only when PREFERRED_QUALITY is set and all series are still
# on the default 'Any' profile (i.e. never customised via the UI).
if [[ -z "${PREFERRED_QUALITY:-}" ]]; then
    skip "PREFERRED_QUALITY not set — skipping Sonarr quality profile"
else
    _sonarr_qp_body=$(body "$(arr_get "$SONARR_BASE/api/v3/qualityprofile" "$SONARR_KEY")")
    _sqp_id=$(echo "$_sonarr_qp_body" | python3 -c "
import json,sys
ps=json.load(sys.stdin)
p=next((x for x in ps if x['name']=='${QP_PROFILE_NAME}'), None)
print(p['id'] if p else '')" 2>/dev/null)
    _sany_id=$(echo "$_sonarr_qp_body" | python3 -c "
import json,sys
ps=json.load(sys.stdin)
p=next((x for x in ps if x['name']=='Any'), None)
print(p['id'] if p else '0')" 2>/dev/null)
    if [[ -z "$_sqp_id" ]]; then
        skip "Quality profile '${QP_PROFILE_NAME}' not found in Sonarr — skipping"
    else
        _sonarr_series_body=$(body "$(arr_get "$SONARR_BASE/api/v3/series" "$SONARR_KEY")")
        _sall_on_default=$(echo "$_sonarr_series_body" | python3 -c "
import json,sys
ss=json.load(sys.stdin)
any_id=int('${_sany_id:-0}' or 0)
print('yes' if all(s.get('qualityProfileId')==any_id for s in ss) else 'no')" 2>/dev/null)
        if [[ "$_sall_on_default" != "yes" ]]; then
            skip "Sonarr quality profiles already customised — skipping to preserve UI changes"
        else
            _series_ids=$(echo "$_sonarr_series_body" | python3 -c "
import json,sys
ss=json.load(sys.stdin)
print(' '.join(str(s['id']) for s in ss))" 2>/dev/null)
            if [[ -z "$_series_ids" ]]; then
                skip "No series in Sonarr yet — nothing to update"
            else
                _sids_json=$(echo "$_series_ids" | python3 -c "import sys; print('['+','.join(sys.stdin.read().split())+']')")
                resp=$(arr_put "$SONARR_BASE/api/v3/series/editor" "$SONARR_KEY" \
                    "{\"seriesIds\":${_sids_json},\"qualityProfileId\":${_sqp_id}}")
                ok_code "$resp" && ok "Sonarr: quality profile set to '${QP_PROFILE_NAME}' for all series" \
                    || fail "Failed to update Sonarr quality profile (HTTP $(code "$resp"))"
            fi
        fi
    fi
fi

# 4e. Block cam/pre-release sources via release profile
_relp_resp=$(arr_get "$SONARR_BASE/api/v3/releaseprofile" "$SONARR_KEY")
if body "$_relp_resp" | python3 -c "
import json,sys
items=json.load(sys.stdin)
print('found' if any('CAM' in (i.get('ignored') or []) for i in items) else 'missing')
" 2>/dev/null | grep -q "found"; then
    skip "Cam/screener release profile already in Sonarr"
else
    _cam_arr=$(echo "$CAM_IGNORE" | python3 -c "import sys; vals=sys.stdin.read().split(','); print('['+','.join('\"'+v.strip()+'\"' for v in vals)+']')")
    resp=$(arr_post "$SONARR_BASE/api/v3/releaseprofile" "$SONARR_KEY" \
        "{\"name\":\"Block Cam/Screener\",\"enabled\":true,\"required\":[],\"ignored\":${_cam_arr},\"indexerId\":0,\"tags\":[]}")
    ok_code "$resp" && ok "Sonarr: cam/screener release profile added" \
        || fail "Failed to add Sonarr release profile (HTTP $(code "$resp")): $(body "$resp")"
fi

# 4f. Jellyfin auto-refresh notification (MediaBrowser)
section "Jellyfin Auto-Refresh"

if is_placeholder "JELLYFIN_API_KEY"; then
    skip "JELLYFIN_API_KEY not set — skipping Sonarr/Radarr -> Jellyfin auto-refresh hooks"
else
    wait_http "http://localhost:8096/health" "Jellyfin" 60 \
        || fail "Jellyfin not responding — cannot configure auto-refresh hooks"

    ensure_jellyfin_hook() {
        local app_name="$1" base="$2" key="$3" kind="$4"
        local list_resp list_body notif_id current_json payload resp

        list_resp=$(arr_get "$base/api/v3/notification" "$key")
        list_body=$(body "$list_resp")

        notif_id=$(echo "$list_body" | python3 -c "
import json,sys
try:
    items=json.load(sys.stdin)
    m=next((i for i in items if str(i.get('implementation','')).lower()=='mediabrowser'), None)
    print(m.get('id','') if m else '')
except Exception:
    print('')
" 2>/dev/null)

        if [[ -n "$notif_id" ]]; then
            current_json=$(curl -sf "$base/api/v3/notification/$notif_id" -H "X-Api-Key: $key" 2>/dev/null)
            payload=$(echo "$current_json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
kind=sys.argv[1]

d['name']='Jellyfin'
d['implementation']='MediaBrowser'
d['implementationName']='Emby / Jellyfin'
d['configContract']='MediaBrowserSettings'
d['tags']=d.get('tags', [])

# Keep Jellyfin-compatible behavior.
d['onGrab']=False
d['onDownload']=True
d['onUpgrade']=True
d['onRename']=True
d['onHealthIssue']=False
d['includeHealthWarnings']=False
d['onHealthRestored']=False
d['onApplicationUpdate']=False
d['onManualInteractionRequired']=False

if kind=='sonarr':
    d['onImportComplete']=True
    d['onSeriesAdd']=False
    d['onSeriesDelete']=False
    d['onEpisodeFileDelete']=False
    d['onEpisodeFileDeleteForUpgrade']=False
elif kind=='radarr':
    d['onMovieAdded']=False
    d['onMovieDelete']=False
    d['onMovieFileDelete']=False
    d['onMovieFileDeleteForUpgrade']=False

fields={f.get('name'):f for f in d.get('fields', []) if isinstance(f, dict) and f.get('name')}
def set_field(name, value):
    if name in fields:
        fields[name]['value']=value
    else:
        fields[name]={'name':name,'value':value}

set_field('host','jellyfin')
set_field('port',8096)
set_field('useSsl',False)
set_field('urlBase','')
set_field('apiKey',sys.argv[2])
set_field('notify',False)
set_field('updateLibrary',True)
set_field('mapFrom','')
set_field('mapTo','')

d['fields']=list(fields.values())
print(json.dumps(d))
" "$kind" "$JELLYFIN_API_KEY" 2>/dev/null)

            resp=$(arr_put "$base/api/v3/notification/$notif_id" "$key" "$payload")
            if ok_code "$resp"; then
                ok "$app_name -> Jellyfin auto-refresh hook synced"
            else
                fail "Failed to sync $app_name -> Jellyfin hook (HTTP $(code "$resp")): $(body "$resp")"
            fi
        else
            if [[ "$kind" == "sonarr" ]]; then
                payload=$(cat <<JSON
{
  "name": "Jellyfin",
  "implementation": "MediaBrowser",
  "implementationName": "Emby / Jellyfin",
  "configContract": "MediaBrowserSettings",
  "onGrab": false,
  "onDownload": true,
  "onUpgrade": true,
  "onImportComplete": true,
  "onRename": true,
  "onSeriesAdd": false,
  "onSeriesDelete": false,
  "onEpisodeFileDelete": false,
  "onEpisodeFileDeleteForUpgrade": false,
  "onHealthIssue": false,
  "includeHealthWarnings": false,
  "onHealthRestored": false,
  "onApplicationUpdate": false,
  "onManualInteractionRequired": false,
  "fields": [
    {"name": "host", "value": "jellyfin"},
    {"name": "port", "value": 8096},
    {"name": "useSsl", "value": false},
    {"name": "urlBase", "value": ""},
    {"name": "apiKey", "value": "${JELLYFIN_API_KEY}"},
    {"name": "notify", "value": false},
    {"name": "updateLibrary", "value": true},
    {"name": "mapFrom", "value": ""},
    {"name": "mapTo", "value": ""}
  ],
  "tags": []
}
JSON
)
            else
                payload=$(cat <<JSON
{
  "name": "Jellyfin",
  "implementation": "MediaBrowser",
  "implementationName": "Emby / Jellyfin",
  "configContract": "MediaBrowserSettings",
  "onGrab": false,
  "onDownload": true,
  "onUpgrade": true,
  "onRename": true,
  "onMovieAdded": false,
  "onMovieDelete": false,
  "onMovieFileDelete": false,
  "onMovieFileDeleteForUpgrade": false,
  "onHealthIssue": false,
  "includeHealthWarnings": false,
  "onHealthRestored": false,
  "onApplicationUpdate": false,
  "onManualInteractionRequired": false,
  "fields": [
    {"name": "host", "value": "jellyfin"},
    {"name": "port", "value": 8096},
    {"name": "useSsl", "value": false},
    {"name": "urlBase", "value": ""},
    {"name": "apiKey", "value": "${JELLYFIN_API_KEY}"},
    {"name": "notify", "value": false},
    {"name": "updateLibrary", "value": true},
    {"name": "mapFrom", "value": ""},
    {"name": "mapTo", "value": ""}
  ],
  "tags": []
}
JSON
)
            fi

            resp=$(arr_post "$base/api/v3/notification" "$key" "$payload")
            if ok_code "$resp"; then
                ok "$app_name -> Jellyfin auto-refresh hook created"
            elif is_already_exists "$(body "$resp")"; then
                skip "$app_name -> Jellyfin auto-refresh hook already configured"
            else
                fail "Failed to create $app_name -> Jellyfin hook (HTTP $(code "$resp")): $(body "$resp")"
            fi
        fi
    }

    ensure_jellyfin_hook "Radarr" "$RADARR_BASE" "$RADARR_KEY" "radarr"
    ensure_jellyfin_hook "Sonarr" "$SONARR_BASE" "$SONARR_KEY" "sonarr"
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

# 5d. Authentication — always sync credentials so .env changes take effect
if [[ -n "${ADMIN_USER:-}" && -n "${ADMIN_PASSWORD:-}" ]]; then
    host_resp=$(arr_get "$PROWLARR_BASE/api/v1/config/host" "$PROWLARR_KEY")
    host_body=$(body "$host_resp")
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
    resp=$(arr_put "$PROWLARR_BASE/api/v1/config/host/$host_id" "$PROWLARR_KEY" "$auth_payload")
    ok_code "$resp" && ok "Authentication synced (${ADMIN_USER})" \
        || fail "Failed to set authentication (HTTP $(code "$resp")): $(body "$resp")"
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
# Bazarr settings API uses form-encoded POST (not JSON).
# Field names follow the pattern: settings-{section}-{key}
# "enabled" is not a field; connection is active when use_radarr/use_sonarr=true and apikey is set.
current=$(http GET "$BAZARR_BASE/api/system/settings" -H "X-API-KEY: $BAZARR_KEY")

radarr_configured=$(body "$current" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    use=d.get('general',{}).get('use_radarr', False)
    key=d.get('radarr',{}).get('apikey','')
    print('true' if use and key else 'false')
except: print('false')
" 2>/dev/null)

sonarr_configured=$(body "$current" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    use=d.get('general',{}).get('use_sonarr', False)
    key=d.get('sonarr',{}).get('apikey','')
    print('true' if use and key else 'false')
except: print('false')
" 2>/dev/null)

if [[ "$radarr_configured" == "true" ]]; then
    skip "Radarr already connected in Bazarr"
else
    resp=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 -X POST "$BAZARR_BASE/api/system/settings" \
        -H "X-API-KEY: $BAZARR_KEY" \
        --data-urlencode "settings-general-use_radarr=true" \
        --data-urlencode "settings-radarr-ip=radarr" \
        --data-urlencode "settings-radarr-port=7878" \
        --data-urlencode "settings-radarr-apikey=${RADARR_API_KEY}" \
        --data-urlencode "settings-radarr-ssl=false" \
        --data-urlencode "settings-radarr-base_url=/")
    [[ "$resp" =~ ^2 ]] && ok "Radarr connected in Bazarr" \
        || fail "Failed to connect Radarr in Bazarr (HTTP $resp)"
fi

if [[ "$sonarr_configured" == "true" ]]; then
    skip "Sonarr already connected in Bazarr"
else
    resp=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 -X POST "$BAZARR_BASE/api/system/settings" \
        -H "X-API-KEY: $BAZARR_KEY" \
        --data-urlencode "settings-general-use_sonarr=true" \
        --data-urlencode "settings-sonarr-ip=sonarr" \
        --data-urlencode "settings-sonarr-port=8989" \
        --data-urlencode "settings-sonarr-apikey=${SONARR_API_KEY}" \
        --data-urlencode "settings-sonarr-ssl=false" \
        --data-urlencode "settings-sonarr-base_url=/")
    [[ "$resp" =~ ^2 ]] && ok "Sonarr connected in Bazarr" \
        || fail "Failed to connect Sonarr in Bazarr (HTTP $resp)"
fi

# 6c. Authentication — must be set directly in config.yaml (API ignores auth writes)
if [[ -n "${ADMIN_USER:-}" && -n "${ADMIN_PASSWORD:-}" ]]; then
    BAZARR_CFG_AUTH="$STACK_DIR/config/bazarr/config/config.yaml"
    [[ ! -f "$BAZARR_CFG_AUTH" ]] && BAZARR_CFG_AUTH="$STACK_DIR/config/bazarr/config.yaml"
    if [[ -f "$BAZARR_CFG_AUTH" ]]; then
        bazarr_auth_type=$(grep -A4 '^auth:' "$BAZARR_CFG_AUTH" | grep 'type:' | awk '{print $2}')
        if [[ -n "$bazarr_auth_type" && "$bazarr_auth_type" != "null" ]]; then
            skip "Authentication already enabled in Bazarr"
        else
            # Bazarr stores the password as MD5
            bazarr_pw_hash=$(python3 -c "import hashlib; print(hashlib.md5('${ADMIN_PASSWORD}'.encode()).hexdigest())")
            sed -i "s/^  type: null/  type: form/" "$BAZARR_CFG_AUTH"
            sed -i "/^auth:/,/^[^ ]/{s/^  username: .*/  username: ${ADMIN_USER}/; s/^  password: .*/  password: ${bazarr_pw_hash}/}" "$BAZARR_CFG_AUTH"
            docker restart bazarr &>/dev/null
            ok "Authentication enabled (${ADMIN_USER}) — Bazarr restarting"
        fi
    else
        fail "Bazarr config.yaml not found — cannot set authentication"
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
    p=next((x for x in ps if x['name']=='${QP_PROFILE_NAME}'), \
       next((x for x in ps if x['name']=='Any'), ps[0] if ps else None))
    print(p['id'] if p else 1)
except: print(1)
" 2>/dev/null)
        radarr_profile_name=$(body "$radarr_profiles" | python3 -c "
import json,sys
try:
    ps=json.load(sys.stdin)
    p=next((x for x in ps if x['name']=='${QP_PROFILE_NAME}'), \
       next((x for x in ps if x['name']=='Any'), ps[0] if ps else None))
    print(p['name'] if p else '${QP_PROFILE_NAME}')
except: print('${QP_PROFILE_NAME}')
" 2>/dev/null)

        # Get Sonarr quality profiles
        sonarr_profiles=$(arr_get "http://localhost:8989/api/v3/qualityprofile" "$SONARR_API_KEY")
        sonarr_profile_id=$(body "$sonarr_profiles" | python3 -c "
import json,sys
try:
    ps=json.load(sys.stdin)
    p=next((x for x in ps if x['name']=='${QP_PROFILE_NAME}'), \
       next((x for x in ps if x['name']=='Any'), ps[0] if ps else None))
    print(p['id'] if p else 1)
except: print(1)
" 2>/dev/null)
        sonarr_profile_name=$(body "$sonarr_profiles" | python3 -c "
import json,sys
try:
    ps=json.load(sys.stdin)
    p=next((x for x in ps if x['name']=='${QP_PROFILE_NAME}'), \
       next((x for x in ps if x['name']=='Any'), ps[0] if ps else None))
    print(p['name'] if p else '${QP_PROFILE_NAME}')
except: print('${QP_PROFILE_NAME}')
" 2>/dev/null)

        # Check existing Radarr servers
        existing_radarr=$(http GET "$JS_BASE/api/v1/settings/radarr" -H "X-Api-Key: $JS_KEY")
        _radarr_existing_id=$(body "$existing_radarr" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" 2>/dev/null)
        if [[ -n "$_radarr_existing_id" ]]; then
            # Already exists — ensure syncEnabled is true
            _radarr_sync=$(body "$existing_radarr" | python3 -c "import json,sys; d=json.load(sys.stdin); print(str(d[0].get('syncEnabled',False)).lower() if d else 'false')" 2>/dev/null)
            if [[ "$_radarr_sync" == "true" ]]; then
                skip "Radarr already configured in Jellyseerr (sync enabled)"
            else
                _radarr_patch=$(body "$existing_radarr" | python3 -c "import json,sys; d=json.load(sys.stdin); d[0]['syncEnabled']=True; print(json.dumps(d[0]))" 2>/dev/null)
                _resp=$(echo "$_radarr_patch" | curl -s -o /dev/null -w "%{http_code}" -X PUT "$JS_BASE/api/v1/settings/radarr/$_radarr_existing_id" \
                    -H "X-Api-Key: $JS_KEY" -H "Content-Type: application/json" -d @-)
                [[ "$_resp" =~ ^2 ]] && ok "Radarr sync enabled in Jellyseerr" \
                    || fail "Failed to enable Radarr sync (HTTP $_resp)"
            fi
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
  "syncEnabled": true,
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
        _sonarr_existing_id=$(body "$existing_sonarr" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" 2>/dev/null)
        if [[ -n "$_sonarr_existing_id" ]]; then
            # Already exists — ensure syncEnabled is true
            _sonarr_sync=$(body "$existing_sonarr" | python3 -c "import json,sys; d=json.load(sys.stdin); print(str(d[0].get('syncEnabled',False)).lower() if d else 'false')" 2>/dev/null)
            if [[ "$_sonarr_sync" == "true" ]]; then
                skip "Sonarr already configured in Jellyseerr (sync enabled)"
            else
                _sonarr_patch=$(body "$existing_sonarr" | python3 -c "import json,sys; d=json.load(sys.stdin); d[0]['syncEnabled']=True; print(json.dumps(d[0]))" 2>/dev/null)
                _resp=$(echo "$_sonarr_patch" | curl -s -o /dev/null -w "%{http_code}" -X PUT "$JS_BASE/api/v1/settings/sonarr/$_sonarr_existing_id" \
                    -H "X-Api-Key: $JS_KEY" -H "Content-Type: application/json" -d @-)
                [[ "$_resp" =~ ^2 ]] && ok "Sonarr sync enabled in Jellyseerr" \
                    || fail "Failed to enable Sonarr sync (HTTP $_resp)"
            fi
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
  "syncEnabled": true,
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

        # ── Jellyfin library sync ─────────────────────────────────────
        # Enable all Jellyfin libraries in Jellyseerr so existing media
        # is flagged as "Available" rather than requestable again.
        lib_resp=$(http GET "$JS_BASE/api/v1/settings/jellyfin/library?sync=true" -H "X-Api-Key: $JS_KEY")
        all_enabled=$(body "$lib_resp" | python3 -c "
import json,sys
try:
    libs = json.load(sys.stdin)
    print('true' if libs and all(l.get('enabled') for l in libs) else 'false')
except: print('false')
" 2>/dev/null)

        if [[ "$all_enabled" == "true" ]]; then
            skip "Jellyseerr Jellyfin libraries already enabled"
        else
            # Build comma-separated list of all library IDs
            lib_ids=$(body "$lib_resp" | python3 -c "
import json,sys
try:
    libs = json.load(sys.stdin)
    print(','.join(l['id'] for l in libs))
except: print('')
" 2>/dev/null)

            if [[ -z "$lib_ids" ]]; then
                fail "No Jellyfin libraries found — ensure Jellyfin has libraries configured"
            else
                enable_resp=$(http GET "$JS_BASE/api/v1/settings/jellyfin/library?sync=true&enable=${lib_ids}" \
                    -H "X-Api-Key: $JS_KEY")
                if ok_code "$enable_resp"; then
                    ok "Jellyseerr Jellyfin libraries enabled"
                    # Trigger a full scan so existing media is marked Available
                    scan_resp=$(http POST "$JS_BASE/api/v1/settings/jellyfin/sync" \
                        -H "X-Api-Key: $JS_KEY" \
                        -H "Content-Type: application/json" \
                        -d '{"start":true}')
                    ok_code "$scan_resp" && ok "Jellyseerr full library scan started" \
                        || fail "Failed to start library scan (HTTP $(code "$scan_resp"))"
                else
                    fail "Failed to enable Jellyfin libraries (HTTP $(code "$enable_resp"))"
                fi
            fi
        fi

        # ── Auto-approve permissions ──────────────────────────────────
        # Jellyseerr permission bits: REQUEST=16, AUTO_APPROVE=64, AUTO_APPROVE_TV=2048
        # Without AUTO_APPROVE, requests sit in PENDING and never reach Radarr/Sonarr.
        _auto_approve_bits=$(( 16 | 64 | 2048 ))   # = 2128

        # 1. Update default permissions for new users
        _main_settings=$(http GET "$JS_BASE/api/v1/settings/main" -H "X-Api-Key: $JS_KEY")
        _cur_default=$(body "$_main_settings" | python3 -c "import json,sys; print(json.load(sys.stdin).get('defaultPermissions',0))" 2>/dev/null)
        if (( (_cur_default & _auto_approve_bits) == _auto_approve_bits )); then
            skip "Jellyseerr default permissions already include auto-approve"
        else
            _new_default=$(( _cur_default | _auto_approve_bits ))
            _resp=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$JS_BASE/api/v1/settings/main" \
                -H "X-Api-Key: $JS_KEY" -H "Content-Type: application/json" \
                -d "{\"defaultPermissions\":$_new_default}")
            [[ "$_resp" =~ ^2 ]] && ok "Jellyseerr default permissions set to include auto-approve" \
                || fail "Failed to update default permissions (HTTP $_resp)"
        fi

        # 2. Grant auto-approve to all existing non-admin users
        _users=$(http GET "$JS_BASE/api/v1/user?take=100&skip=0" -H "X-Api-Key: $JS_KEY")
        body "$_users" | python3 -c "
import json,sys
d=json.load(sys.stdin)
bits=$_auto_approve_bits
for u in d.get('results',[]):
    p=u.get('permissions',0)
    if p & 2:  # ADMIN bit — skip
        continue
    if (p & bits) != bits:
        print(u['id'])
" 2>/dev/null | while read -r _uid; do
            _udata=$(http GET "$JS_BASE/api/v1/user/$_uid" -H "X-Api-Key: $JS_KEY")
            _upatched=$(body "$_udata" | python3 -c "
import json,sys
d=json.load(sys.stdin)
d['permissions']=d.get('permissions',0)|$_auto_approve_bits
print(json.dumps(d))" 2>/dev/null)
            _uresp=$(echo "$_upatched" | curl -s -o /dev/null -w "%{http_code}" -X PUT "$JS_BASE/api/v1/user/$_uid" \
                -H "X-Api-Key: $JS_KEY" -H "Content-Type: application/json" -d @-)
            [[ "$_uresp" =~ ^2 ]] && ok "Auto-approve granted to user id $_uid" \
                || fail "Failed to update user $_uid (HTTP $_uresp)"
        done

        # 3. Approve any requests still in PENDING state
        _pending=$(http GET "$JS_BASE/api/v1/request?take=100&skip=0&filter=pending" -H "X-Api-Key: $JS_KEY")
        _pending_ids=$(body "$_pending" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ids=[str(r['id']) for r in d.get('results',[]) if r.get('status')==1]
print(' '.join(ids))" 2>/dev/null)
        if [[ -z "$_pending_ids" ]]; then
            skip "No pending requests to approve"
        else
            for _rid in $_pending_ids; do
                _rresp=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$JS_BASE/api/v1/request/$_rid/approve" \
                    -H "X-Api-Key: $JS_KEY" -H "Content-Type: application/json")
                [[ "$_rresp" =~ ^2 ]] && ok "Approved request $_rid" \
                    || fail "Failed to approve request $_rid (HTTP $_rresp)"
            done
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
# 8b. JELLYFIN — Transcoding (NVIDIA GPU + remote bitrate limit)
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

    # Set server-wide remote client bitrate from JELLYFIN_MAX_BITRATE (Mbps; 0 = unlimited).
    # Applied only when the env value is non-zero and Jellyfin still has the default (0 = unlimited),
    # so any value set via the UI is never overwritten.
    DESIRED_BITRATE=$(( ${JELLYFIN_MAX_BITRATE:-0} * 1000000 ))
    # Wait for Jellyfin config API to be fully ready (health endpoint responds before API is initialized)
    _jf_api_wait=0
    current_config=""
    while (( _jf_api_wait < 120 )); do
        current_config=$(curl -sf "$JF_BASE/System/Configuration" -H "$JF_AUTH" 2>/dev/null)
        [[ -n "$current_config" ]] && break
        sleep 3; _jf_api_wait=$((_jf_api_wait + 3))
    done
    current_bitrate=$(echo "$current_config" | python3 -c "import json,sys; print(json.load(sys.stdin).get('RemoteClientBitrateLimit',0))" 2>/dev/null || echo "0")

    if [[ -z "${JELLYFIN_MAX_BITRATE:-}" ]]; then
        skip "JELLYFIN_MAX_BITRATE not set — remote bitrate limit not configured"
    elif [[ "$current_bitrate" != "0" ]]; then
        skip "Remote client bitrate already set ($(( current_bitrate / 1000000 )) Mbps) — skipping to preserve UI changes"
    elif [[ "$DESIRED_BITRATE" -eq 0 ]]; then
        skip "JELLYFIN_MAX_BITRATE=0 — remote bitrate unlimited (Jellyfin default, nothing to set)"
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
            ok "Remote client bitrate limit set to ${JELLYFIN_MAX_BITRATE:-10} Mbps"
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
# 8c. LANGUAGE — Preferred language across all services
#     Sets: Radarr/Sonarr/Prowlarr UI language, Jellyfin metadata
#     language + admin user audio/subtitle defaults, Bazarr subtitle
#     download language (undefined-audio fallback + default profile),
#     Jellyseerr original-language content filter.
# ============================================================
section "Language"

LANG_CODE="${MEDIA_LANGUAGE:-en}"

# ISO 639-1 → ISO 639-2/B 3-letter map (Jellyfin user config uses 3-letter)
LANG3=$(python3 -c "
m={'en':'eng','fr':'fra','de':'deu','es':'spa','it':'ita','pt':'por',
   'ja':'jpn','ko':'kor','zh':'zho','ru':'rus','ar':'ara','nl':'nld',
   'sv':'swe','pl':'pol','tr':'tur','hu':'hun','cs':'ces','ro':'ron',
   'da':'dan','fi':'fin','no':'nor','he':'heb','el':'ell','hi':'hin',
   'id':'ind','th':'tha','uk':'ukr','vi':'vie'}
print(m.get('${LANG_CODE}','${LANG_CODE}'))
" 2>/dev/null || echo "${LANG_CODE}")

# Helper: set uiLanguage on an *arr config/host endpoint
_set_arr_lang() {
    local base="$1" path="$2" key="$3" label="$4"
    local resp body cur_lang host_id updated
    resp=$(arr_get "${base}${path}" "$key")
    body=$(body "$resp")
    cur_lang=$(echo "$body" | python3 -c "import json,sys; print(json.load(sys.stdin).get('uiLanguage',''))" 2>/dev/null || echo "")
    if [[ "$cur_lang" == "$LANG_CODE" ]]; then
        skip "${label} UI language already ${LANG_CODE}"; return
    fi
    host_id=$(echo "$body" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',1))" 2>/dev/null || echo "1")
    updated=$(echo "$body" | python3 -c "
import json,sys
d=json.load(sys.stdin)
d['uiLanguage']='${LANG_CODE}'
print(json.dumps(d))")
    resp=$(arr_put "${base}${path}/${host_id}" "$key" "$updated")
    ok_code "$resp" && ok "${label} UI language → ${LANG_CODE}" \
        || fail "Failed to set ${label} language (HTTP $(code "$resp"))"
}

is_placeholder "RADARR_API_KEY"   || _set_arr_lang "http://localhost:7878" "/api/v3/config/host" "$RADARR_API_KEY"   "Radarr"
is_placeholder "SONARR_API_KEY"   || _set_arr_lang "http://localhost:8989" "/api/v3/config/host" "$SONARR_API_KEY"   "Sonarr"
is_placeholder "PROWLARR_API_KEY" || _set_arr_lang "http://localhost:9696" "/api/v1/config/host" "$PROWLARR_API_KEY" "Prowlarr"

# ── Bazarr: subtitle download language ───────────────────────────
if ! is_placeholder "BAZARR_API_KEY"; then
    BAZARR_CFG="$STACK_DIR/config/bazarr/config/config.yaml"
    if [[ ! -f "$BAZARR_CFG" ]]; then
        fail "Bazarr config not found — skipping language setup"
    else
        bazarr_lang_changed=false

        # Set undefined-audio and undefined-embedded-subtitle fallback language
        for sed_field in "default_und_audio_lang" "default_und_embedded_subtitles_lang"; do
            current_val=$(grep -oP "(?<=  ${sed_field}: ')[^']*" "$BAZARR_CFG" 2>/dev/null \
                || grep -oP "(?<=  ${sed_field}: )[^'\n ]+" "$BAZARR_CFG" 2>/dev/null | head -1 || echo "")
            if [[ "$current_val" != "$LANG_CODE" ]]; then
                sed -i "s/  ${sed_field}: .*/  ${sed_field}: '${LANG_CODE}'/" "$BAZARR_CFG"
                bazarr_lang_changed=true
            fi
        done

        # Set embeddedsubtitles fallback_lang
        current_fb=$(grep -oP '(?<=  fallback_lang: )[^\n]+' "$BAZARR_CFG" 2>/dev/null | head -1 | tr -d "'\""|| echo "")
        if [[ "$current_fb" != "$LANG_CODE" ]]; then
            sed -i "s/  fallback_lang: .*/  fallback_lang: ${LANG_CODE}/" "$BAZARR_CFG"
            bazarr_lang_changed=true
        fi

        # Create (or find) a language profile for LANG_CODE via direct DB insert
        # (Bazarr's /api/system/languages/profiles is GET-only; profiles stored in SQLite)
        BAZARR_DB="/media/${USER}/DATA1/mediaserver/config/bazarr/db/bazarr.db"
        prof_id=$(docker exec bazarr python3 -c "
import sqlite3, json
db = '/config/db/bazarr.db'
conn = sqlite3.connect(db)
cur = conn.cursor()
# Enable the language in table_settings_languages
cur.execute(\"UPDATE table_settings_languages SET enabled=1 WHERE code2='${LANG_CODE}'\")
conn.commit()
# Check for existing profile containing LANG_CODE
cur.execute('SELECT profileId, items FROM table_languages_profiles')
match = None
for pid, items_str in cur.fetchall():
    try:
        items = json.loads(items_str)
        if any(str(i.get('language','')).lower() == '${LANG_CODE}'.lower() for i in items):
            match = pid; break
    except: pass
if match is not None:
    print(match)
else:
    items = json.dumps([{'id':1,'language':'${LANG_CODE}','audio_exclude':'False','hi':'False','forced':'False'}])
    cur.execute(\"INSERT INTO table_languages_profiles (name, items, cutoff, originalFormat, mustContain, mustNotContain) VALUES (?,?,NULL,0,'[]','[]')\",
                ('${LANG_CODE}', items))
    conn.commit()
    print(cur.lastrowid)
conn.close()
" 2>/dev/null || echo "")

        if [[ -n "$prof_id" ]]; then
            cur_movie_prof=$(grep -oP "(?<=  movie_default_profile: ')[^']*" "$BAZARR_CFG" 2>/dev/null \
                || grep -oP "(?<=  movie_default_profile: )[^'\n ]+" "$BAZARR_CFG" 2>/dev/null | head -1 || echo "")
            cur_serie_prof=$(grep -oP "(?<=  serie_default_profile: ')[^']*" "$BAZARR_CFG" 2>/dev/null \
                || grep -oP "(?<=  serie_default_profile: )[^'\n ]+" "$BAZARR_CFG" 2>/dev/null | head -1 || echo "")
            if [[ "$cur_movie_prof" != "$prof_id" || "$cur_serie_prof" != "$prof_id" ]]; then
                sed -i "s/  movie_default_enabled: .*/  movie_default_enabled: true/"          "$BAZARR_CFG"
                sed -i "s/  movie_default_profile: .*/  movie_default_profile: '${prof_id}'/" "$BAZARR_CFG"
                sed -i "s/  serie_default_enabled: .*/  serie_default_enabled: true/"          "$BAZARR_CFG"
                sed -i "s/  serie_default_profile: .*/  serie_default_profile: '${prof_id}'/" "$BAZARR_CFG"
                bazarr_lang_changed=true
                ok "Bazarr default subtitle profile → ${LANG_CODE} (profile #${prof_id})"
            else
                skip "Bazarr default subtitle profile already set (${LANG_CODE})"
            fi
        else
            fail "Could not create/find Bazarr language profile for ${LANG_CODE}"
        fi

        if [[ "$bazarr_lang_changed" == true ]]; then
            docker restart bazarr &>/dev/null
            ok "Bazarr restarted to apply language changes"
        fi
    fi
fi

# ── Jellyfin: metadata language + admin user audio/subtitle defaults ──
if ! is_placeholder "JELLYFIN_API_KEY"; then
    JF_SYSTEM_XML="$STACK_DIR/config/jellyfin/system.xml"
    JF_BASE="http://localhost:8096"
    JF_AUTH="Authorization: MediaBrowser Token=\"${JELLYFIN_API_KEY}\""
    jf_lang_changed=false

    # 1. Preferred metadata language in system.xml
    if [[ -f "$JF_SYSTEM_XML" ]]; then
        current_meta=$(grep -oP "(?<=<PreferredMetadataLanguage>)[^<]+" "$JF_SYSTEM_XML" 2>/dev/null || echo "")
        if [[ "$current_meta" == "$LANG_CODE" ]]; then
            skip "Jellyfin metadata language already ${LANG_CODE}"
        else
            sed -i "s|<PreferredMetadataLanguage>[^<]*</PreferredMetadataLanguage>|<PreferredMetadataLanguage>${LANG_CODE}</PreferredMetadataLanguage>|" "$JF_SYSTEM_XML"
            ok "Jellyfin metadata language → ${LANG_CODE}"
            jf_lang_changed=true
        fi
    fi

    # 2. Admin user default audio + subtitle language (ISO 639-2 3-letter)
    JF_USER_ID=$(curl -sf "$JF_BASE/Users" -H "$JF_AUTH" 2>/dev/null \
        | python3 -c "
import json,sys
try:
    users=json.load(sys.stdin)
    admin=next((u for u in users if u.get('Policy',{}).get('IsAdministrator')), users[0] if users else {})
    print(admin.get('Id',''))
except: print('')
" 2>/dev/null || echo "")

    if [[ -n "$JF_USER_ID" ]]; then
        user_cfg=$(curl -sf "$JF_BASE/Users/${JF_USER_ID}" -H "$JF_AUTH" 2>/dev/null \
            | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin).get('Configuration',{})))" \
            2>/dev/null || echo "{}")
        cur_audio=$(echo "$user_cfg" | python3 -c "import json,sys; print(json.load(sys.stdin).get('AudioLanguagePreference',''))" 2>/dev/null || echo "")
        cur_sub=$(echo "$user_cfg"   | python3 -c "import json,sys; print(json.load(sys.stdin).get('SubtitleLanguagePreference',''))" 2>/dev/null || echo "")

        if [[ "$cur_audio" == "$LANG3" && "$cur_sub" == "$LANG3" ]]; then
            skip "Jellyfin user audio/subtitle preference already ${LANG3}"
        else
            new_cfg=$(echo "$user_cfg" | python3 -c "
import json,sys
d=json.load(sys.stdin)
d['AudioLanguagePreference']='${LANG3}'
d['SubtitleLanguagePreference']='${LANG3}'
d['PlayDefaultAudioTrack']=False
print(json.dumps(d))")
            resp=$(curl -s -w "\n%{http_code}" -X POST "$JF_BASE/Users/${JF_USER_ID}/Configuration" \
                -H "$JF_AUTH" -H "Content-Type: application/json" -d "$new_cfg")
            ok_code "$resp" && ok "Jellyfin admin user audio/subtitle language → ${LANG3}" \
                || fail "Failed to set Jellyfin user language (HTTP $(code "$resp"))"
        fi
    fi

    if [[ "$jf_lang_changed" == true ]]; then
        docker restart jellyfin &>/dev/null
        ok "Jellyfin restarted to apply metadata language"
    fi
fi

# ── Jellyseerr: original-language content filter ─────────────────
if ! is_placeholder "JELLYSEERR_API_KEY" && curl -sf "http://localhost:5055/api/v1/settings/public" -H "X-Api-Key: $JELLYSEERR_API_KEY" &>/dev/null; then
    JS_BASE="http://localhost:5055"
    main_resp=$(http GET "$JS_BASE/api/v1/settings/main" -H "X-Api-Key: $JELLYSEERR_API_KEY")
    main_body=$(body "$main_resp")
    cur_locale=$(echo "$main_body" | python3 -c "import json,sys; print(json.load(sys.stdin).get('locale',''))" 2>/dev/null || echo "")
    if [[ "$cur_locale" == "$LANG_CODE" ]]; then
        skip "Jellyseerr UI locale already ${LANG_CODE}"
    else
        updated=$(echo "$main_body" | python3 -c "
import json,sys
d=json.load(sys.stdin)
d.pop('apiKey', None)
d['locale']='${LANG_CODE}'
print(json.dumps(d))")
        resp=$(http POST "$JS_BASE/api/v1/settings/main" \
            -H "X-Api-Key: $JELLYSEERR_API_KEY" \
            -H "Content-Type: application/json" \
            -d "$updated")
        ok_code "$resp" && ok "Jellyseerr UI locale → ${LANG_CODE}" \
            || fail "Failed to set Jellyseerr locale (HTTP $(code "$resp"))"

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
# Note: uptime-kuma:2 initialises Express before socket.io, so the SPA
# catch-all handler intercepts all socket.io polling and WebSocket upgrade
# requests.  The Python uptime_kuma_api library (which uses socket.io) cannot
# connect as a result.  We work around this by talking to the SQLite database
# directly via docker exec, exactly as Uptime Kuma's own reset-password.js does.
# ============================================================
section "Uptime Kuma"

wait_http "http://localhost:3001" "Uptime Kuma" 60 || { fail "Uptime Kuma not responding — skipping"; }

# Step 1: Complete the database setup wizard if not done yet.
# On first run, db-config.json is missing and Uptime Kuma waits at /setup-database.
# The HTTP server still responds (302) during this phase, so wait_http alone is not enough.
_uk_setup_info=$(curl -sf --max-time 5 "http://localhost:3001/setup-database-info" 2>/dev/null || echo '{}')
_uk_need_setup=$(echo "$_uk_setup_info" | python3 -c "import json,sys; print(json.load(sys.stdin).get('needSetup', False))" 2>/dev/null)
if [[ "$_uk_need_setup" == "True" ]]; then
    info "Uptime Kuma database not initialised — running setup..."
    _uk_setup_resp=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
        -X POST "http://localhost:3001/setup-database" \
        -H "Content-Type: application/json" \
        -d '{"dbConfig":{"type":"sqlite"}}' 2>/dev/null)
    if [[ "$_uk_setup_resp" =~ ^2 ]]; then
        ok "Database setup complete — waiting for restart..."
        sleep 8
        wait_http "http://localhost:3001" "Uptime Kuma post-setup" 60 \
            || { fail "Uptime Kuma did not come back after setup"; }
    else
        fail "Database setup POST returned HTTP $_uk_setup_resp"
    fi
fi

if [[ -z "${ADMIN_PASSWORD:-}" || "${ADMIN_PASSWORD:-}" == "changeme" ]]; then
    skip "Uptime Kuma setup skipped — set ADMIN_PASSWORD in .env first"
else
    docker exec -i \
        -e ADMIN_USER="${ADMIN_USER:-admin}" \
        -e ADMIN_PASSWORD="${ADMIN_PASSWORD:-}" \
        uptime-kuma node - <<JSEOF
const sqlite3 = require('@louislam/sqlite3').verbose();
const bcrypt  = require('bcryptjs');
const db = new sqlite3.Database('/app/data/kuma.db');

const user  = process.env.ADMIN_USER     || 'admin';
const pw    = process.env.ADMIN_PASSWORD || '';

const GRN = '\x1b[0;32m'; YLW = '\x1b[1;33m'; RED = '\x1b[0;31m'; NC = '\x1b[0m';
const ok   = (m) => console.log('  ' + GRN + '✓' + NC + '  ' + m);
const skip = (m) => console.log('  ' + YLW + '–' + NC + '  ' + m);
const fail = (m) => console.log('  ' + RED + '✗' + NC + '  ' + m);

const monitors = [
    { name: 'Jellyfin',       url: 'http://jellyfin:8096'    },
    { name: 'Jellyseerr',     url: 'http://jellyseerr:5055'  },
    { name: 'Radarr',         url: 'http://radarr:7878'      },
    { name: 'Sonarr',         url: 'http://sonarr:8989'      },
    { name: 'Prowlarr',       url: 'http://prowlarr:9696'    },
    { name: 'qBittorrent',    url: 'http://gluetun:8080' },
    { name: 'Bazarr',         url: 'http://bazarr:6767'      },
    { name: 'Homepage',       url: 'http://homepage:3000'    },
    { name: 'Audiobookshelf', url: 'http://audiobookshelf:13378' },
    { name: 'FlareSolverr',   url: 'http://flaresolverr:8191'},
];

db.serialize(async () => {
    db.get('SELECT id FROM user WHERE username = ?', [user], async (err, row) => {
        if (row) {
            skip('Uptime Kuma admin account already exists (' + user + ')');
        } else {
            const hash = await bcrypt.hash(pw, 10);
            db.run(
                'INSERT INTO user (username, password, active) VALUES (?, ?, 1)',
                [user, hash],
                (e) => { if (e) fail('Failed to create account: ' + e.message); else ok('Admin account created: ' + user); }
            );
        }

        // Get or wait for user_id
        db.get('SELECT id FROM user WHERE username = ?', [user], (err2, userRow) => {
            if (!userRow) { db.close(); return; }
            const uid = userRow.id;

            db.all('SELECT name FROM monitor WHERE user_id = ?', [uid], (err3, existing) => {
                const existingNames = new Set((existing || []).map(m => m.name));
                let added = 0;
                let pending = monitors.length;

                monitors.forEach(m => {
                    if (existingNames.has(m.name)) {
                        pending--;
                        if (pending === 0) finish();
                        return;
                    }
                    db.run(
                        'INSERT INTO monitor (name, url, type, active, user_id, interval, maxretries, created_date) VALUES (?, ?, ?, 1, ?, 60, 3, datetime("now"))',
                        [m.name, m.url, 'http', uid],
                        (e) => {
                            if (!e) added++;
                            pending--;
                            if (pending === 0) finish();
                        }
                    );
                });

                function finish() {
                    const skipped = monitors.length - added;
                    if (added > 0) ok(added + ' monitor(s) added');
                    if (skipped === monitors.length) skip('All monitors already exist');

                    // Create the "mediaserver" status page if it doesn't exist
                    db.get('SELECT id FROM status_page WHERE slug = ?', ['mediaserver'], (spErr, spRow) => {
                        if (spRow) {
                            skip('Status page "mediaserver" already exists');
                            db.close();
                            return;
                        }
                        db.run(
                            'INSERT INTO status_page (slug, title, description, icon, theme, published, search_engine_index, show_tags, password, footer_text, custom_css, show_powered_by, analytics_id, created_date, modified_date, show_certificate_expiry, auto_refresh_interval, show_only_last_heartbeat) VALUES (?,?,?,?,?,1,1,0,NULL,\'\',\'\',1,NULL,datetime(\'now\'),datetime(\'now\'),0,0,0)',
                            ['mediaserver', 'Media Server', 'Service status for the media stack', '', 'light'],
                            function(spInsertErr) {
                                if (spInsertErr) { fail('Failed to create status page: ' + spInsertErr.message); db.close(); return; }
                                const pageId = this.lastID;
                                db.run(
                                    'INSERT INTO [group] (name, created_date, public, active, weight, status_page_id) VALUES (\'Services\', datetime(\'now\'), 1, 1, 0, ?)',
                                    [pageId],
                                    function(grpErr) {
                                        if (grpErr) { fail('Failed to create status page group: ' + grpErr.message); db.close(); return; }
                                        const groupId = this.lastID;
                                        db.all('SELECT id FROM monitor ORDER BY id', (mErr, allMonitors) => {
                                            let mp = allMonitors.length;
                                            allMonitors.forEach((m, idx) => {
                                                db.run(
                                                    'INSERT INTO monitor_group (monitor_id, group_id, weight, send_url) VALUES (?,?,?,0)',
                                                    [m.id, groupId, idx],
                                                    () => { if (--mp === 0) { ok('Status page "mediaserver" created with ' + allMonitors.length + ' monitors'); db.close(); } }
                                                );
                                            });
                                        });
                                    }
                                );
                            }
                        );
                    });
                }
            });
        });
    });
});
JSEOF
    RET=$?
    [[ $RET -ne 0 ]] && fail "Uptime Kuma setup via database failed (exit $RET)"
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

    # Create Audiobooks library if none exist
    ABS_TOKEN="${abs_token:-${AUDIOBOOKSHELF_API_KEY:-}}"
    if [[ -n "$ABS_TOKEN" ]]; then
        abs_lib_count=$(curl -s "$ABS_URL/api/libraries" \
            -H "Authorization: Bearer $ABS_TOKEN" | \
            python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else len(d.get('libraries',[])))" 2>/dev/null)
        if [[ "${abs_lib_count:-0}" -eq 0 ]]; then
            abs_lib_resp=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$ABS_URL/api/libraries" \
                -H "Authorization: Bearer $ABS_TOKEN" \
                -H "Content-Type: application/json" \
                -d '{"name":"Audiobooks","folders":[{"fullPath":"/audiobooks"}],"icon":"audiobookshelf","mediaType":"book","provider":"audible","settings":{"coverAspectRatio":1,"disableWatcher":false,"skipMatchingMediaWithAsin":false,"skipMatchingMediaWithIsbn":false,"autoScanCronExpression":""}}')
            [[ "$abs_lib_resp" == "200" ]] \
                && ok "Audiobooks library created" \
                || fail "Failed to create Audiobooks library (HTTP $abs_lib_resp)"
        else
            skip "Audiobooks library already exists"
        fi

        # Apply default server settings (idempotent — safe to re-run)
        abs_settings_resp=$(curl -s -o /dev/null -w "%{http_code}" -X PATCH "$ABS_URL/api/settings" \
            -H "Authorization: Bearer $ABS_TOKEN" \
            -H "Content-Type: application/json" \
            -d '{"chromecastEnabled":true,"sortingIgnorePrefix":true,"scannerFindCovers":true}')
        [[ "$abs_settings_resp" == "200" ]] \
            && ok "Server settings applied (Chromecast, ignore prefixes, find covers)" \
            || fail "Failed to apply server settings (HTTP $abs_settings_resp)"
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
  {"hostname": "qbit.${CF_DOMAIN}",      "service": "http://gluetun:8080"},
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
