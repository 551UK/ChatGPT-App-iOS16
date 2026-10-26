#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
VERSION="0.19.0"
WORK="$ROOT/build/work"
DIST="$ROOT/dist"
mkdir -p "$WORK" "$DIST"

# The TrollStore flavor of the same Gecko 158.0.1 release supports iOS 16.
# The separately uploaded Jailbroken IPA targets older jailbreak install paths.
URL="https://github.com/minh-ton/reynard-browser/releases/download/${VERSION}/Reynard-TrollStore.tipa"
curl -fL --retry 4 --retry-delay 2 "$URL" -o "$WORK/Reynard-TrollStore.tipa"
unzip -q "$WORK/Reynard-TrollStore.tipa" -d "$WORK/unpacked"
APP="$(find "$WORK/unpacked/Payload" -maxdepth 1 -name '*.app' -type d | head -1)"
[ -n "$APP" ] && [ -d "$APP" ] || { echo 'Missing Reynard app'; exit 1; }

# Retain original JIT and memory permissions from TrollStore's entitlement set.
mkdir -p "$WORK/entitlements"
save_entitlements() {
    local exe="$1" label="$2"
    ldid -e "$exe" > "$WORK/entitlements/$label.plist" || true
}
MAIN_EXE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")"
save_entitlements "$APP/$MAIN_EXE" main
for PLUG in "$APP"/PlugIns/*.appex; do
    [ -d "$PLUG" ] || continue
    EXE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLUG/Info.plist")"
    save_entitlements "$PLUG/$EXE" "$EXE"
done

# Build a dedicated Objective-C shell against Apple's iOS SDK. Gecko remains
# the original upstream runtime, including its mandatory helper extension.
mkdir -p "$APP/Frameworks"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos --find clang)"
"$CLANG" -arch arm64 -isysroot "$SDK" -miphoneos-version-min=16.0 \
    -fobjc-arc -fblocks -O2 -dynamiclib \
    -framework Foundation -framework UIKit \
    -Wno-deprecated-declarations \
    "$ROOT/src/ChatGPTShell.m" -o "$APP/Frameworks/ChatGPTShell.dylib"

python3 "$ROOT/scripts/inject.py" "$APP/$MAIN_EXE"
python3 "$ROOT/scripts/rebrand.py" "$APP"
python3 "$ROOT/scripts/icon.py" "$APP"

# Set matching identifiers in existing entitlements where appropriate.
python3 - "$WORK/entitlements" <<'PY'
import sys, pathlib, plistlib
base=pathlib.Path(sys.argv[1])
for f in base.glob("*.plist"):
    try: obj=plistlib.loads(f.read_bytes())
    except Exception: continue
    if not isinstance(obj,dict): continue
    for k in ("application-identifier","com.apple.application-identifier"):
        if k in obj and isinstance(obj[k],str):
            obj[k]=obj[k].replace("com.minh-ton.Reynard", "com.551uk.chatgptgecko")
    for k in ("com.apple.security.application-groups",):
        if k in obj and isinstance(obj[k],list):
            obj[k]=[s.replace("com.minh-ton.Reynard", "com.551uk.chatgptgecko") if isinstance(s,str) else s for s in obj[k]]
    f.write_bytes(plistlib.dumps(obj))
PY

sign_binary() {
    local exe="$1" label="$2"
    local ent="$WORK/entitlements/$label.plist"
    if [ -s "$ent" ] && grep -q '<plist' "$ent"; then
        ldid -S"$ent" "$exe"
    else
        ldid -S "$exe"
    fi
}
sign_binary "$APP/Frameworks/ChatGPTShell.dylib" nothing
for PLUG in "$APP"/PlugIns/*.appex; do
    [ -d "$PLUG" ] || continue
    EXE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLUG/Info.plist")"
    sign_binary "$PLUG/$EXE" "$EXE"
done
sign_binary "$APP/$MAIN_EXE" main

# Package as a real standalone ChatGPT application (not a tweak or web clip).
# TrollStore resigns and registers the app on installation.
NEWAPP="$WORK/unpacked/Payload/ChatGPT.app"
if [ "$APP" != "$NEWAPP" ]; then mv "$APP" "$NEWAPP"; fi
OUTPUT="$DIST/ChatGPT-Gecko-iOS16.ipa"
(cd "$WORK/unpacked" && zip -qyr "$OUTPUT" Payload)
unzip -t "$OUTPUT" >/dev/null
/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$NEWAPP/Info.plist"
ls -lh "$OUTPUT"
