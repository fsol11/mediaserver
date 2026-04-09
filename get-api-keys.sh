#!/usr/bin/env bash
# ============================================================
# get-api-keys.sh
# Extracts API keys from each service's config file and
# writes them into .env automatically.
#
# Run this AFTER docker compose up -d and all services have
# finished their first-time initialization (usually 1-2 min).
#
# Usage:
#   bash get-api-keys.sh
#
# Safe to re-run: already-set keys are skipped unless you
# pass --force to overwrite everything.
# ============================================================

set -uo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$STACK_DIR/.env"
CONFIG_DIR="$STACK_DIR/config"
FORCE=false

[[ "${1:-}" == "--force" ]] && FORCE=true

# ── Colours ────────────────────────────────────────────────
GRN='\033[0;32m'; YLW='\033[1;33m'; RED='\033[0;31m'; BLD='\033[1m'; NC='\033[0m'
ok()      { echo -e "  ${GRN}✓${NC}  $*"; }
skip()    { echo -e "  ${YLW}–${NC}  $*"; }
fail()    { echo -e "  ${RED}✗${NC}  $*"; }
section() { echo -e "\n${BLD}── $* ${NC}$(printf '─%.0s' $(seq 1 $((48 - ${#1}))))"; }

# ── Helpers ────────────────────────────────────────────────

# Read current value of a key from .env
env_val() { grep -m1 "^${1}=" "$ENV_FILE" | cut -d= -f2-; }

# Return true if the key still holds a placeholder value
is_placeholder() {
    local val
    val=$(env_val "$1")
    [[ -z "$val" || "$val" == *"your_"* || "$val" == *"_here"* ]]
}

# Overwrite a key's value in .env (in-place, preserves comments)
set_env() {
    local key="$1" val="$2"
    sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
    ok "$key = $val"
}

# Should we process this key?
should_update() {
    $FORCE || is_placeholder "$1"
}

# Wait up to $3 seconds for a file to exist, printing dots
wait_for_file() {
    local file="$1" label="$2" timeout="${3:-90}"
    local elapsed=0
    if [[ -f "$file" ]]; then return 0; fi
    echo -ne "  Waiting for ${label} config"
    while [[ ! -f "$file" ]] && (( elapsed < timeout )); do
        sleep 3; elapsed=$((elapsed + 3)); echo -n "."
    done
    echo ""
    [[ -f "$file" ]]
}

# Wait up to $3 seconds for an HTTP endpoint to respond
wait_for_http() {
    local url="$1" label="$2" timeout="${3:-90}"
    local elapsed=0
    echo -ne "  Waiting for ${label} HTTP"
    while (( elapsed < timeout )); do
        if curl -sf --max-time 2 "$url" &>/dev/null; then
            echo ""; return 0
        fi
        sleep 3; elapsed=$((elapsed + 3)); echo -n "."
    done
    echo ""
    return 1
}

# Parse <ApiKey>VALUE</ApiKey> from an *arr XML config
xml_api_key() { grep -oP '(?<=<ApiKey>)[^<]+' "$1" 2>/dev/null | head -1; }

# ── Sanity checks ──────────────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env not found at $ENV_FILE"; exit 1
fi

if ! command -v docker &>/dev/null; then
    echo "ERROR: docker not found"; exit 1
fi

echo ""
echo "============================================================"
echo " Media Server — API Key Extractor"
echo " Stack:  $STACK_DIR"
echo " Env:    $ENV_FILE"
[[ $FORCE == true ]] && echo " Mode:   FORCE (overwriting existing keys)"
echo "============================================================"

# ============================================================
# 1. SONARR
# ============================================================
section "Sonarr"
if should_update "SONARR_API_KEY"; then
    config="$CONFIG_DIR/sonarr/config.xml"
    if wait_for_file "$config" "Sonarr"; then
        key=$(xml_api_key "$config")
        if [[ -n "$key" ]]; then
            set_env "SONARR_API_KEY" "$key"
        else
            fail "Could not parse key — check $config"
        fi
    else
        fail "Config not found after timeout. Is Sonarr running?"
        fail "  docker compose logs sonarr"
    fi
else
    skip "SONARR_API_KEY already set (use --force to overwrite)"
fi

