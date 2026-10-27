# ChatGPT — Gecko app for iOS 16

Experimental **ChatGPT app** using the complete mobile website at https://chatgpt.com, powered by **Reynard Browser's Gecko engine** instead of iOS WebKit. The UI is the actual ChatGPT website, not a recreation of its conversations or API. Reynard's address bar and browser tab controls are hidden.

- App display name: **ChatGPT**
- Bundle ID: `com.551uk.chatgptios16`
- Reynard: **0.19.0**; Firefox Gecko: **158.0.1**
- Target: **iOS 16 Dopamine rootless DEB**, with alternative TrollStore IPA
- ChatGPT account login; website features, conversation history, attachments and voice are provided by the ChatGPT site itself, subject to browser/device support
- Separate from the official ChatGPT app and from the original Reynard installation

## Installation

Download the `com.551uk.chatgptgecko_0.19.0-11_iphoneos-arm64.deb` package from the latest test release and install through **Sileo** on Dopamine iOS 16. Alternatively, use the TrollStore IPA (do not install both at once). Keep the Gecko helper extension. This is an independent web-powered app, not the legacy ChatGPT IPA.

## App-style navigation and microphone

The real ChatGPT website remains the conversation engine because it already provides current conversations, attachments, search and account features. Reynard's URL bar, toolbar, tab overview and share controls are hidden. There are **no visible browser/navigation controls** at the bottom. The ChatGPT web area fills the screen to the device bottom, and the **Ask ChatGPT** composer is docked directly to the bottom safe area. Back navigation is gesture-only: swipe right from the left edge to trigger Gecko history Back. There is no Forward control. The Gecko content script hides the small AI/disclaimer footer text and removes the **What can you do?** suggestion button.

For this dedicated ChatGPT wrapper, Reynard's **chatgpt.com microphone site permission is pre-allowed** so the browser-level prompt does not have to be repeated. The app explicitly asks iOS for microphone authorization on first active launch when the system state is still Not Determined. iOS itself cannot be silently pre-authorized; the system prompt must still be accepted once. The wrapper overrides Reynard's hidden browser-toolbar geometry so it does not reserve extra blank space. There is no native bottom strip; only ChatGPT's own composer occupies the bottom safe area.

## Building

GitHub Actions downloads the official **Reynard-Jailbroken.ipa** from the fixed `0.19.0` release, compiles our Objective-C app shell on macOS, adds it as an executable dependency, rebrands icons/bundle identifiers, signs the app and extension and generates the IPA and rootless DEB. You don't need the full Firefox/Gecko source to rebuild. See `scripts/package.sh`.

## What remains experimental

This package and shell integration are **device-tested iteratively on iOS 16**, but this permission/base change still requires verification. Upstream browser UI changes can affect the hide/layout hook. Gecko JIT, login and file pickers must be tested on a real iOS 16 device. If the hook fails, the app should remain an ordinary usable Reynard browser.

The app uses the user's supplied blue-to-purple ChatGPT home-screen icon, embedded directly in the reproducible icon generator. The official ChatGPT 1.2026.272 and 1.2024.200 IPAs are used only as interface/navigation references; their messaging implementation is not copied. Reynard's URL handlers and optional Open In extension are removed, and its Gecko helper uses a distinct app identifier.

## Acknowledgements and licensing

This app builds on [Reynard Browser](https://github.com/minh-ton/reynard-browser) by Minh Ton and Mozilla Gecko. Their engine, applications, open-source licenses and attribution remain upstream. No Reynard binary is stored in this repository; release assets are downloaded only at build time. This is an unofficial, independent ChatGPT website client, not an OpenAI-produced or endorsed application.
