#!/usr/bin/env bash
# Deploys the push relay (server/push-relay) to Cloudflare non-interactively and records its URL
# in Tools/release/.env as KITTY_PUSH_RELAY_URL, which the release script bakes into the app.
#
# Needs in Tools/release/.env:
#   CLOUDFLARE_API_TOKEN    (Edit Cloudflare Workers template)
#   CLOUDFLARE_ACCOUNT_ID
#   APNS_KEY_PATH           path to AuthKey_XXXXXXXXXX.p8 (the APNs key, not the App Store Connect one)
# The Team ID is read from ExportOptions.plist. Safe to re-run; secrets are overwritten in place.
set -euo pipefail
cd "$(dirname "$0")/../.."
[ -f Tools/release/.env ] && . Tools/release/.env
fail() { printf '\n%s\n' "$1" >&2; exit 1; }
for v in CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID APNS_KEY_PATH; do [ -n "${!v:-}" ] || fail "$v is not set in Tools/release/.env"; done
[ -f "$APNS_KEY_PATH" ] || fail "APNs key not found at $APNS_KEY_PATH"
export CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID

KEY_ID="$(basename "$APNS_KEY_PATH" .p8 | sed 's/^AuthKey_//')"
TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :teamID' Tools/release/ExportOptions.plist)"
[ ${#KEY_ID} -eq 10 ] || fail "Could not derive the Key ID from $APNS_KEY_PATH (expected AuthKey_XXXXXXXXXX.p8)"
echo "==> Key ID $KEY_ID, Team ID $TEAM_ID"

cd server/push-relay
W="npx --yes wrangler"

if grep -q REPLACE_WITH_KV_NAMESPACE_ID wrangler.toml; then
    echo "==> Creating KV namespace"
    OUT="$($W kv namespace create DEVICES 2>&1)" || { echo "$OUT"; fail "KV namespace creation failed"; }
    ID="$(echo "$OUT" | grep -oE 'id = "[0-9a-f]{32}"' | head -1 | grep -oE '[0-9a-f]{32}')"
    [ -n "$ID" ] || { echo "$OUT"; fail "Could not read the namespace id from wrangler's output"; }
    sed -i '' "s/REPLACE_WITH_KV_NAMESPACE_ID/$ID/" wrangler.toml
    echo "    namespace $ID"
fi

echo "==> Deploying worker"
OUT="$($W deploy 2>&1)" || { echo "$OUT"; fail "Deploy failed"; }
URL="$(echo "$OUT" | grep -oE 'https://[a-z0-9.-]+\.workers\.dev' | head -1)"
[ -n "$URL" ] || { echo "$OUT"; fail "Deploy succeeded but no workers.dev URL was printed"; }

echo "==> Setting secrets"
$W secret put APNS_KEY_P8 < "$APNS_KEY_PATH" >/dev/null
printf '%s' "$KEY_ID" | $W secret put APNS_KEY_ID >/dev/null
printf '%s' "$TEAM_ID" | $W secret put APNS_TEAM_ID >/dev/null

echo "==> Health check"
curl -fsS "$URL/v1/health" >/dev/null || fail "$URL/v1/health did not answer"

cd ../..
ENV=Tools/release/.env
if grep -q '^export KITTY_PUSH_RELAY_URL=' "$ENV"; then
    sed -i '' "s|^export KITTY_PUSH_RELAY_URL=.*|export KITTY_PUSH_RELAY_URL=$URL|" "$ENV"
else
    echo "export KITTY_PUSH_RELAY_URL=$URL" >> "$ENV"
fi
cat <<EOS

Relay is live at $URL and recorded in $ENV.
Next: ./Tools/release/testflight.sh bakes it into the app.
EOS
