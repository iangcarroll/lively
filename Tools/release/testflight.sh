#!/bin/bash
# Archive/export a Release build. Upload requires an explicit --upload.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${LIVELY_RELEASE_DIR:-$ROOT/build/release}"
TEAM="${LIVELY_TEAM_ID:-}"
BUILD_NUMBER="${LIVELY_BUILD_NUMBER:-}"
CONFIG="${LIVELY_RELEASE_CONFIG:-}"
BUNDLE_ID="${LIVELY_APP_BUNDLE_ID-}"
BUNDLE_ID_SET="${LIVELY_APP_BUNDLE_ID+x}"
APP_GROUP="${LIVELY_APP_GROUP-}"
APP_GROUP_SET="${LIVELY_APP_GROUP+x}"
URL_SCHEME="${LIVELY_URL_SCHEME-}"
URL_SCHEME_SET="${LIVELY_URL_SCHEME+x}"
BROKER_URL="${LIVELY_KEY_BROKER_URL-}"
BROKER_URL_SET="${LIVELY_KEY_BROKER_URL+x}"
UPLOAD=0
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage: Tools/release/testflight.sh --team TEAMID --build-number NUMBER [options]

Creates a signed iOS Release archive and exports an IPA. It does not upload
unless --upload is supplied. Signing may create/update provisioning profiles.

  --team ID             Apple Developer Program Team ID (or LIVELY_TEAM_ID)
  --build-number N      Increasing build number (or LIVELY_BUILD_NUMBER)
  --config FILE         Optional xcconfig (or LIVELY_RELEASE_CONFIG)
  --bundle-id ID        Main app ID (or LIVELY_APP_BUNDLE_ID)
  --app-group ID        Shared group (or LIVELY_APP_GROUP)
  --url-scheme SCHEME   Widget/deep-link scheme (or LIVELY_URL_SCHEME)
  --broker-url URL      HTTPS broker, or '' to disable (LIVELY_KEY_BROKER_URL)
  --output DIR          Artifact directory (or LIVELY_RELEASE_DIR)
  --upload              Upload to App Store Connect after archiving
  --no-upload           Archive/export only (the default)
  --dry-run             Show configuration/commands without changing files
  --help                Show this help

Flag values override environment values, then the optional xcconfig, then the
project defaults. Both targets inherit the selected signing team and version;
the widget ID is always the main app ID followed by .widgets.
USAGE
}

die() { printf 'Error: %s\n' "$*" >&2; exit 2; }
require_value() { [[ "$#" -ge 2 ]] || die "$1 requires a value"; }

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --team) require_value "$@"; TEAM="$2"; shift 2 ;;
    --build-number) require_value "$@"; BUILD_NUMBER="$2"; shift 2 ;;
    --config) require_value "$@"; CONFIG="$2"; shift 2 ;;
    --bundle-id) require_value "$@"; BUNDLE_ID="$2"; BUNDLE_ID_SET=1; shift 2 ;;
    --app-group) require_value "$@"; APP_GROUP="$2"; APP_GROUP_SET=1; shift 2 ;;
    --url-scheme) require_value "$@"; URL_SCHEME="$2"; URL_SCHEME_SET=1; shift 2 ;;
    --broker-url) require_value "$@"; BROKER_URL="$2"; BROKER_URL_SET=1; shift 2 ;;
    --output) require_value "$@"; OUT="$2"; shift 2 ;;
    --upload) UPLOAD=1; shift ;;
    --no-upload) UPLOAD=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || die 'Set --team or LIVELY_TEAM_ID to your 10-character Team ID.'
# Stay within the documented 4/2/2 component limits, without a development suffix.
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]{0,3}(\.[0-9]{1,2}){0,2}$ ]] || die 'Set --build-number or LIVELY_BUILD_NUMBER (for example, 1 or 42.1).'
id_pattern='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'
if [[ -n "$BUNDLE_ID_SET" ]]; then
  [[ "$BUNDLE_ID" =~ $id_pattern && "${#BUNDLE_ID}" -le 247 ]] || die 'Invalid app bundle ID.'
fi
if [[ -n "$APP_GROUP_SET" ]]; then
  [[ "$APP_GROUP" == group.* && "${APP_GROUP#group.}" =~ $id_pattern && "${#APP_GROUP}" -le 255 ]] || die 'Invalid App Group ID (expected group.<reverse-DNS ID>).'
fi
if [[ -n "$URL_SCHEME_SET" ]]; then
  [[ "$URL_SCHEME" =~ ^[A-Za-z][A-Za-z0-9+.-]*$ ]] || die 'Invalid URL scheme.'
fi
if [[ -n "$BROKER_URL_SET" && -n "$BROKER_URL" ]]; then
  broker_pattern='^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]+)?([/?][^[:space:]#\"\\$]*)?$'
  [[ "$BROKER_URL" =~ $broker_pattern ]] || die 'Broker URL must be an HTTPS URL without credentials, a fragment, or build-setting expressions; use an empty value to disable it.'
  [[ "$BROKER_URL" != *'/*'* && "$BROKER_URL" != *'*/'* ]] || die 'Percent-encode asterisks in the broker URL to avoid xcconfig block comments.'
