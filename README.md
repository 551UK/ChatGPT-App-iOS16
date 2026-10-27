# ChatGPT — Gecko app for iOS 16

Experimental **ChatGPT app** using the complete mobile website at https://chatgpt.com, powered by **Reynard Browser's Gecko engine** instead of iOS WebKit. The UI is the actual ChatGPT website, not a recreation of its conversations or API. Reynard's address bar and browser tab controls are hidden.

- App display name: **ChatGPT**
- Bundle ID: `com.551uk.chatgptgecko`
- Reynard: **0.19.0**; Firefox Gecko: **158.0.1**
- Target: **iOS 16 Dopamine rootless DEB**, with alternative TrollStore IPA
- ChatGPT account login; website features, conversation history, attachments and voice are provided by the ChatGPT site itself, subject to browser/device support
- Separate from the official ChatGPT app and from the original Reynard installation

## Installation

Download the `com.551uk.chatgptgecko_0.19.0-4_iphoneos-arm64.deb` package from the latest test release and install through **Sileo** on Dopamine iOS 16. Alternatively, use the TrollStore IPA (do not install both at once). Keep the Gecko helper extension. This is an independent web-powered app, not the legacy ChatGPT IPA.

## App-style navigation and microphone

The real ChatGPT website is the interface. The native **•••** options button offers **Back to chats**, **New chat**, **Enable microphone**, and **Reload ChatGPT**. The app now hides Reynard's native URL bar and bottom toolbar via the controller's UIKit lifecycle, including on relayout, while leaving the native Gecko child views intact. You can also swipe from the left edge to return to chats if you get stuck in voice mode. The button is an app recovery menu, **not a browser address or tab bar**. The site-origin prompt (“Allow chatgpt.com to use your microphone?”) is owned by Reynard/Gecko's original media permission delegate and must appear when the website requests audio. The optional native Enable microphone button handles the distinct iOS TCC authorization. A build success does not prove website voice works; verify on-device. Video, advanced voice and specific native-only app features depend on actual website and Gecko support. The app is not an exact clone of the current official ChatGPT IPA.

## Building

GitHub Actions downloads the official **Reynard-TrollStore.tipa** from the fixed `0.19.0` release, compiles our Objective-C app shell on macOS, adds it as an executable dependency, rebrands icons/bundle identifiers, signs the app and extension and generates the IPA and rootless DEB. You don't need the full Firefox/Gecko source to rebuild. See `scripts/package.sh`.

## What remains experimental

This package and shell integration are **not yet device-tested**. Upstream browser UI changes can affect the hide/layout hook. Gecko JIT, login and file pickers must be tested on a real iOS 16 device. If the hook fails, the app should remain an ordinary usable Reynard browser.

The app uses the user's supplied blue-to-purple ChatGPT home-screen icon, embedded directly in the reproducible icon generator. Reynard's URL handlers and optional Open In extension are removed, and its Gecko helper uses a distinct app identifier.

## Acknowledgements and licensing

This app builds on [Reynard Browser](https://github.com/minh-ton/reynard-browser) by Minh Ton and Mozilla Gecko. Their engine, applications, open-source licenses and attribution remain upstream. No Reynard binary is stored in this repository; release assets are downloaded only at build time. This is an unofficial, independent ChatGPT website client, not an OpenAI-produced or endorsed application.
