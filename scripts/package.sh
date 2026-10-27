#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
VERSION="0.19.0"
WORK="$ROOT/build/work"
DIST="$ROOT/dist"
mkdir -p "$WORK" "$DIST"

# Match the working standalone Reynard installation on Dopamine: use the
# upstream jailbroken flavor rather than wrapping the TrollStore flavor in a DEB.
URL="https://github.com/minh-ton/reynard-browser/releases/download/${VERSION}/Reynard-Jailbroken.ipa"
curl -fL --retry 4 --retry-delay 2 "$URL" -o "$WORK/Reynard-Jailbroken.ipa"
unzip -q "$WORK/Reynard-Jailbroken.ipa" -d "$WORK/unpacked"
APP="$(find "$WORK/unpacked/Payload" -maxdepth 1 -name '*.app' -type d | head -1)"
[ -n "$APP" ] && [ -d "$APP" ] || { echo 'Missing Reynard app'; exit 1; }

# Retain the jailbroken build's original JIT and memory permissions.
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
    -framework Foundation -framework UIKit -framework CoreGraphics -framework QuartzCore -framework AVFoundation -lsqlite3 \
    -Wno-deprecated-declarations \
    "$ROOT/src/ChatGPTShell.m" \
    "$ROOT/src/ChatGPTDataMaintenance.m" \
    "$ROOT/src/ChatGPTDownloadOverlay.m" \
    "$ROOT/src/ChatGPTExternalLinks.m" \
    -o "$APP/Frameworks/ChatGPTShell.dylib"

python3 "$ROOT/scripts/inject.py" "$APP/$MAIN_EXE"
python3 "$ROOT/scripts/rebrand.py" "$APP"
python3 "$ROOT/scripts/icon.py" "$APP"

# Bundle a plain ChatGPT knot image for the native startup spinner.
curl -fLsS --retry 4 --retry-delay 2 \
  "https://i.logos-download.com/114223/31076-s640-9e4b46076f911162aebfdb80fad3fef6.png/ChatGPT_Logo_2024-s640.png?dl=" \
  -o "$APP/StartupLoaderIcon.png"


# Extend Reynard's already-loaded built-in ReaderView WebExtension with a
# ChatGPT-only content script. This gives the dedicated app a presentation
# layer inside Gecko without modifying ChatGPT's networking or message logic.
READERVIEW_MANIFEST="$(find "$APP" -path '*/extensions/readerview/manifest.json' -type f | head -1)"
[ -n "$READERVIEW_MANIFEST" ] && [ -f "$READERVIEW_MANIFEST" ] || {
    echo "ERROR: built-in ReaderView extension manifest not found" >&2
    exit 1
}
python3 - "$READERVIEW_MANIFEST" "$ROOT/web/chatgpt-app-shell.js" <<'PY'
import json, pathlib, shutil, sys
manifest_path = pathlib.Path(sys.argv[1])
script_source = pathlib.Path(sys.argv[2])
extension_dir = manifest_path.parent
script_name = "chatgpt-app-shell.js"
shutil.copy2(script_source, extension_dir / script_name)

manifest = json.loads(manifest_path.read_text())
scripts = manifest.setdefault("content_scripts", [])
scripts = [entry for entry in scripts if script_name not in entry.get("js", [])]
scripts.append({
    "matches": [
        "https://chatgpt.com/*",
        "https://www.chatgpt.com/*",
        "https://chat.openai.com/*"
    ],
    "js": [script_name],
    "run_at": "document_start"
})
manifest["content_scripts"] = scripts
# Bump the built-in extension version so Gecko refreshes the installed copy
# for users upgrading from the previous ChatGPT package.
manifest["version"] = "1.0.34"
manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
print("Injected ChatGPT app presentation content script into", manifest_path)
PY

# Preserve the upstream unsandboxed/JIT entitlements. If ldid cannot extract
# a binary's signature (some TIPA builds have none), use the pinned upstream
# entitlement manifests rather than accidentally signing with no entitlements.
fetch_entitlements() {
    local label="$1" upstream="$2"
    local target="$WORK/entitlements/$label.plist"
    if ! grep -q '<plist' "$target" 2>/dev/null; then
        echo "Restoring upstream JIT entitlements for $label"
        curl -fLsS --retry 3 "https://raw.githubusercontent.com/minh-ton/reynard-browser/${VERSION}/$upstream" -o "$target"
    fi
}
fetch_entitlements main browser/Reynard/Entitlements/Reynard.private.entitlements
fetch_entitlements "Reynard Helper" browser/Helper/Entitlements/Reynard-Helper.private.entitlements

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
            obj[k]=obj[k].replace("com.minh-ton.Reynard", "com.551uk.chatgptios16")
    for k in ("com.apple.security.application-groups",):
        if k in obj and isinstance(obj[k],list):
            obj[k]=[s.replace("com.minh-ton.Reynard", "com.551uk.chatgptios16") if isinstance(s,str) else s for s in obj[k]]
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