fi
[[ -n "$OUT" ]] || die 'Output directory cannot be empty.'
[[ "$OUT" = /* ]] || OUT="$PWD/$OUT"
if [[ -n "$CONFIG" ]]; then
  [[ "$CONFIG" = /* ]] || CONFIG="$PWD/$CONFIG"
  [[ -f "$CONFIG" && -r "$CONFIG" ]] || die "Cannot read xcconfig: $CONFIG"
  [[ "$CONFIG" != *$'\n'* && "$CONFIG" != *'"'* && "$CONFIG" != *'\'* ]] || die 'Unsupported character in xcconfig path.'
fi

ARCHIVE="$OUT/Lively-$BUILD_NUMBER.xcarchive"
EXPORT_DIR="$OUT/export-$BUILD_NUMBER"
OVERRIDES="$OUT/Release-$BUILD_NUMBER.xcconfig"
EXPORT_OPTIONS="$OUT/ExportOptions-$BUILD_NUMBER.plist"
DESTINATION=export
if [[ "$UPLOAD" -eq 1 ]]; then DESTINATION=upload; fi

# Apply explicit values after the local config. No config is executed as shell.
# This also makes precedence independent of xcodebuild's -xcconfig precedence.
write_overrides() {
  if [[ -n "$CONFIG" ]]; then printf '#include "%s"\n' "$CONFIG"; fi
  printf 'DEVELOPMENT_TEAM = %s\nCODE_SIGN_STYLE = Automatic\nCURRENT_PROJECT_VERSION = %s\n' "$TEAM" "$BUILD_NUMBER"
  if [[ -n "$BUNDLE_ID_SET" ]]; then printf 'LIVELY_APP_BUNDLE_ID = %s\n' "$BUNDLE_ID"; fi
  if [[ -n "$APP_GROUP_SET" ]]; then printf 'LIVELY_APP_GROUP = %s\n' "$APP_GROUP"; fi
  if [[ -n "$URL_SCHEME_SET" ]]; then printf 'LIVELY_URL_SCHEME = %s\n' "$URL_SCHEME"; fi
  if [[ -n "$BROKER_URL_SET" ]]; then
    # xcconfig treats // as a comment; $() expands to an empty build setting.
    local escaped_slashes='/$()/'
    printf 'LIVELY_KEY_BROKER_URL = %s\n' "${BROKER_URL//\/\//$escaped_slashes}"
  fi
}

archive_command=(xcodebuild archive -project "$ROOT/Lively.xcodeproj" -scheme Lively
  -configuration Release -destination 'generic/platform=iOS' -archivePath "$ARCHIVE"
  -xcconfig "$OVERRIDES" -allowProvisioningUpdates)
export_command=(xcodebuild -exportArchive -archivePath "$ARCHIVE"
  -exportOptionsPlist "$EXPORT_OPTIONS" -exportPath "$EXPORT_DIR" -allowProvisioningUpdates)

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf 'Dry run: Release archive; destination=%s; no files or provisioning changes.\n' "$DESTINATION"
  printf '\nConfiguration to write to %s:\n' "$OVERRIDES"
  write_overrides
  printf '\nArchive command:\n'; printf '%q ' "${archive_command[@]}"; printf '\n'
  printf '\nExport command (%s):\n' "$DESTINATION"; printf '%q ' "${export_command[@]}"; printf '\n'
  exit 0
fi

command -v xcodebuild >/dev/null || die 'xcodebuild is required; install and select Xcode first.'
[[ ! -e "$ARCHIVE" && ! -e "$EXPORT_DIR" ]] || die 'Artifacts already exist for this build number; select a new build number or output directory.'
mkdir -p "$OUT"
write_overrides > "$OVERRIDES"
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$DESTINATION</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>testFlightInternalTestingOnly</key><false/>
</dict>
</plist>
PLIST

printf 'Archiving Release build %s for team %s…\n' "$BUILD_NUMBER" "$TEAM"
if ! "${archive_command[@]}" > "$OUT/archive-$BUILD_NUMBER.log" 2>&1; then
  tail -30 "$OUT/archive-$BUILD_NUMBER.log" >&2
  die "Archive failed; full log: $OUT/archive-$BUILD_NUMBER.log"
fi
printf 'Exporting (%s)…\n' "$DESTINATION"
if ! "${export_command[@]}" > "$OUT/export-$BUILD_NUMBER.log" 2>&1; then
  tail -30 "$OUT/export-$BUILD_NUMBER.log" >&2
  die "Export failed; full log: $OUT/export-$BUILD_NUMBER.log"
fi
if [[ "$UPLOAD" -eq 1 ]]; then
  printf 'Uploaded build %s. Check App Store Connect after processing.\n' "$BUILD_NUMBER"
else
  printf 'Exported build %s to %s\n' "$BUILD_NUMBER" "$EXPORT_DIR"
fi