# ============================================================
# 2. RADARR
# ============================================================
section "Radarr"
if should_update "RADARR_API_KEY"; then
    config="$CONFIG_DIR/radarr/config.xml"
    if wait_for_file "$config" "Radarr"; then
        key=$(xml_api_key "$config")
        if [[ -n "$key" ]]; then
            set_env "RADARR_API_KEY" "$key"
        else
            fail "Could not parse key — check $config"
        fi
    else
        fail "Config not found after timeout. Is Radarr running?"
    fi
else
    skip "RADARR_API_KEY already set"
fi

# ============================================================
# 3. PROWLARR
# ============================================================
section "Prowlarr"
if should_update "PROWLARR_API_KEY"; then
    config="$CONFIG_DIR/prowlarr/config.xml"
    if wait_for_file "$config" "Prowlarr"; then
        key=$(xml_api_key "$config")
        if [[ -n "$key" ]]; then
            set_env "PROWLARR_API_KEY" "$key"
        else
            fail "Could not parse key — check $config"
        fi
    else
        fail "Config not found after timeout. Is Prowlarr running?"
    fi
else
    skip "PROWLARR_API_KEY already set"
fi

# ============================================================
# 4. BAZARR
# ============================================================
section "Bazarr"
if should_update "BAZARR_API_KEY"; then
    # Bazarr may write config.yaml at one of two locations
    config=""
    for candidate in \
        "$CONFIG_DIR/bazarr/config.yaml" \
        "$CONFIG_DIR/bazarr/config/config.yaml"
    do
        if [[ -f "$candidate" ]]; then config="$candidate"; break; fi
    done

    if [[ -z "$config" ]]; then
        # Not found yet — wait for the most common path
        config="$CONFIG_DIR/bazarr/config.yaml"
        wait_for_file "$config" "Bazarr" 90 || {
            # Try alternate path one more time
            config="$CONFIG_DIR/bazarr/config/config.yaml"
            wait_for_file "$config" "Bazarr (alt path)" 10 || config=""
        }
    fi

    if [[ -n "$config" && -f "$config" ]]; then
        # auth.apikey: VALUE  (YAML, no quotes usually)
        key=$(grep -oP '(?<=apikey:\s{0,10})\S+' "$config" 2>/dev/null | head -1)
        if [[ -n "$key" ]]; then
            set_env "BAZARR_API_KEY" "$key"
        else
            fail "Could not parse apikey from $config"
            fail "  You can find it in Bazarr → Settings → General → Security"
        fi
    else
        fail "Bazarr config not found. Is Bazarr running?"
    fi
else
    skip "BAZARR_API_KEY already set"
fi