# Confirm that Gecko's parent app and helper retain the JIT permissions.
ldid -e "$APP/$MAIN_EXE" > "$WORK/entitlements/main-verified.plist"
grep -q 'com.apple.private.security.no-sandbox' "$WORK/entitlements/main-verified.plist" || {
    echo "ERROR: missing Gecko JIT parent entitlement" >&2; exit 1;
}
ldid -e "$APP/PlugIns/Reynard Helper.appex/Reynard Helper" > "$WORK/entitlements/helper-verified.plist"
grep -q 'extended-virtual-addressing' "$WORK/entitlements/helper-verified.plist" || {
    echo "ERROR: missing Gecko helper entitlement" >&2; exit 1;
}

# Package as a real standalone ChatGPT application (not a tweak or web clip).
# The IPA remains available for testing, but the rootless DEB is the primary target.
NEWAPP="$WORK/unpacked/Payload/ChatGPT.app"
if [ "$APP" != "$NEWAPP" ]; then mv "$APP" "$NEWAPP"; fi
OUTPUT="$DIST/ChatGPT-Gecko-iOS16.ipa"
(cd "$WORK/unpacked" && zip -qyr "$OUTPUT" Payload)
unzip -t "$OUTPUT" >/dev/null
/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$NEWAPP/Info.plist"
ls -lh "$OUTPUT"

# Build the Settings preference bundle on top of the preserved 0.19.0-22
# app shell/web baseline. The only added runtime source is the isolated,
# login-safe data-maintenance module used by the real Settings controls.
: "${THEOS:?THEOS must point to a Theos checkout}"

SETTINGS_ICON_SOURCE="$NEWAPP/StartupLoaderIcon.png"
[ -s "$SETTINGS_ICON_SOURCE" ] || { echo "ERROR: black ChatGPT settings icon source missing" >&2; exit 1; }

# Use the black ChatGPT knot icon for the main Settings/Tweaks list only.
# The in-page hero is deliberately text-only.
python3 - "$SETTINGS_ICON_SOURCE" "$ROOT/prefs/Resources/icon.png" <<'PY'
from PIL import Image
from pathlib import Path
import sys

source = Image.open(sys.argv[1]).convert("RGBA")
target = Path(sys.argv[2])
target.parent.mkdir(parents=True, exist_ok=True)
source.resize((29, 29), Image.Resampling.LANCZOS).save(target)
PY

make -C "$ROOT/prefs" clean all stage FINALPACKAGE=1 THEOS="$THEOS"

PREF_BUNDLE="$(find "$ROOT/prefs/.theos" -type d -path '*/Library/PreferenceBundles/ChatGPTPrefs.bundle' | head -1)"
[ -n "$PREF_BUNDLE" ] && [ -d "$PREF_BUNDLE" ] || {
    echo "ERROR: ChatGPTPrefs.bundle was not staged" >&2
    exit 1
}
PREF_EXE="$PREF_BUNDLE/ChatGPTPrefs"
[ -s "$PREF_EXE" ] || { echo "ERROR: ChatGPTPrefs executable missing" >&2; exit 1; }

# Sign the staged bundle executable before copying it into the manually-built
# DEB. This does not touch the ChatGPT application or its entitlements.
ldid -S "$PREF_EXE"

# Build an independent rootless app package. Its filesystem directory is
# distinct from standalone Reynard and registered with its own fresh bundle ID.
# No MobileSubstrate injection is required.
PKG="$ROOT/build/deb-root"
mkdir -p \
    "$PKG/var/jb/Applications" \
    "$PKG/var/jb/Library/PreferenceBundles" \
    "$PKG/var/jb/Library/PreferenceLoader/Preferences" \
    "$PKG/DEBIAN"
ditto "$NEWAPP" "$PKG/var/jb/Applications/ChatGPT.app"
ditto "$PREF_BUNDLE" "$PKG/var/jb/Library/PreferenceBundles/ChatGPTPrefs.bundle"
cp "$ROOT/prefs/PreferenceLoader.plist" \
   "$PKG/var/jb/Library/PreferenceLoader/Preferences/ChatGPT.plist"
cp "$ROOT/prefs/Resources/icon.png" \
   "$PKG/var/jb/Library/PreferenceLoader/Preferences/ChatGPT.png"
cat > "$PKG/DEBIAN/control" <<'CONTROL'
Package: com.551uk.chatgptgecko
Name: ChatGPT
Version: 0.19.0-48
Architecture: iphoneos-arm64
Maintainer: 551UK
Author: 551UK
Section: Applications
Depends: firmware (>= 16.0), preferenceloader
Description: ChatGPT App by 551UK. Built for iOS 16 to provide a seamless modern ChatGPT experience without the limitations of the outdated legacy app.
CONTROL
cat > "$PKG/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
export PATH="/var/jb/usr/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
if command -v uicache >/dev/null 2>&1; then uicache -a || true; fi
exit 0
POSTINST
cat > "$PKG/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
set -e
export PATH="/var/jb/usr/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
if command -v uicache >/dev/null 2>&1; then uicache -a || true; fi
exit 0
POSTRM
chmod 0755 "$PKG/DEBIAN/postinst" "$PKG/DEBIAN/postrm"
DEB="$DIST/com.551uk.chatgptgecko_0.19.0-48_iphoneos-arm64.deb"
dpkg-deb --root-owner-group -Zxz --build "$PKG" "$DEB"
dpkg-deb --field "$DEB" Package Architecture
ls -lh "$DEB"
