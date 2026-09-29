#!/usr/bin/env bash
# Archive Kitty and upload it to TestFlight, non-interactively.
#
# Needs an App Store Connect API key, so no Apple ID password or 2FA prompt is involved.
# Configure it once by exporting these (or putting them in Tools/release/.env, which is gitignored):
#
#   ASC_KEY_ID=ABCD123456                 # the API key's Key ID
#   ASC_ISSUER_ID=aaaaaaaa-bbbb-....      # the Issuer ID from the Keys page
#   ASC_KEY_PATH=$HOME/.appstoreconnect/private_keys/AuthKey_ABCD123456.p8
#   KITTY_PUSH_RELAY_URL=https://kitty-push-relay.example.workers.dev   # optional: the push relay you deployed
#
# One-time setup that must happen in a browser first, because Apple allows no other route:
#   1. Accept any pending agreements in App Store Connect.
#   2. Create the app record for the bundle id below, named "Kitty: Hermes Agent UI".
# After that this script can run unattended for every subsequent build.

set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT="$PWD"
[ -f Tools/release/.env ] && . Tools/release/.env

PROJECT="Kitty.xcodeproj"
SCHEME="Kitty"
BUNDLE_ID="com.vorantx.kitty"
ARCHIVE_DIR="${ARCHIVE_DIR:-$ROOT/build/archives}"

fail() { printf '\n%s\n' "$1" >&2; exit 1; }

for var in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH; do
    [ -n "${!var:-}" ] || fail "$var is not set. See the header of this script."
done
[ -f "$ASC_KEY_PATH" ] || fail "API key not found at $ASC_KEY_PATH"

# Info.plist holds the $(MARKETING_VERSION) macro, so read the real value from the project.
MARKETING_VERSION="${MARKETING_VERSION:-$(grep -m1 'MARKETING_VERSION = ' "$PROJECT/project.pbxproj" | sed 's/.*= *//; s/;//')}"

# The build number is the iteration count: one more than the highest small build number App Store
# Connect already holds for this app (App Store Connect refuses a number it has already seen). The
# first ten builds used date-style numbers (up to 2609240140); those are ignored. The marketing
# version is 1.0.1 for the beta (1.0 was the date-numbered builds), then 1.2, 1.3, … and 2.0 for the
# App Store. Override with BUILD_NUMBER=.
next_build_number() {
    local token
    token="$(ASC_KEY_ID="$ASC_KEY_ID" ASC_ISSUER_ID="$ASC_ISSUER_ID" ASC_KEY_PATH="$ASC_KEY_PATH" swift Tools/release/asc-jwt.swift)" || return 1
    curl -sS --fail -H "Authorization: Bearer $token" \
        "https://api.appstoreconnect.apple.com/v1/builds?filter%5Bapp%5D=$ASC_APP_ID&limit=200&fields%5Bbuilds%5D=version" \
    | python3 -c '
import json, sys
versions = [b["attributes"]["version"] for b in json.load(sys.stdin)["data"]]
small = [int(v) for v in versions if v.isdigit() and int(v) < 100000]
print(max(small) + 1 if small else len(versions) + 1)'
}
ASC_APP_ID="${ASC_APP_ID:-6814980297}"
if [ -z "${BUILD_NUMBER:-}" ]; then
    BUILD_NUMBER="$(next_build_number)" || fail "Could not read the existing builds from App Store Connect to pick the next build number. Pass BUILD_NUMBER=<n> to override."
fi

ARCHIVE="$ARCHIVE_DIR/Kitty-$BUILD_NUMBER.xcarchive"
mkdir -p "$ARCHIVE_DIR"

AUTH=(-authenticationKeyPath "$ASC_KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID")

echo "==> Archiving $BUNDLE_ID $MARKETING_VERSION ($BUILD_NUMBER)"
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates \
    "${AUTH[@]}" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    MARKETING_VERSION="$MARKETING_VERSION" \
    KITTY_PUSH_RELAY_URL="${KITTY_PUSH_RELAY_URL:-}" \
    | grep -E 'error:|warning: .*(signing|provision)|ARCHIVE' || true

[ -d "$ARCHIVE" ] || fail "Archive was not produced. Re-run without the grep filter to see why."

echo "==> Exporting with manual distribution signing"
EXPORT_DIR="$ARCHIVE_DIR/export-$BUILD_NUMBER"
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist Tools/release/ExportOptions.plist \
    -exportPath "$EXPORT_DIR" \
    "${AUTH[@]}"

IPA="$(ls "$EXPORT_DIR"/*.ipa 2>/dev/null | head -1)"
[ -n "$IPA" ] || fail "No .ipa was produced in $EXPORT_DIR"

# Guard the one thing that silently breaks background push: a build signed for the sandbox
# APNs environment will never receive notifications sent to the production host.
# PlistBuddy cannot read a pipe ("Error Reading File: /dev/stdin"), so go through real files.
GUARD_TMP="$(mktemp -d)"
unzip -p "$IPA" 'Payload/*.app/embedded.mobileprovision' > "$GUARD_TMP/prov.cms" 2>/dev/null || true
security cms -D -i "$GUARD_TMP/prov.cms" -o "$GUARD_TMP/prov.plist" 2>/dev/null || true
APS="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:aps-environment' "$GUARD_TMP/prov.plist" 2>/dev/null || true)"
rm -rf "$GUARD_TMP"
[ "$APS" = "production" ] || fail "Expected aps-environment=production in the signed build, got '${APS:-absent}'."
echo "    signed with aps-environment=production"

echo "==> Uploading to TestFlight"
xcrun altool --upload-app --type ios --file "$IPA" \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

# Keep the App Store listing in step: attach this build to the version (created if needed) and
# refresh its screenshots from Tools/release/screenshots. Skipped with SKIP_LISTING=1.
if [ -z "${SKIP_LISTING:-}" ]; then
    echo "==> Updating the App Store listing (build + screenshots)"
    python3 Tools/release/asc-listing.py attach "$MARKETING_VERSION" "$BUILD_NUMBER" \
        && python3 Tools/release/asc-listing.py screenshots \
        || echo "(listing update failed; run Tools/release/asc-listing.py by hand)"
fi

cat <<EOS

Uploaded build $BUILD_NUMBER of version $MARKETING_VERSION.

Apple now processes it, which usually takes a few minutes. Internal testers get it automatically
once processing finishes; no review is involved. Export compliance is already answered in
Info.plist, so nothing should be waiting on you.
EOS
