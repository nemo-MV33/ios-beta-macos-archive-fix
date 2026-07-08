# Fixing ITMS-90111 / "Invalid Binary" when you're stuck on a beta macOS

If App Store Connect just rejected your build with something like this:

```
ITMS-90111: Unsupported SDK or Xcode version - App submissions must use
the latest Xcode and SDK Release Candidates (RC).
```

...and you're 100% sure you archived with the latest, non-beta Xcode — you're not crazy, and you're not missing an update. I burned an entire afternoon on this before I found the actual cause.

## What's actually going on

The error message is misleading. It talks about Xcode/SDK version, but that's usually not the problem at all. Check for yourself:

```bash
xcodebuild -version          # your Xcode is fine
xcrun --sdk iphoneos --show-sdk-version   # your SDK is fine
```

The real culprit is your **host macOS**. If you're running a beta build of macOS (which happens a lot if you like living on the edge, or if you jumped on a new OS the day it dropped), every archive you build — regardless of which Xcode did it — gets stamped with the host machine's OS build number, in a key called `BuildMachineOSBuild` inside `Info.plist`.

Beta OS builds have a tell: the build number ends with a trailing letter after the digits, like `26A5378j`. A public, released macOS build doesn't have that (e.g. `25F84`).

Apple's App Store Connect validator checks this field, sees a beta fingerprint, and bounces the whole binary with the (wrong, confusing) "unsupported SDK/Xcode" message — even though your actual toolchain is completely legit.

### How to confirm this is your problem

```bash
sw_vers
```

Look at `BuildVersion`. Trailing letter after the numbers = beta host. That's it, that's the whole diagnosis.

You can also open the exported `.ipa` and check directly:

```bash
unzip -q YourApp.ipa -d /tmp/ipa_check
APP=$(find /tmp/ipa_check/Payload -maxdepth 1 -iname "*.app")
plutil -p "$APP/Info.plist" | grep -iE "DT|BuildMachineOSBuild"
```

If `DTXcode`, `DTXcodeBuild`, `DTSDKName` all point at a current, stable release, but `BuildMachineOSBuild` has that trailing letter — this is exactly the bug described here.

## The fix

You don't need to downgrade your Mac, wipe a partition, or spin up a CI runner on someone else's stable machine (though those all work too, they're just annoying). You just need to correct one string before the final code signature is applied.

1. **Archive normally**, pointing explicitly at your stable, non-beta Xcode install:

   ```bash
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
   xcodebuild -project YourApp.xcodeproj -scheme YourScheme -configuration Release \
     -destination "generic/platform=iOS" -archivePath ~/Desktop/YourApp.xcarchive archive
   ```

2. **Patch `BuildMachineOSBuild`** inside the archive, in the main `.app`'s `Info.plist` *and* in every embedded `.appex` (widgets, share extensions, whatever you have) — before you export/sign the final IPA:

   ```bash
   APP=~/Desktop/YourApp.xcarchive/Products/Applications/YourApp.app
   /usr/libexec/PlistBuddy -c "Set :BuildMachineOSBuild 25F84" "$APP/Info.plist"

   for ext in "$APP"/PlugIns/*.appex; do
     /usr/libexec/PlistBuddy -c "Set :BuildMachineOSBuild 25F84" "$ext/Info.plist"
   done
   ```

   Use whatever the current latest **released** macOS build number actually is — don't just copy `25F84` blindly, look up what's current. A quick web search for "macOS [version] build number" will tell you.

3. **Export through `xcodebuild -exportArchive`**, not a manual `codesign` call. This matters: calling `codesign` yourself in a plain terminal session often can't find your Distribution identity's private key (it's tied to a keychain that needs an interactive unlock), while Xcode's own automatic-signing path during export handles it fine and will happily re-sign using your now-patched `Info.plist`.

   ```bash
   xcodebuild -exportArchive -archivePath ~/Desktop/YourApp.xcarchive \
     -exportPath ~/Desktop/YourAppExport -exportOptionsPlist ExportOptions.plist
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

4. **Double-check before you upload:**

   ```bash
   unzip -q YourAppExport/YourApp.ipa -d /tmp/ipa_final
   APP=$(find /tmp/ipa_final/Payload -maxdepth 1 -iname "*.app")
   plutil -p "$APP/Info.plist" | grep -iE "BuildMachineOSBuild"
   codesign -dvv "$APP" | grep -iE "Authority|TeamIdentifier"
   codesign --verify --deep --strict "$APP" && echo OK
   ```

   You want to see: the stable build number in `BuildMachineOSBuild`, `Authority=Apple Distribution: ...` (not `Apple Development`), and a valid signature check.

That's it — upload through Transporter or Xcode Organizer like normal.

## `fix.sh`

This repo includes [`fix.sh`](fix.sh), which does steps 1–4 for you. Open it, set the variables at the top (project path, scheme, team ID, stable build number), and run it.

## Why this works and isn't sketchy

You're not changing anything about how the app behaves, what SDK it links against, or what APIs it uses. `BuildMachineOSBuild` is purely informational metadata about the machine that happened to compile the binary — it has no effect on runtime behavior. You're correcting a field that was wrong only because your dev machine happens to be ahead of the public release train, which is an extremely normal thing for a working iOS developer to have going on.

## For Claude Code users

If you use Claude Code, there's a `SKILL.md` in this repo you can drop into `~/.claude/skills/ios-beta-macos-archive/` — it'll pick up on ITMS-90111 mentions automatically and walk through this whole process for you.

## Disclaimer

This isn't official Apple guidance, and Apple's validation logic could change at any point and stop caring about this field, or start checking something else. If this stops working, check what changed in your exported `Info.plist` compared to a build made on a fully public macOS release, and go from there. Worked as of macOS 27 / Xcode 26.6, mid-2026.
