#!/usr/bin/env bash
# ============================================================
# install.sh — Complete automated media server setup
#
# Run this on a fresh machine, or re-run at any time to pick up
# where a previous run left off.  It will:
#   1.  Collect a few one-time credentials from you
#   2.  Enable Docker on boot & create all directories
#   3.  Start all containers
#   4.  Complete the Jellyfin setup wizard via API
#   5.  Create Jellyfin libraries (Movies, TV Shows, Audiobooks)
#   6.  Complete the Jellyseerr setup wizard via API
#   7.  Extract all API keys from config files
#   8.  Wire every service to every other service
#   9.  Trigger initial Prowlarr → Radarr/Sonarr sync
#  10.  Trigger initial Recyclarr quality-profile sync
#
# Usage:
#   bash install.sh          # first run or re-run
#
# Re-runnable — every step checks current state before acting.
# Already-done steps are skipped automatically.
# ============================================================

set -uo pipefail
STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$STACK_DIR/.env"

# ── Colours ────────────────────────────────────────────────
GRN='\033[0;32m'; YLW='\033[1;33m'; RED='\033[0;31m'; BLD='\033[1m'; CYN='\033[0;36m'; NC='\033[0m'
ok()      { echo -e "  ${GRN}✓${NC}  $*"; }
skip()    { echo -e "  ${YLW}–${NC}  $*"; }
fail()    { echo -e "  ${RED}✗${NC}  $*"; }
info()    { echo -e "  ${CYN}i${NC}  $*"; }
section() { echo -e "\n${BLD}╔══ $* ══${NC}"; }
die()     { echo -e "\n${RED}FATAL:${NC} $*\n"; exit 1; }

# ── Helpers ────────────────────────────────────────────────
# set_env writes to .env (runtime values like API keys)
set_env() { sed -i "s|^${1}=.*|${1}=${2}|" "$ENV_FILE"; }
env_val() { grep -m1 "^${1}=" "$ENV_FILE" | cut -d= -f2-; }
is_placeholder() { local v; v=$(env_val "$1"); [[ -z "$v" ]]; }

body()    { echo "$1" | head -n -1; }
code()    { echo "$1" | tail -n 1; }
ok_code() { [[ "$(code "$1")" == "2"* ]]; }

http() {
    local method="$1" url="$2"; shift 2
    curl -s -w "\n%{http_code}" -X "$method" "$url" "$@"
}

json_field() {
    local json="$1" key="$2"
    python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('${key}',''))" "$json" 2>/dev/null \
        || echo "$json" | grep -oP "(?<=\"${key}\":\")[^\"]+" | head -1
}

wait_http() {
    local url="$1" label="$2" max="${3:-180}"
    local i=0
    echo -ne "  Waiting for ${label}"
    while (( i < max )); do
        curl -sf --max-time 3 "$url" &>/dev/null && { echo " ready"; return 0; }
        sleep 4; i=$((i+4)); echo -n "."
    done
    echo " TIMEOUT"; return 1
}

wait_file() {
    local f="$1" label="$2" max="${3:-120}"
    local i=0
    [[ -f "$f" ]] && return 0
    echo -ne "  Waiting for ${label} config"
    while [[ ! -f "$f" ]] && (( i < max )); do
        sleep 3; i=$((i+3)); echo -n "."
    done
    echo ""
    [[ -f "$f" ]]
}

