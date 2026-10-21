#!/bin/zsh
# Archives the iOS app, signed by the Certly Inc team, and uploads it to TestFlight.
#
#   LIVELY_TEAM_ID=XXXXXXXXXX Tools/release/testflight.sh           # archive + upload
#   LIVELY_TEAM_ID=XXXXXXXXXX Tools/release/testflight.sh --no-upload
#
# Uses automatic signing with the Apple ID signed into Xcode (apple@ian.sh).
# The first run registers the sh.ian.lively App ID. The App Store Connect app
# record must exist before the upload step.
set -euo pipefail

: "${LIVELY_TEAM_ID:?Set LIVELY_TEAM_ID to the Certly Inc team ID}"
ROOT="${0:A:h:h:h}"
OUT="${LIVELY_RELEASE_DIR:-$ROOT/build/release}"
# Build numbers must increase on every upload; a UTC timestamp always does.
BUILD_NUMBER="${LIVELY_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
ARCHIVE="$OUT/Lively-$BUILD_NUMBER.xcarchive"
UPLOAD=1
[[ "${1:-}" == "--no-upload" ]] && UPLOAD=0

mkdir -p "$OUT"
echo "Archiving build $BUILD_NUMBER for team $LIVELY_TEAM_ID…"
xcodebuild archive \
  -project "$ROOT/Lively.xcodeproj" \
  -scheme Lively \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$LIVELY_TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  > "$OUT/archive-$BUILD_NUMBER.log" 2>&1 \
  || { grep -E "error:|Signing|provision" "$OUT/archive-$BUILD_NUMBER.log" | tail -20; tail -15 "$OUT/archive-$BUILD_NUMBER.log"; echo "Archive failed; full log: $OUT/archive-$BUILD_NUMBER.log" >&2; exit 1; }

DESTINATION=export
(( UPLOAD )) && DESTINATION=upload
cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$DESTINATION</string>
  <key>teamID</key><string>$LIVELY_TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>testFlightInternalTestingOnly</key><false/>
</dict>
</plist>
EOF

echo "Exporting ($DESTINATION)…"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT/export-$BUILD_NUMBER" \
  -allowProvisioningUpdates

if (( UPLOAD )); then
  echo "Uploaded build $BUILD_NUMBER. It appears in App Store Connect › TestFlight after processing (usually 5–15 min)."
else
  echo "Exported to $OUT/export-$BUILD_NUMBER"
fi
