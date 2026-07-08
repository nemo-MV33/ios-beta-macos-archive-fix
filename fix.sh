#!/usr/bin/env bash
#
# Fixes ITMS-90111 / "Invalid Binary" caused by archiving on a beta macOS host.
# See README.md for the full explanation.
#
# Fill in the variables below, then run: ./fix.sh

set -euo pipefail

# --- edit these ---
XCODEPROJ="YourApp.xcodeproj"          # or use XCWORKSPACE below instead
# XCWORKSPACE="YourApp.xcworkspace"
SCHEME="YourApp"
TEAM_ID="YOURTEAMID"
STABLE_BUILD="25F84"                    # latest RELEASED macOS build number — look this up, don't guess
XCODE_APP="/Applications/Xcode.app"     # your stable, non-beta Xcode install
ARCHIVE_PATH="$HOME/Desktop/${SCHEME}_patched.xcarchive"
EXPORT_PATH="$HOME/Desktop/${SCHEME}_export"
# ------------------

DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
export DEVELOPER_DIR

echo "==> Archiving with $($DEVELOPER_DIR/usr/bin/xcodebuild -version | head -1)"

PROJECT_FLAG=(-project "$XCODEPROJ")
if [ -n "${XCWORKSPACE:-}" ]; then
  PROJECT_FLAG=(-workspace "$XCWORKSPACE")
fi

xcodebuild "${PROJECT_FLAG[@]}" -scheme "$SCHEME" -configuration Release \
  -destination "generic/platform=iOS" -archivePath "$ARCHIVE_PATH" archive

APP=$(find "$ARCHIVE_PATH/Products/Applications" -maxdepth 1 -iname "*.app" | head -1)
if [ -z "$APP" ]; then
  echo "Couldn't find the .app inside the archive, something's off." >&2
  exit 1
fi

echo "==> Patching BuildMachineOSBuild -> $STABLE_BUILD"
echo "    (was: $(/usr/libexec/PlistBuddy -c 'Print :BuildMachineOSBuild' "$APP/Info.plist" 2>/dev/null || echo unknown))"

/usr/libexec/PlistBuddy -c "Set :BuildMachineOSBuild $STABLE_BUILD" "$APP/Info.plist"

if [ -d "$APP/PlugIns" ]; then
  for ext in "$APP"/PlugIns/*.appex; do
    [ -d "$ext" ] || continue
    echo "    also patching $(basename "$ext")"
    /usr/libexec/PlistBuddy -c "Set :BuildMachineOSBuild $STABLE_BUILD" "$ext/Info.plist"
  done
fi

EXPORT_OPTIONS=$(mktemp /tmp/exportoptions.XXXXXX.plist)
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>automatic</string>
    <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST

echo "==> Exporting (this re-signs with your patched Info.plist)"
rm -rf "$EXPORT_PATH"
xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" -exportOptionsPlist "$EXPORT_OPTIONS"

rm -f "$EXPORT_OPTIONS"

IPA=$(find "$EXPORT_PATH" -maxdepth 1 -iname "*.ipa" | head -1)
echo
echo "==> Done: $IPA"
echo "==> Verifying..."

TMP_CHECK=$(mktemp -d)
unzip -q "$IPA" -d "$TMP_CHECK"
CHECK_APP=$(find "$TMP_CHECK/Payload" -maxdepth 1 -iname "*.app" | head -1)

echo "    BuildMachineOSBuild: $(/usr/libexec/PlistBuddy -c 'Print :BuildMachineOSBuild' "$CHECK_APP/Info.plist")"
codesign -dvv "$CHECK_APP" 2>&1 | grep -iE "Authority|TeamIdentifier" | sed 's/^/    /'
codesign --verify --deep --strict "$CHECK_APP" && echo "    signature: OK"

rm -rf "$TMP_CHECK"

echo
echo "Upload $IPA through Transporter or Xcode Organizer."
