#!/bin/zsh
# Prints the push relay's request count for the last 24 h and 7 d from Cloudflare's analytics, and
# how many devices are registered, so the free tier (100,000 requests/day) is never a surprise.
# Needs CLOUDFLARE_API_TOKEN (with Account Analytics read + Workers KV read) and CLOUDFLARE_ACCOUNT_ID
# in Tools/release/.env. Run by hand or from a daily cron; exits 2 when the day is past the warn line.
set -u
cd "$(dirname "$0")/../.." || exit 1
[ -f Tools/release/.env ] && . Tools/release/.env
: "${CLOUDFLARE_API_TOKEN:?set in Tools/release/.env}" "${CLOUDFLARE_ACCOUNT_ID:?set in Tools/release/.env}"
WORKER="${RELAY_WORKER_NAME:-kitty-push-relay}"
WARN="${RELAY_WARN_PER_DAY:-60000}"

query() {
    local since="$1"
    curl -sS https://api.cloudflare.com/client/v4/graphql -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H 'Content-Type: application/json' \
        --data "$(python3 -c 'import json,sys; print(json.dumps({"query": "query($a:String!,$s:String!,$w:String!){viewer{accounts(filter:{accountTag:$a}){workersInvocationsAdaptive(limit:1000,filter:{datetime_geq:$s,scriptName:$w}){sum{requests errors}}}}}", "variables": {"a": sys.argv[1], "s": sys.argv[2], "w": sys.argv[3]}}))' "$CLOUDFLARE_ACCOUNT_ID" "$since" "$WORKER")" \
        | python3 -c 'import sys,json; d=json.load(sys.stdin); rows=d["data"]["viewer"]["accounts"][0]["workersInvocationsAdaptive"]; print(sum(r["sum"]["requests"] for r in rows), sum(r["sum"]["errors"] for r in rows))'
}
day=$(date -u -v-1d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ)
week=$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)
read -r d_req d_err <<< "$(query "$day")"
read -r w_req w_err <<< "$(query "$week")"
ns=$(grep -m1 '^id' server/push-relay/wrangler.toml | sed 's/.*"\(.*\)".*/\1/')
devices=$(curl -sS "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/storage/kv/namespaces/$ns/keys?prefix=dev:&limit=1000" -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("result",[])))' 2>/dev/null || echo '?')
printf 'relay %s: last 24h %s requests (%s errors) · last 7d %s (%s errors) · registered devices %s · free tier 100000/day\n' "$WORKER" "$d_req" "$d_err" "$w_req" "$w_err" "$devices"
[ "${d_req:-0}" -gt "$WARN" ] && { echo "WARNING: past $WARN requests in 24h — move the Worker to the paid plan (\$5/mo, 10M requests) or investigate abuse"; exit 2; }
exit 0
