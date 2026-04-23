#!/usr/bin/env bash
#
# bin/auth.sh — manage entries in the Auth KV namespace.
#
# Each entry maps a caller-supplied UUID to a callback suffix. The worker
# accepts requests at GET /<uuid>/<callback> only when <callback> equals
# Auth.get(<uuid>).
#
# Usage:
#   bin/auth.sh list                       # list uuid → callback pairs
#   bin/auth.sh get    <uuid>              # print the callback for <uuid>
#   bin/auth.sh set    <callback>          # create; uuid is generated for you
#   bin/auth.sh delete <uuid>              # remove

set -euo pipefail

cd "$(dirname "$0")/.."

ENV_FILE=".env"

fail() { printf '\033[0;31m[auth]\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$ENV_FILE" ] || fail "$ENV_FILE not found — run bin/deploy.sh first"

# shellcheck disable=SC1090
set -a; . "./$ENV_FILE"; set +a

: "${KV_AUTH_ID:?KV_AUTH_ID not set in .env}"

if [ -x "./node_modules/.bin/wrangler" ]; then
    WRANGLER="./node_modules/.bin/wrangler"
elif command -v wrangler >/dev/null 2>&1; then
    WRANGLER="wrangler"
elif command -v npx >/dev/null 2>&1; then
    WRANGLER="npx --yes wrangler"
else
    fail "wrangler not found. Run: npm install"
fi

TOKEN_RE='^[A-Za-z0-9_-]{8,128}$'

validate_token() {
    local label="$1" value="$2"
    [[ "$value" =~ $TOKEN_RE ]] \
        || fail "$label must match $TOKEN_RE (8–128 chars, [A-Za-z0-9_-])"
}

usage() {
    cat >&2 <<'EOF'
Usage:
  bin/auth.sh list
  bin/auth.sh get    <uuid>
  bin/auth.sh set    <callback>       # uuid is generated automatically
  bin/auth.sh delete <uuid>
EOF
    exit 1
}

cmd="${1:-}"; shift || true

case "$cmd" in
    list)
        # Cloudflare's KV list API only returns key names, so fan out one
        # `kv key get` per uuid to show callback suffixes alongside.
        keys_json=$($WRANGLER kv key list --namespace-id="$KV_AUTH_ID" --remote)
        if command -v jq >/dev/null 2>&1; then
            names=$(printf '%s' "$keys_json" | jq -r '.[].name')
        else
            names=$(printf '%s' "$keys_json" \
                | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"' \
                | sed -E 's/.*"([^"]+)"$/\1/')
        fi

        if [ -z "$names" ]; then
            echo "(no entries)"
            exit 0
        fi

        printf '%-40s  %s\n' UUID CALLBACK
        printf '%-40s  %s\n' "----" "--------"
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            callback=$($WRANGLER kv key get --namespace-id="$KV_AUTH_ID" --remote "$name" 2>/dev/null || echo '<error>')
            printf '%-40s  %s\n' "$name" "$callback"
        done <<<"$names"
        ;;
    get)
        [ $# -eq 1 ] || usage
        validate_token uuid "$1"
        $WRANGLER kv key get --namespace-id="$KV_AUTH_ID" --remote "$1"
        ;;
    set)
        [ $# -eq 1 ] || usage
        validate_token callback "$1"
        command -v uuidgen >/dev/null 2>&1 \
            || fail "uuidgen not found — required to generate uuids"
        uuid=$(uuidgen | tr '[:upper:]' '[:lower:]')
        $WRANGLER kv key put --namespace-id="$KV_AUTH_ID" --remote "$uuid" "$1"
        echo
        echo "Created auth entry:"
        echo "  uuid:     $uuid"
        echo "  callback: $1"
        echo "  path:     /$uuid/$1"
        ;;
    delete|del|rm)
        [ $# -eq 1 ] || usage
        validate_token uuid "$1"
        $WRANGLER kv key delete --namespace-id="$KV_AUTH_ID" --remote "$1"
        ;;
    ""|-h|--help|help)
        usage
        ;;
    *)
        fail "unknown subcommand: $cmd"
        ;;
esac
