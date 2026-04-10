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

_config_exists() {
    # Check if a config file exists: try host path first, fall back to docker exec.
    local container="$1" container_path="$2" host_path="$3"
    [[ -s "$host_path" ]] && return 0
    docker exec "$container" test -s "$container_path" 2>/dev/null && return 0
    return 1
}

_config_read() {
    # Read a config file: try host path first, fall back to docker exec.
    local container="$1" container_path="$2" host_path="$3"
    if [[ -s "$host_path" ]]; then
        cat "$host_path"
    else
        docker exec "$container" cat "$container_path" 2>/dev/null
    fi
}

wait_for_first_boot() {
    local max="${1:-300}"
    local interval=4
    local elapsed=0

    echo -ne "  Waiting for first-boot config files"
    while (( elapsed < max )); do
        local all_ready=true

        _config_exists sonarr   /config/config.xml "$STACK_DIR/config/sonarr/config.xml"   || all_ready=false
        _config_exists radarr   /config/config.xml "$STACK_DIR/config/radarr/config.xml"   || all_ready=false
        _config_exists prowlarr /config/config.xml "$STACK_DIR/config/prowlarr/config.xml" || all_ready=false

        local bazarr_ready=false
        _config_exists bazarr /config/config.yaml "$STACK_DIR/config/bazarr/config.yaml" && bazarr_ready=true
        _config_exists bazarr /config/config/config.yaml "$STACK_DIR/config/bazarr/config/config.yaml" && bazarr_ready=true
        [[ "$bazarr_ready" == true ]] || all_ready=false

        if [[ "$all_ready" == true ]]; then
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

check_desktop_mount_sharing() {
    local ctx=""
    ctx=$(docker context show 2>/dev/null || true)
    [[ "$ctx" == "desktop-linux" ]] || return 0

    section "Docker Desktop Mount Preflight"
    info "Docker context: desktop-linux"

    local mount_paths=(
        "$STACK_DIR"
        "$DIR_DOWNLOADS"
        "$DIR_MOVIES"
        "$DIR_TV"
        "$DIR_AUDIOBOOKS"
    )

    local failed=()
    for p in "${mount_paths[@]}"; do
        [[ -z "$p" ]] && continue
        # The mount must succeed AND the filesystem must not be overlayfs.
        # Docker Desktop silently falls back to overlay when a host path
        # is not shared, so a simple "docker run -v" exit-code check is
        # not enough.
        local fstype
        fstype=$(docker run --rm -v "$p:/mnt:rw" alpine:3.20 \
            stat -f -c '%T' /mnt 2>/dev/null) || fstype="failed"
        if [[ "$fstype" == "overlayfs" || "$fstype" == "overlay" || "$fstype" == "failed" ]]; then
            failed+=("$p")
        fi
    done

    if (( ${#failed[@]} > 0 )); then
        fail "Docker Desktop cannot properly bind-mount one or more host paths."
        fail "Mounts silently fall back to an overlay filesystem, so container"
        fail "data will NOT persist to disk and disk space will be very limited."
        echo ""
        echo "  Share these paths in Docker Desktop:"
        for p in "${failed[@]}"; do
            echo "   - $p"
        done
        echo ""
        echo "  Docker Desktop -> Settings -> Resources -> File sharing"
        echo "  Add the paths above (or a common parent like /media), Apply & Restart,"
        echo "  then run: bash install.sh"
        die "Host paths are not shared with Docker Desktop"
    fi

    ok "Docker Desktop mount sharing verified (bind mounts, not overlay)"
}

xml_key()  { grep -oP '(?<=<ApiKey>)[^<]+' "$1" 2>/dev/null | head -1; }
json_key() { python3 -c "import json; print(json.load(open('$1')).get('main',{}).get('apiKey',''))" 2>/dev/null || jq -r '.main.apiKey // empty' "$1" 2>/dev/null; }

# ============================================================
# STEP 0 — Validate credentials
# ============================================================
echo ""
echo -e "${BLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLD}║        Media Server — Fully Automated Setup          ║${NC}"
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

# Generate .env if it doesn't exist
if [[ ! -f "$ENV_FILE" ]]; then
    if [[ ! -f "$STACK_DIR/.env.initial" ]]; then
        die ".env.initial template not found — cannot create .env"
    fi
    info "Creating .env from .env.initial — edit credentials before re-running"
    cp "$STACK_DIR/.env.initial" "$ENV_FILE"
    # Replace $USER placeholder with actual username
    sed -i "s|\$USER|$(id -un)|g" "$ENV_FILE"
    ok "Created .env — please edit credentials and paths, then re-run: bash install.sh"
    exit 0
fi

# Create config directory structure if missing
mkdir -p "$STACK_DIR/config/"{qbittorrent,prowlarr,radarr,sonarr,jellyfin,jellyseerr,bazarr,recyclarr,homepage,uptime-kuma,audiobookshelf/metadata}

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
# STEP 0 — Prerequisites: install Docker and dependencies
# ============================================================
section "Prerequisites"

# curl
if command -v curl &>/dev/null; then
    skip "curl already installed"
else
    info "Installing curl..."
    sudo apt-get update -qq && sudo apt-get install -y -qq curl >/dev/null \
        && ok "curl installed" || die "Failed to install curl"
fi

# python3
if command -v python3 &>/dev/null; then
    skip "python3 already installed"
else
    info "Installing python3..."
    sudo apt-get update -qq && sudo apt-get install -y -qq python3 >/dev/null \
        && ok "python3 installed" || die "Failed to install python3"
fi

# Docker Engine
if command -v docker &>/dev/null; then
    skip "Docker already installed ($(docker --version | head -c 40))"
else
    info "Installing Docker..."
    # Official Docker convenience script (supports Ubuntu, Debian, Fedora, etc.)
    curl -fsSL https://get.docker.com | sudo sh \
        && ok "Docker installed" || die "Failed to install Docker"
    # Add current user to docker group so sudo is not needed for docker commands
    sudo usermod -aG docker "$USER" 2>/dev/null || true
    info "You may need to log out and back in for group changes to take effect"
fi

# Docker Compose plugin (ships with Docker Engine ≥20.10, but verify)
if docker compose version &>/dev/null; then
    skip "Docker Compose plugin available"
else
    info "Installing Docker Compose plugin..."
    sudo apt-get update -qq && sudo apt-get install -y -qq docker-compose-plugin >/dev/null \
        && ok "Docker Compose plugin installed" || die "Failed to install Docker Compose plugin"
fi

# Ensure Docker daemon is running
if docker info &>/dev/null; then
    skip "Docker daemon running"
else
    info "Starting Docker daemon..."
    sudo systemctl start docker \
        && ok "Docker daemon started" || die "Failed to start Docker daemon"
fi

# ============================================================
# STEP 1 — System: directories + Docker on boot
# ============================================================
section "System Setup"

# Ensure all path-like variables from .env exist as directories.
# Supported keys: DIR_*, *_ROOT, *_PATH
env_path_keys=()
while IFS='=' read -r key _; do
    case "$key" in
        DIR_*|*_ROOT|*_PATH) env_path_keys+=("$key") ;;
    esac
done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE")

for key in "${env_path_keys[@]}"; do
    path="${!key:-}"
    [[ -z "$path" ]] && continue
    if [[ -d "$path" ]]; then
        skip "Path exists (${key}): $path"
    else
        mkdir -p "$path" && ok "Created path (${key}): $path" || die "Could not create path (${key}): $path"
    fi
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

# Docker Desktop on Linux can block host mounts unless paths are shared.
check_desktop_mount_sharing

# ============================================================
# STEP 2 — Start containers
# ============================================================
section "Starting Containers"

# Pull missing images and check for updates on existing ones
needs_pull=false
while IFS= read -r image; do
    [[ -z "$image" ]] && continue
    if ! docker image inspect "$image" >/dev/null 2>&1; then
        needs_pull=true
        break
    fi
done < <(docker compose -f "$STACK_DIR/docker-compose.yml" config --images 2>/dev/null)

if [[ "$needs_pull" == true ]]; then
    info "Pulling missing images..."
fi

# Always check for updates (pulls only layers that changed)
if docker compose -f "$STACK_DIR/docker-compose.yml" pull --quiet 2>/dev/null; then
    ok "Images up to date"
else
    die "Failed to pull one or more Docker images"
fi

if docker compose -f "$STACK_DIR/docker-compose.yml" up -d; then
    ok "All containers started"
else
    die "Failed to start one or more containers"
fi

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
    local name="$1" env_key="$2" container="$3"
    local container_path="/config/config.xml"
    local host_path="$CONFIG/${container}/config.xml"
    if is_placeholder "$env_key"; then
        local attempts=0
        while (( attempts < 23 )); do   # ~90s (23×4)
            if _config_exists "$container" "$container_path" "$host_path"; then
                local content; content=$(_config_read "$container" "$container_path" "$host_path")
                local key; key=$(echo "$content" | grep -oP '(?<=<ApiKey>)[^<]+' | head -1)
                if [[ -n "$key" ]]; then
                    set_env "$env_key" "$key"
                    ok "$name: $key"
                    return 0
                fi
            fi
            sleep 4; attempts=$((attempts+1))
        done
        fail "$name: config file not found after 90s"
    else
        skip "$env_key already set"
    fi
}

_extract_xml "Sonarr"   "SONARR_API_KEY"   "sonarr"
_extract_xml "Radarr"   "RADARR_API_KEY"   "radarr"
_extract_xml "Prowlarr" "PROWLARR_API_KEY" "prowlarr"

# Bazarr
if is_placeholder "BAZARR_API_KEY"; then
    local_found=false
    bkey=""
    # Try reading from host first, then via docker exec
    for candidate in "$CONFIG/bazarr/config.yaml" "$CONFIG/bazarr/config/config.yaml"; do
        if [[ -f "$candidate" ]]; then
            bkey=$(grep -A1 '^auth:' "$candidate" 2>/dev/null | grep -oP '(?<=apikey:\s{0,10})\S+' | head -1)
            [[ -n "$bkey" ]] && { local_found=true; break; }
        fi
    done
    if [[ "$local_found" != true ]]; then
        # Fall back to docker exec
        for cpath in /config/config.yaml /config/config/config.yaml; do
            if docker exec bazarr test -s "$cpath" 2>/dev/null; then
                bkey=$(docker exec bazarr cat "$cpath" 2>/dev/null \
                    | grep -A1 '^auth:' | grep -oP '(?<=apikey:\s{0,10})\S+' | head -1)
                [[ -n "$bkey" ]] && break
            fi
        done
    fi
    if [[ -n "$bkey" ]]; then
        set_env "BAZARR_API_KEY" "$bkey"
        ok "Bazarr: $bkey"
    else
        fail "Bazarr: could not extract API key"
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
# Jellyfin /health returns "Healthy" only after migrations complete;
# during startup/migration it returns "Degraded" (still 200), so we
# must match the response body, not just the HTTP code.
info "Waiting for Jellyfin (may take several minutes during DB migrations) …"
_jf_i=0; _jf_max=600
while (( _jf_i < _jf_max )); do
    _jf_h=$(curl -sf --max-time 3 "$JF_BASE/health" 2>/dev/null || echo "")
    [[ "$_jf_h" == "Healthy" ]] && break
    sleep 4; _jf_i=$((_jf_i+4)); (( _jf_i % 40 == 0 )) && echo -ne "."
done
(( _jf_i >= _jf_max )) && die "Jellyfin not healthy after 10 minutes"
ok "Jellyfin healthy"

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

    # Wait for Jellyfin to create its default user (race condition in 10.11+)
    info "Waiting for Jellyfin default user to be ready …"
    for _try in $(seq 1 120); do
        _su=$(curl -sf "$JF_BASE/Startup/User" 2>/dev/null || echo "")
        [[ -n "$_su" ]] && python3 -c "import json,sys; u=json.loads(sys.argv[1]); assert u.get('Name')" "$_su" 2>/dev/null && break
        sleep 1
    done
    [[ $_try -eq 120 ]] && die "Jellyfin default user not ready after 120 s"

    jf_user_json=$(python3 -c 'import json,sys; print(json.dumps({"Name":sys.argv[1],"Password":sys.argv[2]}, ensure_ascii=False))' "$JF_USER" "$JF_PASS")
    resp=$(http POST "$JF_BASE/Startup/User" \
        -H "Content-Type: application/json" \
        -d "$jf_user_json")
    ok_code "$resp" && ok "Admin user '${JF_USER}' created" \
        || fail "Failed to create Jellyfin user: $(body "$resp")"

    http POST "$JF_BASE/Startup/RemoteAccess" \
        -H "Content-Type: application/json" \
        -d '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' >/dev/null

    http POST "$JF_BASE/Startup/Complete" >/dev/null
    ok "Wizard complete"

    # Authenticate with credentials (still available in memory)
    JF_AUTH_HEADER='MediaBrowser Client="Setup", Device="install-script", DeviceId="install-001", Version="1.0.0"'
    jf_auth_json=$(python3 -c 'import json,sys; print(json.dumps({"Username":sys.argv[1],"Pw":sys.argv[2]}, ensure_ascii=False))' "$JF_USER" "$JF_PASS")
    auth_resp=$(http POST "$JF_BASE/Users/AuthenticateByName" \
        -H "Content-Type: application/json" \
        -H "X-Emby-Authorization: $JF_AUTH_HEADER" \
        -d "$jf_auth_json")
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
        local lib_status
        lib_status=$(echo "$existing_libs" | python3 -c "
import json,sys
libs=json.load(sys.stdin)
match=[l for l in libs if l['Name']=='${name}']
if not match:
    print('missing')
elif any('${path}' in loc for loc in match[0].get('Locations',[])):
    print('ok')
else:
    print('no_path')
" 2>/dev/null)

        if [[ "$lib_status" == "ok" ]]; then
            skip "Library '${name}' already configured (${path})"
        elif [[ "$lib_status" == "no_path" ]]; then
            # Library exists but has no folder path — add it
            resp=$(http POST "$JF_BASE/Library/VirtualFolders/Paths" \
                -H "$JF_AUTH" -H "Content-Type: application/json" \
                -d "{\"Name\":\"${name}\",\"PathInfo\":{\"Path\":\"${path}\"}}")
            ok_code "$resp" && ok "Path '${path}' added to existing library '${name}'" \
                || fail "Failed to add path to '${name}' library (HTTP $(code "$resp")): $(body "$resp")"
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

    # ── FFmpeg path ────────────────────────────────────────────
    ffmpeg_set=$(curl -sf "$JF_BASE/System/Configuration/encoding" -H "$JF_AUTH" 2>/dev/null \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('EncoderAppPath',''))" 2>/dev/null)
    if [[ -n "$ffmpeg_set" ]]; then
        skip "FFmpeg path already configured"
    else
        resp=$(http POST "$JF_BASE/System/MediaEncoder/Path" \
            -H "$JF_AUTH" -H "Content-Type: application/json" \
            -d '{"Path":"/usr/lib/jellyfin-ffmpeg/ffmpeg","PathType":"Custom"}')
        ok_code "$resp" && ok "FFmpeg path set (/usr/lib/jellyfin-ffmpeg/ffmpeg)" \
            || fail "Failed to set FFmpeg path (HTTP $(code "$resp"))"
    fi

    if is_placeholder "JELLYFIN_API_KEY"; then
        key_resp=$(http POST "$JF_BASE/Auth/Keys?app=MediaServer" -H "$JF_AUTH")
        if ok_code "$key_resp"; then
            # POST /Auth/Keys returns 204 with no body; fetch key from the list
            keys_body=$(curl -sf "$JF_BASE/Auth/Keys" -H "$JF_AUTH" 2>/dev/null || echo "{}")
            JF_API_KEY=$(python3 -c "
import json,sys
data=json.loads(sys.argv[1])
items=data.get('Items',[])
ms=[i for i in items if i.get('AppName')=='MediaServer']
print(ms[-1]['AccessToken'] if ms else '')" "$keys_body" 2>/dev/null)
            if [[ -n "$JF_API_KEY" ]]; then
                set_env "JELLYFIN_API_KEY" "$JF_API_KEY"
                ok "API key created: $JF_API_KEY"
            else
                fail "Could not find API key in key list"
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
        -d "{\"hostname\":\"jellyfin\",\"port\":8096,\"urlBase\":\"\",\"useSsl\":false,\"serverType\":2,\"email\":\"\",\"username\":\"${JF_USER}\",\"password\":\"${JF_PASS}\"}")

    init_body=$(body "$init_resp")
    if ok_code "$init_resp"; then
        ok "Jellyseerr authenticated with Jellyfin account '${JF_USER}'"
        sleep 3
    elif echo "$init_body" | grep -qi "already configured"; then
        skip "Jellyseerr Jellyfin connection already configured"
    else
        fail "Jellyseerr init failed (HTTP $(code "$init_resp")): $init_body"
        info "Complete manually at http://localhost:5055, then run: bash configure.sh"
    fi

    # Finalize the wizard so initialized=true
    fin_resp=$(curl -s -c "$JS_JAR" -b "$JS_JAR" -w "\n%{http_code}" \
        -X POST "$JS_BASE/api/v1/settings/initialize" \
        -H "Content-Type: application/json")
    if ok_code "$fin_resp"; then
        ok "Jellyseerr wizard finalized"
    else
        skip "Jellyseerr wizard already finalized"
    fi

    if is_placeholder "JELLYSEERR_API_KEY"; then
        js_config="$CONFIG/jellyseerr/settings.json"
        if [[ -f "$js_config" ]]; then
            jskey=$(python3 -c "import json; d=json.load(open('$js_config')); print(d.get('main',{}).get('apiKey',''))" 2>/dev/null)
        else
            # Docker Desktop overlay fallback — read from container
            jskey=$(docker exec jellyseerr cat /app/config/settings.json 2>/dev/null \
                | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('main',{}).get('apiKey',''))" 2>/dev/null)
        fi
        [[ -n "$jskey" ]] && { set_env "JELLYSEERR_API_KEY" "$jskey"; ok "Jellyseerr API key: $jskey"; }
    fi
    rm -f "$JS_JAR"
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
