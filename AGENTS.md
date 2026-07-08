# Agent instructions: ITMS-90111 / Invalid Binary on a beta macOS host

Use this when a user reports any of the following about an iOS/macOS app:

- `ITMS-90111: Unsupported SDK or Xcode version`
- An "Invalid Binary" status on a build in App Store Connect
- Confusion that they used the latest Xcode but still got a rejection blaming SDK/Xcode version
- They mention running a beta macOS (e.g. "I'm on macOS 27 but Xcode 27 is still beta")
- A request to archive, export, or upload an iOS app for App Store submission where the host machine might be on a beta OS

## Diagnose before touching anything

1. Check the host OS build:
   ```
   sw_vers
   ```
   A `BuildVersion` ending in a letter after the digits (e.g. `26A5378j`) is a beta seed build. A public release build has no trailing letter (e.g. `25F84`).

2. Rule out an actually-beta Xcode first, don't assume:
   ```
   /usr/bin/xcodebuild -version
   ls /Applications | grep -i xcode
   ```
   If there's an `Xcode-beta.app` sitting alongside a stable `Xcode.app`, confirm which one actually did the build (check `DEVELOPER_DIR`, and which app the user opened) before concluding the host OS is the cause.

3. Inspect the actual archive or exported `.ipa`:
   ```
   unzip -q App.ipa -d /tmp/ipa_check
   APP=$(find /tmp/ipa_check/Payload -maxdepth 1 -iname "*.app")
   plutil -p "$APP/Info.plist" | grep -iE "DT|BuildMachineOSBuild|CFBundleVersion"
   otool -l "$APP/<BinaryName>" | grep -A5 LC_BUILD_VERSION
   ```
   If `DTXcode`, `DTXcodeBuild`, `DTSDKName`, and the Mach-O `LC_BUILD_VERSION sdk` all point to a current, stable, non-beta release, but `BuildMachineOSBuild` has the beta trailing-letter pattern, that confirms the diagnosis: the binary itself is fine, the recorded build-host metadata is what's getting flagged.

Don't stop at step 1 and assume. Walk through all three before proposing the fix below, since a genuinely-beta Xcode or SDK looks similar at first glance but needs a different fix (install/select the stable Xcode instead).

## The fix

Find the latest publicly released (non-beta) macOS build number before doing anything. Search "macOS [current version] build number" or check `https://developer.apple.com/news/releases/`. Never guess or reuse a hardcoded value from an old run, macOS updates every few weeks and the target must be a real, currently-released build.

1. Archive with the confirmed-stable Xcode, explicit `DEVELOPER_DIR` so there's no ambiguity about which install got used:
   ```
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
   xcodebuild -project <Proj>.xcodeproj -scheme <Scheme> -configuration Release \
     -destination "generic/platform=iOS" -archivePath ~/Desktop/App.xcarchive archive
   ```

2. Patch `BuildMachineOSBuild` inside the archive, in the main `.app`'s `Info.plist` and in every `.appex` under `PlugIns/`, before export:
   ```
   APP=~/Desktop/App.xcarchive/Products/Applications/<AppName>.app
   /usr/libexec/PlistBuddy -c "Set :BuildMachineOSBuild <stable_build>" "$APP/Info.plist"
   for ext in "$APP"/PlugIns/*.appex; do
     [ -d "$ext" ] && /usr/libexec/PlistBuddy -c "Set :BuildMachineOSBuild <stable_build>" "$ext/Info.plist"
   done
   ```

3. Export through `xcodebuild -exportArchive`, not a manual `codesign` invocation. A bare `codesign` call from a non-interactive shell frequently can't reach the Distribution certificate's private key (it needs an interactive keychain unlock). The export step's automatic signing handles this correctly and re-signs using the patched `Info.plist`.
   ```
   xcodebuild -exportArchive -archivePath ~/Desktop/App.xcarchive \
     -exportPath ~/Desktop/AppExport -exportOptionsPlist ExportOptions.plist
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

4. Verify before handing the `.ipa` back to the user:
   ```
   unzip -q AppExport/App.ipa -d /tmp/ipa_final
   APP=$(find /tmp/ipa_final/Payload -maxdepth 1 -iname "*.app")
   plutil -p "$APP/Info.plist" | grep -iE "BuildMachineOSBuild|DT"
   codesign -dvv "$APP" | grep -iE "Authority|TeamIdentifier"
   codesign --verify --deep --strict "$APP" && echo OK
   ```
   Confirm all three: `BuildMachineOSBuild` shows the stable build, `Authority` is `Apple Distribution: ...` (not `Apple Development`), and the embedded provisioning profile is a Store/distribution profile, not a Team/Development one (check with `security cms -D -i "$APP/embedded.mobileprovision"`).

5. Clean up temp extraction directories when finished (`/tmp/ipa_check`, `/tmp/ipa_final`, etc).

## Guardrails

- This only edits a metadata string in `Info.plist`. It never touches app code, assets, entitlements, or behavior. Don't ask for extra confirmation beyond what you'd normally ask before running build/export commands.
- Don't silently pick a stable build number without checking. If you can't verify what the current release build is, say so and ask, rather than hardcoding something that might already be outdated.
- If step 3 in diagnosis shows the SDK or Xcode itself is genuinely beta (not just the host OS), this fix doesn't apply, point the user at installing/selecting a stable Xcode instead.
