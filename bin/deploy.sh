#!/usr/bin/env bash
#
# bin/deploy.sh — deploy the oauth-relay Cloudflare Worker.
#
# First run (no .env):
#   - Ensures you are logged in to Cloudflare
#   - Creates the OAuthCallback and Auth KV namespaces
#   - Persists their IDs to .env
#   - Generates wrangler.toml from wrangler.toml.template
#   - Deploys the worker
#
# Subsequent runs (.env present):
#   - Loads IDs from .env
#   - Verifies both namespaces still exist in your Cloudflare account
#   - Regenerates wrangler.toml
#   - Deploys the worker

set -euo pipefail

cd "$(dirname "$0")/.."

ENV_FILE=".env"
TEMPLATE="wrangler.toml.template"
CONFIG="wrangler.toml"

log()  { printf '\033[0;36m[deploy]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[deploy]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[0;31m[deploy]\033[0m %s\n' "$*" >&2; exit 1; }

# ---- prerequisites ------------------------------------------------------

if [ ! -f "$TEMPLATE" ]; then
    fail "missing $TEMPLATE — cannot generate $CONFIG"
fi

# Prefer a project-local wrangler if npm deps are installed.
if [ -x "./node_modules/.bin/wrangler" ]; then
    WRANGLER="./node_modules/.bin/wrangler"
elif command -v wrangler >/dev/null 2>&1; then
    WRANGLER="wrangler"
elif command -v npx >/dev/null 2>&1; then
    WRANGLER="npx --yes wrangler"
else
    fail "wrangler not found. Run: npm install"
fi

log "using wrangler: $WRANGLER"

# ---- auth ---------------------------------------------------------------

if ! $WRANGLER whoami >/dev/null 2>&1; then
    log "not logged in to Cloudflare — launching 'wrangler login'"
    $WRANGLER login
fi

$WRANGLER whoami >/dev/null 2>&1 || fail "still not authenticated after login"

# ---- resolve KV ids -----------------------------------------------------

# Extracts the 32-char hex KV namespace id from any wrangler create output
# (handles both TOML-style and JSON-style output from wrangler v3/v4).
extract_id() {
    grep -oE '[a-f0-9]{32}' | head -1
}

create_namespace() {
    local binding="$1"
    log "creating KV namespace for binding '$binding'"
    local out
    out=$($WRANGLER kv namespace create "$binding" 2>&1) \
        || { printf '%s\n' "$out" >&2; fail "failed to create KV namespace '$binding'"; }
    printf '%s\n' "$out" >&2
    local id
    id=$(printf '%s\n' "$out" | extract_id)
    [ -n "$id" ] || fail "could not parse KV id from wrangler output for '$binding'"
    printf '%s' "$id"
}

verify_namespace() {
    local id="$1"
    local binding="$2"
    if ! $WRANGLER kv namespace list 2>/dev/null | grep -q "$id"; then
        fail "KV namespace for '$binding' (id=$id) not found in your Cloudflare account. \
Remove .env to recreate, or fix the id manually."
    fi
}

if [ -f "$ENV_FILE" ]; then
    log ".env found — loading existing KV ids"
    # shellcheck disable=SC1090
    set -a; . "./$ENV_FILE"; set +a

    : "${KV_OAUTH_CALLBACK_ID:?KV_OAUTH_CALLBACK_ID not set in .env}"
    : "${KV_AUTH_ID:?KV_AUTH_ID not set in .env}"

    log "verifying KV namespaces exist"
    verify_namespace "$KV_OAUTH_CALLBACK_ID" "OAuthCallback"
    verify_namespace "$KV_AUTH_ID" "Auth"
else
    log ".env not found — bootstrapping fresh KV namespaces"
    KV_OAUTH_CALLBACK_ID=$(create_namespace OAuthCallback)
    KV_AUTH_ID=$(create_namespace Auth)

    umask 077
    cat > "$ENV_FILE" <<EOF
KV_OAUTH_CALLBACK_ID=$KV_OAUTH_CALLBACK_ID
KV_AUTH_ID=$KV_AUTH_ID
EOF
    log "saved KV ids to $ENV_FILE (chmod 600)"
    export KV_OAUTH_CALLBACK_ID KV_AUTH_ID
fi

# ---- render config ------------------------------------------------------

log "generating $CONFIG from $TEMPLATE"
# Use '|' delimiters so ids (which are hex only) never clash with sed separators.
sed \
    -e "s|__KV_OAUTH_CALLBACK_ID__|$KV_OAUTH_CALLBACK_ID|g" \
    -e "s|__KV_AUTH_ID__|$KV_AUTH_ID|g" \
    "$TEMPLATE" > "$CONFIG"

# ---- deploy -------------------------------------------------------------

log "deploying worker"
$WRANGLER deploy

log "done"
