#!/usr/bin/env python3
"""Rebrand a pinned Reynard TIPA without removing Gecko or its helper extensions."""
import argparse
import os
import plistlib
from pathlib import Path

APP_ID = "com.551uk.chatgptgecko"
NAME = "ChatGPT"

def modify_plist(path, changes):
    with open(path, "rb") as f:
        data = plistlib.load(f)
    changes(data)
    with open(path, "wb") as f:
        plistlib.dump(data, f, sort_keys=False)

def main():
    p = argparse.ArgumentParser()
    p.add_argument("app", type=Path)
    a = p.parse_args()
    app = a.app
    info = app / "Info.plist"

    def update_app(d):
        d["CFBundleIdentifier"] = APP_ID
        d["CFBundleDisplayName"] = NAME
        d["CFBundleName"] = NAME
        d["NSCameraUsageDescription"] = "Attach photos to ChatGPT."
        d["NSPhotoLibraryUsageDescription"] = "Attach photos to ChatGPT."
        d["NSMicrophoneUsageDescription"] = "Use your microphone for ChatGPT voice features."
        d["NSSpeechRecognitionUsageDescription"] = "Use speech input in ChatGPT."
        # Avoid hijacking the original browser's reynard:// deep links.
        d.pop("CFBundleURLTypes", None)
        icons = d.setdefault("CFBundleIcons", {}).setdefault("CFBundlePrimaryIcon", {})
        icons.pop("CFBundleIconName", None)
        icons["CFBundleIconFiles"] = ["AppIcon60x60", "AppIcon76x76"]
        d.pop("CFBundleIcons~ipad", None)
        d["CFBundleIconFiles"] = ["AppIcon60x60", "AppIcon76x76"]
    modify_plist(info, update_app)

    plugin_root = app / "PlugIns"
    if plugin_root.is_dir():
        for extension in plugin_root.glob("*.appex"):
            def update_extension(d):
                old = d["CFBundleIdentifier"]
                if old.endswith(".Helper"):
                    d["CFBundleIdentifier"] = APP_ID + ".Helper"
                elif old.endswith(".OpenIn"):
                    d["CFBundleIdentifier"] = APP_ID + ".OpenIn"
                else:
                    raise ValueError("Unexpected extension identifier " + old)
            modify_plist(extension / "Info.plist", update_extension)

    # Remove old code resource manifests invalidated by the modified plists.
    for root in [app, *plugin_root.glob("*.appex")]:
        import shutil
        shutil.rmtree(root / "_CodeSignature", ignore_errors=True)
    print(f"Rebranded {app} as {NAME} ({APP_ID})")

if __name__ == "__main__":
    main()