wait_for_first_boot() {
    local max="${1:-300}"
    local interval=4
    local elapsed=0
    local config="$STACK_DIR/config"

    local required=(
        "$config/sonarr/config.xml"
        "$config/radarr/config.xml"
        "$config/prowlarr/config.xml"
    )

    echo -ne "  Waiting for first-boot config files"
    while (( elapsed < max )); do
        local pending=()
        local f
        for f in "${required[@]}"; do
            [[ -s "$f" ]] || pending+=("$f")
        done

        local bazarr_ready=false
        [[ -s "$config/bazarr/config.yaml" || -s "$config/bazarr/config/config.yaml" ]] && bazarr_ready=true

        if (( ${#pending[@]} == 0 )) && [[ "$bazarr_ready" == true ]]; then
            echo " ready"
            return 0
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
        echo -n "."
    done

    echo ""
    skip "Initialization still in progress after ${max}s; continuing and waiting per service"
    return 1
}

xml_key()  { grep -oP '(?<=<ApiKey>)[^<]+' "$1" 2>/dev/null | head -1; }
json_key() { python3 -c "import json; print(json.load(open('$1')).get('main',{}).get('apiKey',''))" 2>/dev/null || jq -r '.main.apiKey // empty' "$1" 2>/dev/null; }

# ============================================================
# STEP 0 — Validate credentials
# ============================================================
echo ""
echo -e "${BLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLD}║       Media Server — Full Automated Setup            ║${NC}"
echo -e "${BLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

# Derive PUID/PGID/TZ from the system
export PUID="$(id -u)"
export PGID="$(id -g)"
export TZ
TZ=$(timedatectl show --property=Timezone --value 2>/dev/null) \
    || TZ=$(cat /etc/timezone 2>/dev/null) \
    || TZ=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||') \
    || TZ="UTC"

# Load .env
set -o allexport; source "$ENV_FILE"; set +o allexport

# Validate required values
MISSING=()
for var in QBIT_USERNAME QBIT_PASSWORD; do
    [[ -z "$(env_val "$var")" ]] && MISSING+=("$var")
done
# Jellyfin credentials only required before wizard runs (auto-removed after)
if grep -q "^JELLYFIN_ADMIN_USER=" "$ENV_FILE" 2>/dev/null; then
    for var in JELLYFIN_ADMIN_USER JELLYFIN_ADMIN_PASSWORD; do
        val=$(env_val "$var")
        [[ -z "$val" || "$val" == *"changeme"* ]] && MISSING+=("$var")
    done
fi

if (( ${#MISSING[@]} > 0 )); then
    fail "The following values must be filled in before running:"
    for v in "${MISSING[@]}"; do fail "  $v"; done
    exit 1
fi

JF_USER="${JELLYFIN_ADMIN_USER:-}"
JF_PASS="${JELLYFIN_ADMIN_PASSWORD:-}"

ok "Running as:        $(id -un) (PUID=$PUID, PGID=$PGID)"
ok "Timezone:          $TZ (auto-detected)"
ok "qBittorrent user:  $QBIT_USERNAME"
[[ -n "$JF_USER" ]] && ok "Jellyfin admin:    $JF_USER" || ok "Jellyfin admin:    (credentials already used and removed)"
echo ""
echo -e "  ${GRN}Starting unattended setup...${NC}"

# ============================================================
# STEP 1 — System: directories + Docker on boot
# ============================================================
section "System Setup"

# Media directories
for d in "$DIR_DOWNLOADS" "$DIR_MOVIES" "$DIR_TV" "$DIR_AUDIOBOOKS"; do
    mkdir -p "$d" && ok "Directory: $d" || fail "Could not create: $d"
done

# Config directories
mkdir -p "$STACK_DIR/config/"{qbittorrent,prowlarr,radarr,sonarr,jellyfin,jellyseerr,bazarr,recyclarr,homepage,uptime-kuma,audiobookshelf/metadata}
ok "Config directories created"

# Permissions
chown -R 1000:1000 "$STACK_DIR/config" \
    "$DIR_DOWNLOADS" "$DIR_MOVIES" \
    "$DIR_AUDIOBOOKS" 2>/dev/null || true
chown -R 1000:1000 "$DIR_TV" 2>/dev/null || true
ok "Permissions set"

# Enable Docker at boot
sudo systemctl enable docker &>/dev/null && ok "Docker enabled on boot" || skip "Docker already enabled"

# ============================================================
# STEP 2 — Start containers
# ============================================================
section "Starting Containers"

docker compose -f "$STACK_DIR/docker-compose.yml" pull --quiet 2>/dev/null
ok "Images pulled"

docker compose -f "$STACK_DIR/docker-compose.yml" up -d 2>/dev/null
ok "All containers started"

echo ""
info "Waiting for services to initialize (adaptive)..."
wait_for_first_boot 300 || true

# ============================================================
# STEP 3 — Extract API keys from *arr config files
# (Sonarr, Radarr, Prowlarr write keys on first boot)
# ============================================================
section "Extracting API Keys from Config Files"

CONFIG="$STACK_DIR/config"

_extract_xml() {
    local name="$1" env_key="$2" path="$3"
    if is_placeholder "$env_key"; then
        if wait_file "$path" "$name" 90; then
            local key; key=$(xml_key "$path")
            if [[ -n "$key" ]]; then
                set_env "$env_key" "$key"
                ok "$name: $key"
            else
                fail "$name: could not parse key from $path"
            fi
        else
            fail "$name: config file not found after 90s"
        fi
    else
        skip "$env_key already set"
    fi
}

_extract_xml "Sonarr"   "SONARR_API_KEY"   "$CONFIG/sonarr/config.xml"
_extract_xml "Radarr"   "RADARR_API_KEY"   "$CONFIG/radarr/config.xml"
_extract_xml "Prowlarr" "PROWLARR_API_KEY" "$CONFIG/prowlarr/config.xml"

# Bazarr
if is_placeholder "BAZARR_API_KEY"; then
    bazarr_conf=""
    for candidate in "$CONFIG/bazarr/config.yaml" "$CONFIG/bazarr/config/config.yaml"; do
        [[ -f "$candidate" ]] && { bazarr_conf="$candidate"; break; }
    done
    if [[ -z "$bazarr_conf" ]]; then
        wait_file "$CONFIG/bazarr/config.yaml" "Bazarr" 90 \
            && bazarr_conf="$CONFIG/bazarr/config.yaml" || true
    fi
    if [[ -n "$bazarr_conf" && -f "$bazarr_conf" ]]; then
        bkey=$(grep -oP '(?<=apikey:\s{0,10})\S+' "$bazarr_conf" 2>/dev/null | head -1)
        [[ -n "$bkey" ]] && { set_env "BAZARR_API_KEY" "$bkey"; ok "Bazarr: $bkey"; } \
            || fail "Bazarr: could not parse apikey from $bazarr_conf"
    else
        fail "Bazarr: config not found"
    fi
else
    skip "BAZARR_API_KEY already set"
fi

# Reload .env with extracted keys
set -o allexport; source "$ENV_FILE"; set +o allexport

# ============================================================
# STEP 4 — Jellyfin: wizard + libraries + API key
# ============================================================
section "Jellyfin Setup"

JF_BASE="http://localhost:8096"
wait_http "$JF_BASE/health" "Jellyfin" 180 || die "Jellyfin not responding after 3 minutes"

jf_status=$(curl -sf "$JF_BASE/System/Info/Public" 2>/dev/null || echo "{}")
wizard_done=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('StartupWizardCompleted', False))" "$jf_status" 2>/dev/null || echo "False")

JF_AUTH=""

if [[ "$wizard_done" != "True" ]]; then
    # ── First run: complete the wizard ─────────────────────
    [[ -z "$JF_USER" || -z "$JF_PASS" ]] && \
        die "Jellyfin wizard not done but JELLYFIN_ADMIN_USER/PASSWORD missing from .env"

    http POST "$JF_BASE/Startup/Configuration" \
        -H "Content-Type: application/json" \
        -d '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}' >/dev/null
    ok "Startup config set"

    resp=$(http POST "$JF_BASE/Startup/User" \
        -H "Content-Type: application/json" \
        -d "{\"Name\":\"${JF_USER}\",\"Password\":\"${JF_PASS}\"}")
    ok_code "$resp" && ok "Admin user '${JF_USER}' created" \
        || fail "Failed to create Jellyfin user: $(body "$resp")"

    http POST "$JF_BASE/Startup/RemoteAccess" \
        -H "Content-Type: application/json" \
        -d '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' >/dev/null

    http POST "$JF_BASE/Startup/Complete" >/dev/null
    ok "Wizard complete"

    # Authenticate with credentials (still available in memory)
    JF_AUTH_HEADER='MediaBrowser Client="Setup", Device="install-script", DeviceId="install-001", Version="1.0.0"'
    auth_resp=$(http POST "$JF_BASE/Users/AuthenticateByName" \
        -H "Content-Type: application/json" \
        -H "X-Emby-Authorization: $JF_AUTH_HEADER" \
        -d "{\"Username\":\"${JF_USER}\",\"Pw\":\"${JF_PASS}\"}")
    ok_code "$auth_resp" || die "Jellyfin authentication failed: $(body "$auth_resp")"
    JF_TOKEN=$(json_field "$(body "$auth_resp")" "AccessToken")
    [[ -z "$JF_TOKEN" ]] && die "Could not extract Jellyfin access token"
    JF_AUTH="Authorization: MediaBrowser Token=\"${JF_TOKEN}\""
    ok "Authenticated as ${JF_USER}"

elif ! is_placeholder "JELLYFIN_API_KEY"; then
    # ── Re-run: wizard done, use existing API key for auth ─
    skip "Jellyfin wizard already complete"
    JF_AUTH="Authorization: MediaBrowser Token=\"${JELLYFIN_API_KEY}\""

else
    # ── Re-run: wizard done but no API key and no credentials
    fail "Jellyfin wizard done but JELLYFIN_API_KEY not set"
    info "Add JELLYFIN_ADMIN_USER and JELLYFIN_ADMIN_PASSWORD back to .env and re-run"
fi

# ── Libraries + API key (runs whenever we have a valid auth token) ──
if [[ -n "$JF_AUTH" ]]; then
    existing_libs=$(curl -sf "$JF_BASE/Library/VirtualFolders" -H "$JF_AUTH" 2>/dev/null || echo "[]")

    _add_library() {
        local name="$1" type="$2" path="$3"
        if echo "$existing_libs" | python3 -c "
import json,sys
libs=json.load(sys.stdin)
sys.exit(0 if any(l['Name']=='${name}' for l in libs) else 1)" 2>/dev/null; then
            skip "Library '${name}' already exists"
        else
            resp=$(http POST "$JF_BASE/Library/VirtualFolders" \
                -H "$JF_AUTH" -H "Content-Type: application/json" \
                -G \
                --data-urlencode "name=${name}" \
                --data-urlencode "collectionType=${type}" \
                --data-urlencode "refreshLibrary=false" \
                -d "{\"LibraryOptions\":{\"PathInfos\":[{\"Path\":\"${path}\"}],\"EnableRealtimeMonitor\":true,\"MetadataCountryCode\":\"US\",\"PreferredMetadataLanguage\":\"en\"}}")
            ok_code "$resp" && ok "Library '${name}' created (${path})" \
                || fail "Failed to create '${name}' library (HTTP $(code "$resp"))"
        fi
    }

    _add_library "Movies"     "movies"  "/data/movies"
    _add_library "TV Shows"   "tvshows" "/data/tvshows"
    _add_library "Audiobooks" "books"   "/data/audiobooks"

    if is_placeholder "JELLYFIN_API_KEY"; then
        key_resp=$(http POST "$JF_BASE/Auth/Keys?app=MediaServer" -H "$JF_AUTH")
        if ok_code "$key_resp"; then
            JF_API_KEY=$(json_field "$(body "$key_resp")" "AccessToken")
            if [[ -n "$JF_API_KEY" ]]; then
                set_env "JELLYFIN_API_KEY" "$JF_API_KEY"
                ok "API key created: $JF_API_KEY"
            else
                fail "Could not parse API key from response"
            fi
        else
            fail "Failed to create API key (HTTP $(code "$key_resp"))"
        fi
    else
        skip "JELLYFIN_API_KEY already set"
    fi
fi

# Reload
set -o allexport; source "$ENV_FILE"; set +o allexport

# ============================================================
# STEP 5 — Jellyseerr: wizard (link to Jellyfin)
# ============================================================
section "Jellyseerr Setup"

JS_BASE="http://localhost:5055"
wait_http "$JS_BASE/api/v1/settings/public" "Jellyseerr" 120 || { fail "Jellyseerr not responding — skipping"; }

public_resp=$(curl -sf "$JS_BASE/api/v1/settings/public" 2>/dev/null || echo "{}")
initialized=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('initialized', False))" "$public_resp" 2>/dev/null || echo "False")

if [[ "$initialized" == "True" ]]; then
    skip "Jellyseerr already initialized"
elif [[ -z "$JF_USER" || -z "$JF_PASS" ]]; then
    # Re-run after credentials were scrubbed but Jellyseerr wasn't initialized
    fail "Jellyseerr not initialized but Jellyfin credentials are gone"
    info "Add JELLYFIN_ADMIN_USER and JELLYFIN_ADMIN_PASSWORD back to .env and re-run"
else
    JS_JAR=$(mktemp)
    init_resp=$(curl -s -c "$JS_JAR" -b "$JS_JAR" \
        -w "\n%{http_code}" \
        -X POST "$JS_BASE/api/v1/auth/jellyfin" \
        -H "Content-Type: application/json" \
        -d "{\"hostname\":\"jellyfin\",\"port\":8096,\"urlBase\":\"\",\"useSsl\":false,\"email\":\"\",\"username\":\"${JF_USER}\",\"password\":\"${JF_PASS}\"}")

    if ok_code "$init_resp"; then
        ok "Jellyseerr initialized with Jellyfin account '${JF_USER}'"
        sleep 3
        if is_placeholder "JELLYSEERR_API_KEY"; then
            js_config="$CONFIG/jellyseerr/settings.json"
            if [[ -f "$js_config" ]]; then
                jskey=$(json_key "$js_config")
                [[ -n "$jskey" ]] && { set_env "JELLYSEERR_API_KEY" "$jskey"; ok "Jellyseerr API key: $jskey"; }
            fi
        fi
    else
        fail "Jellyseerr init failed (HTTP $(code "$init_resp")): $(body "$init_resp")"
        info "Complete manually at http://localhost:5055, then run: bash configure.sh"
    fi
    rm -f "$JS_JAR"
fi

# Scrub Jellyfin credentials now that both wizards are done
if grep -q "^JELLYFIN_ADMIN_USER=" "$ENV_FILE" 2>/dev/null; then
    sed -i '/^JELLYFIN_ADMIN_USER=/d; /^JELLYFIN_ADMIN_PASSWORD=/d' "$ENV_FILE"
    ok "Jellyfin credentials removed from .env"
fi

# Reload with all keys
set -o allexport; source "$ENV_FILE"; set +o allexport

# ============================================================
# STEP 6 — Wire all services together
# ============================================================
section "Service Configuration"

bash "$STACK_DIR/configure.sh"

# ============================================================
# STEP 7 — Restart Homepage + Unpackerr with all API keys
# ============================================================
section "Applying Final Config"

docker compose -f "$STACK_DIR/docker-compose.yml" up -d homepage unpackerr recyclarr 2>/dev/null
ok "Homepage, Unpackerr, Recyclarr restarted with API keys"

# ============================================================
# STEP 8 — Final summary
# ============================================================
echo ""
echo -e "${BLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLD}║              Setup Complete!                         ║${NC}"
echo -e "${BLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BLD}Service URLs:${NC}"
echo -e "   ${GRN}►${NC} Homepage       http://localhost:3000   ← start here"
echo -e "   ${GRN}►${NC} Jellyfin       http://localhost:8096"
echo -e "   ${GRN}►${NC} Jellyseerr     http://localhost:5055"
echo -e "   ${GRN}►${NC} Radarr         http://localhost:7878"
echo -e "   ${GRN}►${NC} Sonarr         http://localhost:8989"
echo -e "   ${GRN}►${NC} Prowlarr       http://localhost:9696"
echo -e "   ${GRN}►${NC} qBittorrent    http://localhost:8080"
echo -e "   ${GRN}►${NC} Bazarr         http://localhost:6767"
echo -e "   ${GRN}►${NC} Audiobookshelf http://localhost:13378"
echo -e "   ${GRN}►${NC} Uptime Kuma    http://localhost:3001"
echo ""
echo -e "  ${BLD}Still needs manual attention:${NC}"
echo -e "   ${YLW}•${NC} Prowlarr → Add your torrent indexers (trackers)"
echo -e "   ${YLW}•${NC} Bazarr → Settings → Subtitles → add providers"
echo -e "   ${YLW}•${NC} Uptime Kuma → create account → add monitors"
echo -e "   ${YLW}•${NC} Audiobookshelf → create admin account"
echo ""

# API key status check
echo -e "  ${BLD}API Key Status:${NC}"
for k in SONARR_API_KEY RADARR_API_KEY PROWLARR_API_KEY \
          BAZARR_API_KEY JELLYFIN_API_KEY JELLYSEERR_API_KEY; do
    is_placeholder "$k" \
        && echo -e "   ${RED}MISSING${NC}  $k" \
        || echo -e "   ${GRN}OK${NC}      $k"
done

echo ""
echo -e "  Cloudflare tunnel: see ${BLD}CLOUDFLARE_SETUP.md${NC}"
echo ""
