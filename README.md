# Fixing ITMS-90111 / "Invalid Binary" when you're stuck on a beta macOS

App Store Connect just rejected your build with this:

```
ITMS-90111: Unsupported SDK or Xcode version - App submissions must use
the latest Xcode and SDK Release Candidates (RC).
```

...and you're sure you archived with the newest, non-beta Xcode. You're not crazy and you didn't miss an update. I lost an entire afternoon to this before finding the actual cause, so here it is written down.

## What's actually going on

The error text blames your Xcode/SDK version. That's almost never the real problem. Check it yourself:

```bash
xcodebuild -version                       # your Xcode is fine
xcrun --sdk iphoneos --show-sdk-version   # your SDK is fine
```

The actual culprit is your **host macOS**. If you're running a beta build (common if you update your Mac the day a new OS drops, or just never got around to going back to a stable release), every archive you build gets stamped with the host machine's OS build number. This lands in a key called `BuildMachineOSBuild`, inside `Info.plist`, no matter which Xcode did the compiling.

Beta build numbers have a tell: a letter tacked onto the end after the digits, like `26A5378j`. A public release doesn't have that, it looks like `25F84`.

App Store Connect reads that field, sees the beta fingerprint, and rejects the whole binary with the "unsupported SDK/Xcode" message, even when the toolchain itself is completely current and legitimate.

### Confirm this is your problem

```bash
sw_vers
```

Check `BuildVersion`. A trailing letter after the numbers means a beta host. That's the entire diagnosis.

You can also check inside the exported `.ipa` directly:

```bash
unzip -q YourApp.ipa -d /tmp/ipa_check
APP=$(find /tmp/ipa_check/Payload -maxdepth 1 -iname "*.app")
plutil -p "$APP/Info.plist" | grep -iE "DT|BuildMachineOSBuild"
```

If `DTXcode`, `DTXcodeBuild`, and `DTSDKName` all point at a current, stable release, but `BuildMachineOSBuild` has the trailing letter, this is the exact bug this repo is about.

## Manual fix, no tools, no AI, just Terminal

You don't need to downgrade macOS, wipe a partition, or borrow someone else's clean Mac. All of that works, but it's overkill. One string in the archive needs correcting before the final signature goes on. Do it in four steps.

**Step 1: Archive normally**, pointing straight at your stable, non-beta Xcode. Replace `YourApp.xcodeproj` and `YourScheme` with your project's actual names.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project YourApp.xcodeproj -scheme YourScheme -configuration Release \
  -destination "generic/platform=iOS" -archivePath ~/Desktop/YourApp.xcarchive archive
```

If your project uses a `.xcworkspace` instead (CocoaPods, SPM workspaces, etc.), swap `-project YourApp.xcodeproj` for `-workspace YourApp.xcworkspace`.

**Step 2: Patch `BuildMachineOSBuild`** in the archive, before anything gets exported or signed. Do this for the main `.app`'s `Info.plist`, and for every `.appex` inside it (widgets, share extensions, whatever your app ships).

First, find the latest **released** (non-beta) macOS build number. Search "macOS [current version] build number" and use whatever comes back, don't reuse the example below blindly.

```bash
APP=~/Desktop/YourApp.xcarchive/Products/Applications/YourApp.app
/usr/libexec/PlistBuddy -c "Set :BuildMachineOSBuild 25F84" "$APP/Info.plist"

for ext in "$APP"/PlugIns/*.appex; do
  /usr/libexec/PlistBuddy -c "Set :BuildMachineOSBuild 25F84" "$ext/Info.plist"
done
```

If your app has no extensions, the `for` loop just does nothing and that's fine.

**Step 3: Export with `xcodebuild -exportArchive`.** Don't try to run `codesign` by hand here, it usually can't reach your Distribution certificate's private key from a plain terminal session because that key lives in a keychain that wants an interactive unlock. Letting `-exportArchive` do the signing sidesteps that, and it picks up the `Info.plist` you just edited.

```bash
xcodebuild -exportArchive -archivePath ~/Desktop/YourApp.xcarchive \
  -exportPath ~/Desktop/YourAppExport -exportOptionsPlist ExportOptions.plist
```

You'll need an `ExportOptions.plist` next to that command. Save this as a new file with that exact name, and fill in your team ID (find it at developer.apple.com under Membership):

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

**Step 4: Check your work before uploading anything.**

```bash
unzip -q YourAppExport/YourApp.ipa -d /tmp/ipa_final
APP=$(find /tmp/ipa_final/Payload -maxdepth 1 -iname "*.app")
plutil -p "$APP/Info.plist" | grep -iE "BuildMachineOSBuild"
codesign -dvv "$APP" | grep -iE "Authority|TeamIdentifier"
codesign --verify --deep --strict "$APP" && echo OK
```

You're looking for three things: the patched build number in `BuildMachineOSBuild`, `Authority=Apple Distribution: ...` (not `Apple Development`), and `OK` at the end.

That's the whole fix. Upload the `.ipa` through Transporter or Xcode Organizer the way you normally would.

## Running it as a script instead

[`fix.sh`](fix.sh) in this repo does steps 1 through 4 for you. Open it, fill in the variables at the top of the file (project path, scheme, team ID, current stable build number), then run `./fix.sh` from your project folder.

## Using an AI coding agent

If you drive your builds through an AI coding assistant, drop the matching file into your setup and it'll recognize this problem on its own the next time it shows up:

- **Claude Code**: copy [`SKILL.md`](SKILL.md) into `~/.claude/skills/ios-beta-macos-archive/SKILL.md`.
- **Codex, Cursor, or anything else that reads an `AGENTS.md`**: copy [`AGENTS.md`](AGENTS.md) into your project root, or point your agent at this repo.

Both files describe the same diagnosis and fix as above, just phrased for an agent to act on directly.

## Why this is safe to do

Nothing about the app changes: not the SDK it links against, not the APIs it calls, not a single line of your code. `BuildMachineOSBuild` is metadata about the machine that happened to compile the binary. It has zero effect on how the app runs. You're correcting a field that was only wrong because your Mac is ahead of the public release train, which is a completely ordinary state for a working iOS developer to be in.

## Disclaimer

Not official Apple guidance. Apple's validation could change tomorrow and stop caring about this field, or start checking something new. If this stops working for you, diff your exported `Info.plist` against a build made on a fully public macOS release and see what else differs. Confirmed working on macOS 27 beta / Xcode 26.6, mid-2026.
