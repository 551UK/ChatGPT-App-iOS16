# ChatGPT Native Diagnostics 2.0 — separate rootless tweak

This is a **new independent package** \`com.551uk.chatgpt-native-diagnostics\`; it does NOT modify or rebuild ChatGPT v1.26. Install the .deb on the user's iOS 16.3 Dopamine rootless device, close and relaunch the custom ChatGPT app. The previous broken \`com.551uk.chatgpt-crashmon\` can be removed independently. The new package is loaded only in **com.551uk.chatgptios16** (main process), not the Helper.

## How it works

- Native UIKit **Diagnostics** pill over the app, draggable, dismissible until restart.
- It listens to app activate/background/memory-warning events and takes one status/memory snapshot every 30 seconds **while the app is foregrounded**. No polling for chat messages, no JavaScript injected into ChatGPT, no Gecko Helper hooks, no LaunchDaemon or launchctl dependency.
- On app foreground and via **Capture crash reports now**, searches accessible CrashReporter directories for \`Reynard Helper\` report files and confirms the **custom ChatGPT Helper bundle ID** or plugin path in each report before copying. Captures complete original IPS, sha256 deduplicates reports, and writes per-report analysis with timestamps, JIT signature, thread, XUL UUID when available, app version, GeckoView metadata, JS SHA256 and memory.
- In the app, select **Export evidence** to use the iOS share sheet to send \`events.log\`, \`build-info.txt\`, \`capture-status.txt\`, \`app-heartbeat.txt\`, original IPS files and analysis files. Choose **Import .ips from Files** if iOS cannot give the app direct access to Analytics crash reports; save the report into Files first.
- Data is ONLY saved locally at \`/var/mobile/Documents/ChatGPTNativeDiagnostics/\`. It is not automatically sent anywhere. Crash reports can contain device-specific details, so the user chooses whether and where to share.

## Evidentiary limits

- An IPS report containing \`js::jit::TraceJitFrames\` shows the native fault site. It does NOT prove which JavaScript function, which Gecko engine bug, or which native module corrupted memory first.
- Lifecycle/memory traces can correlate crash timing to app resumption and memory pressure, even when the Helper dies but the app survives.
- Precise root cause may require XUL debug symbols, a Gecko profiler/JIT diagnostic build, or an A/B experiment using the same Gecko binary and an isolated engine/configuration change. This tweak makes collecting and comparing that evidence practical; it cannot guarantee the crash's cause will be identifiable by a report alone.

## Verification

On the phone: after installing, close and relaunch the ChatGPT app. Verify the small draggable "Diagnostics" button appears. Tap **Capture crash reports now**, then **Show status**. \`capture-status.txt\` should get the current UTC timestamp. After the next Helper crash, use **Export evidence**. The background-service startup failure in the older monitor is irrelevant: this package does not use launchd.

If no reports are collected, export the Apple Analytics \`Reynard Helper\` .ips from Settings > Privacy & Security > Analytics & Improvements > Analytics Data, save it to Files, and import it using the button. Verify the report belongs to \`com.551uk.chatgptios16.Helper\`.

IMPORTANT: This is a diagnostic test package. It must be tested on-device; compiled source alone does not verify UIKit overlay placement or the OS's crash report permissions.