# ============================================================
# 5. JELLYSEERR
# ============================================================
section "Jellyseerr"
if should_update "JELLYSEERR_API_KEY"; then
    config="$CONFIG_DIR/jellyseerr/settings.json"
    if wait_for_file "$config" "Jellyseerr"; then
        # Try python3 first, fall back to grep
        key=""
        if command -v python3 &>/dev/null; then
            key=$(python3 -c "
import json, sys
try:
    d = json.load(open('$config'))
    print(d.get('main', {}).get('apiKey', ''))
except Exception as e:
    sys.exit(0)
" 2>/dev/null)
        fi
        if [[ -z "$key" ]] && command -v jq &>/dev/null; then
            key=$(jq -r '.main.apiKey // empty' "$config" 2>/dev/null)
        fi
        if [[ -z "$key" ]]; then
            # last-resort grep
            key=$(grep -oP '(?<="apiKey":")[^"]+' "$config" 2>/dev/null | head -1)
        fi

        if [[ -n "$key" ]]; then
            set_env "JELLYSEERR_API_KEY" "$key"
        else
            fail "Could not parse apiKey from $config"
            fail "  You can find it in Jellyseerr → Settings → General"
        fi
    else
        fail "Jellyseerr config not found. Has it been set up via the web UI?"
        fail "  Visit http://localhost:5055 and complete the setup wizard first."
    fi
else
    skip "JELLYSEERR_API_KEY already set"
fi

# ============================================================
# 6. JELLYFIN  (requires REST API — no key in a plain file)
# ============================================================
section "Jellyfin"
if should_update "JELLYFIN_API_KEY"; then
    JELLYFIN_URL="http://localhost:8096"

    if ! wait_for_http "$JELLYFIN_URL/health" "Jellyfin" 60; then
        fail "Jellyfin is not responding at $JELLYFIN_URL"
        fail "  Make sure the container is running and the setup wizard is complete."
    else
        echo ""
        echo "  Jellyfin does not store API keys in a plain file."
        echo "  Enter your Jellyfin admin credentials to create one automatically."
        echo ""
        read -rp "  Jellyfin admin username: " JF_USER
        read -rsp "  Jellyfin admin password: " JF_PASS
        echo ""

        AUTH_HDR='MediaBrowser Client="KeyExtractor", Device="Script", DeviceId="keyscript-001", Version="1.0.0"'

        AUTH_RESP=$(curl -sf -X POST "$JELLYFIN_URL/Users/AuthenticateByName" \
            -H "Content-Type: application/json" \
            -H "X-Emby-Authorization: $AUTH_HDR" \
            -d "{\"Username\":\"${JF_USER}\",\"Pw\":\"${JF_PASS}\"}" 2>/dev/null) || true

        JF_TOKEN=""
        if [[ -n "$AUTH_RESP" ]]; then
            if command -v python3 &>/dev/null; then
                JF_TOKEN=$(python3 -c "
import json, sys
try:
    print(json.loads('''${AUTH_RESP}''').get('AccessToken',''))
except: pass
" 2>/dev/null)
            fi
            if [[ -z "$JF_TOKEN" ]] && command -v jq &>/dev/null; then
                JF_TOKEN=$(echo "$AUTH_RESP" | jq -r '.AccessToken // empty' 2>/dev/null)
            fi
            if [[ -z "$JF_TOKEN" ]]; then
                JF_TOKEN=$(echo "$AUTH_RESP" | grep -oP '(?<="AccessToken":")[^"]+' | head -1)
            fi
        fi

        if [[ -z "$JF_TOKEN" ]]; then
            fail "Authentication failed. Check username/password."
            fail "  You can create an API key manually:"
            fail "  Jellyfin → Dashboard → API Keys → + button"
        else
            # Create a named API key
            KEY_RESP=$(curl -sf -X POST \
                "$JELLYFIN_URL/Auth/Keys?app=MediaServer" \
                -H "Authorization: MediaBrowser Token=\"$JF_TOKEN\"" \
                2>/dev/null) || true

            JF_KEY=""
            if [[ -n "$KEY_RESP" ]]; then
                if command -v python3 &>/dev/null; then
                    JF_KEY=$(python3 -c "
import json
try:
    print(json.loads('''${KEY_RESP}''').get('AccessToken',''))
except: pass
" 2>/dev/null)
                fi
                if [[ -z "$JF_KEY" ]] && command -v jq &>/dev/null; then
                    JF_KEY=$(echo "$KEY_RESP" | jq -r '.AccessToken // empty' 2>/dev/null)
                fi
                if [[ -z "$JF_KEY" ]]; then
                    JF_KEY=$(echo "$KEY_RESP" | grep -oP '(?<="AccessToken":")[^"]+' | head -1)
                fi
            fi

            if [[ -n "$JF_KEY" ]]; then
                set_env "JELLYFIN_API_KEY" "$JF_KEY"
            else
                fail "API key creation failed — unexpected response:"
                fail "  $KEY_RESP"
                fail "  Create manually: Jellyfin → Dashboard → API Keys → +"
            fi
        fi
    fi
else
    skip "JELLYFIN_API_KEY already set"
fi

# ============================================================
# 7. Apply updated keys — restart services that consume them
# ============================================================
section "Applying keys"
echo "  Restarting services that use API keys..."
docker compose -f "$STACK_DIR/docker-compose.yml" up -d \
    unpackerr recyclarr homepage 2>/dev/null \
    && ok "unpackerr, recyclarr, homepage restarted" \
    || fail "Could not restart services — run: docker compose up -d"

# ============================================================
# Summary
# ============================================================
echo ""
echo "============================================================"
echo " Summary of current .env API keys:"
echo "============================================================"
for k in SONARR_API_KEY RADARR_API_KEY PROWLARR_API_KEY \
          BAZARR_API_KEY JELLYFIN_API_KEY JELLYSEERR_API_KEY; do
    val=$(env_val "$k")
    if is_placeholder "$k"; then
        echo -e "  ${RED}MISSING${NC}  $k"
    else
        echo -e "  ${GRN}OK${NC}      $k = ${val:0:12}..."
    fi
done
echo ""
echo "  Done. If any keys are still MISSING, follow POST_SETUP.md"
echo "  to retrieve them from each service's web UI."
echo ""
