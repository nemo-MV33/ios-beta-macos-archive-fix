---
name: ios-beta-macos-archive
description: Fix App Store Connect rejections (ITMS-90111 "Unsupported SDK or Xcode version", "Invalid Binary") that happen when archiving/exporting an iOS app while the Mac's host macOS is a beta build, even though Xcode itself is a stable release. Use when a user reports ITMS-90111, an "Invalid Binary" status in App Store Connect, mentions building on a beta macOS (e.g. "macOS 27" while Xcode 27 is still beta), or asks to archive/export/upload an iOS app for App Store submission.
---

# iOS archive on beta macOS host

## The problem

Apple's App Store Connect validator rejects binaries with `ITMS-90111: Unsupported SDK or Xcode version` (often surfacing later as a generic "Invalid Binary" status) even when:
- The installed Xcode is the latest **stable, non-beta** release (e.g. Xcode 26.6).
- The linked SDK is correct and non-beta (`DTSDKName`, `DTXcodeBuild`, Mach-O `LC_BUILD_VERSION` all check out).

The real cause: the **host macOS itself is a beta** (e.g. macOS 27.0 beta while only Xcode 27 beta / macOS 27 beta exist, no stable release yet). Every build records the host OS build number into the binary via `BuildMachineOSBuild` in `Info.plist`. A beta host build number typically ends in a trailing letter after the digits (e.g. `26A5378j`) — that's the tell. Apple's validator flags this even though nothing else about the toolchain is beta.

## Diagnosis (do this first, don't skip)

1. Confirm host OS is beta:
   ```
   sw_vers
   ```
   A `BuildVersion` with a trailing letter after the numeric suffix (e.g. `26A5378j`) is a beta seed. A clean public release build has no such trailing letter (e.g. `25F84`).

2. Confirm Xcode itself is NOT beta (rule out the more obvious cause first):
   ```
   /usr/bin/xcodebuild -version
   ls /Applications | grep -i xcode   # check for a separate Xcode-beta.app
   ```

3. Inspect the actual exported `.ipa`/`.app` metadata to see what got baked in:
   ```
   unzip -q Northly.ipa -d /tmp/ipa_check
   APP=$(find /tmp/ipa_check/Payload -maxdepth 1 -iname "*.app")
   plutil -p "$APP/Info.plist" | grep -iE "DT|BuildMachineOSBuild|CFBundleVersion"
   otool -l "$APP/<BinaryName>" | grep -A5 LC_BUILD_VERSION
   ```
   If `DTXcode`/`DTXcodeBuild`/`DTSDKName`/`LC_BUILD_VERSION sdk` all point to a stable, current Xcode/SDK, but `BuildMachineOSBuild` has the beta trailing-letter pattern — this is the bug, not a real SDK problem.

## Fix: patch `BuildMachineOSBuild` before final signing

Don't downgrade macOS or spin up CI unless the user wants that route. Instead, spoof the recorded host build to the latest known-stable public macOS release build number (look this up — e.g. web search "macOS Tahoe <version> build number" — don't guess; it must be a real released build, not the beta one).

1. Archive normally, explicitly pointing at the stable (non-beta) Xcode:
   ```
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
   xcodebuild -project <Proj>.xcodeproj -scheme <Scheme> -configuration Release \
     -destination "generic/platform=iOS" -archivePath ~/Desktop/App.xcarchive archive
   ```

2. Patch `BuildMachineOSBuild` **inside the archive**, before export — in the main `.app`'s `Info.plist` AND in every embedded `.appex` (widgets, extensions):
   ```
   APP=~/Desktop/App.xcarchive/Products/Applications/<AppName>.app
   /usr/libexec/PlistBuddy -c "Set :BuildMachineOSBuild <stable_build>" "$APP/Info.plist"
   for ext in "$APP"/PlugIns/*.appex; do
     /usr/libexec/PlistBuddy -c "Set :BuildMachineOSBuild <stable_build>" "$ext/Info.plist"
   done
   ```

3. Export with `xcodebuild -exportArchive` (NOT manual `codesign` — a manually-invoked `codesign` in a non-interactive shell often can't see the Distribution identity/private key; `-exportArchive`'s automatic signing can). This re-signs everything, picking up the patched plist:
   ```
   xcodebuild -exportArchive -archivePath ~/Desktop/App.xcarchive \
     -exportPath ~/Desktop/AppExport -exportOptionsPlist ~/Desktop/ExportOptions.plist
   ```
   Minimal `ExportOptions.plist`:
   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
       <key>method</key><string>app-store-connect</string>
       <key>teamID</key><string>YOUR_TEAM_ID</string>
       <key>signingStyle</key><string>automatic</string>
       <key>uploadSymbols</key><true/>
   </dict>
   </plist>
   ```

4. Verify before handing back the `.ipa`:
   ```
   unzip -q AppExport/App.ipa -d /tmp/ipa_final
   APP=$(find /tmp/ipa_final/Payload -maxdepth 1 -iname "*.app")
   plutil -p "$APP/Info.plist" | grep -iE "BuildMachineOSBuild|DT"
   codesign -dvv "$APP" | grep -iE "Authority|TeamIdentifier"
   codesign --verify --deep --strict "$APP" && echo OK
   ```
   Confirm: `BuildMachineOSBuild` is the stable build, signing `Authority` is `Apple Distribution: ...` (not `Apple Development`), and the embedded provisioning profile is a **Store**/distribution profile, not a Team/Development one.

5. Clean up temp extraction dirs (`/tmp/ipa_check`, `/tmp/ipa_final`, etc.) when done.

This only edits build metadata (a string in `Info.plist`), never app code, resources, or behavior — safe to do without re-testing the app.
