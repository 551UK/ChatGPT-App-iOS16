#!/usr/bin/env python3
"""Rebrand the pinned Reynard jailbroken app without removing Gecko or its helper."""
import argparse
import os
import plistlib
from pathlib import Path

APP_ID = "com.551uk.chatgptios16"
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
        d["NSMicrophoneUsageDescription"] = "Allow ChatGPT to record voice conversations and speech."
        d["NSSpeechRecognitionUsageDescription"] = "Use speech input in ChatGPT."
        # Avoid hijacking the original browser's reynard:// deep links.
        d.pop("CFBundleURLTypes", None)

        # Reynard declares background audio because it is a general-purpose
        # browser/media app. In the dedicated ChatGPT wrapper this causes iOS
        # to keep treating the app as a background media source and can produce
        # a blank lock-screen player after an ordinary text chat has loaded.
        # Keep Reynard's non-audio background capabilities, but remove only
        # the audio mode. Do not carry forward the failed v49 Now Playing hook.
        background_modes = d.get("UIBackgroundModes")
        if isinstance(background_modes, list):
            background_modes = [mode for mode in background_modes if mode != "audio"]
            if background_modes:
                d["UIBackgroundModes"] = background_modes
            else:
                d.pop("UIBackgroundModes", None)
        icons = d.setdefault("CFBundleIcons", {}).setdefault("CFBundlePrimaryIcon", {})
        icons.pop("CFBundleIconName", None)
        icons["CFBundleIconFiles"] = ["AppIcon60x60", "AppIcon76x76"]
        d.pop("CFBundleIcons~ipad", None)
        d["CFBundleIconFiles"] = ["AppIcon60x60", "AppIcon76x76"]
    modify_plist(info, update_app)

    plugin_root = app / "PlugIns"
    if plugin_root.is_dir():
        import shutil
        # ChatGPT does not register browser-style share extensions. Preserve
        # Reynard's mandatory Gecko helper, but remove the optional OpenIn.
        shutil.rmtree(plugin_root / "OpenIn.appex", ignore_errors=True)
        for extension in plugin_root.glob("*.appex"):
            def update_extension(d):
                old = d["CFBundleIdentifier"]
                if old.endswith(".Helper"):
                    d["CFBundleIdentifier"] = APP_ID + ".Helper"
                    d["NSMicrophoneUsageDescription"] = "Allow ChatGPT to record voice conversations and speech."
                    d["NSCameraUsageDescription"] = "Allow ChatGPT to use the camera for requested website features."
                elif old.endswith(".OpenIn"):
                    raise ValueError("Unexpected OpenIn extension: delete it before rebranding")
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
