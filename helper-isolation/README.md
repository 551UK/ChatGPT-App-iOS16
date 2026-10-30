# ChatGPT Helper Tweak Isolation 1.0

Independent rootless package. Does NOT modify ChatGPT v1.26, Gecko JIT, the Helper executable, entitlements, or the Native Diagnostics monitor.

At installation, its signed Objective-C helper validates the installed main ChatGPT and Reynard Helper bundle IDs, backs up the previous Helper-only setting, and changes exactly:
appSettings -> com.551uk.chatgptios16.Helper -> tweakInjectionDisabled = true

All other Choicy settings stay unchanged. The package posts Choicy's normal ReloadPrefs notification and checks that the value was saved. It doesn't respring or terminate processes.

After installation, fully close and relaunch ChatGPT so the Helper starts with the new setting.

For visual confirmation: Settings > Choicy > Applications > ChatGPT > App Plugins > Reynard Helper > Disable Tweak Injection.

The previous Helper preference is restored when the package is removed in Sileo, provided the setting is still enabled by this installer. Global Choicy settings and the main ChatGPT app are never touched.

Diagnostic log: /var/mobile/Documents/ChatGPTNativeDiagnostics/choicy-helper-isolation-status.txt

Potential downside: any tweak that intentionally runs inside the Helper, such as Cr4shed's in-process crash notification integration, will stop operating there. Apple's .ips files are still expected to be produced. The Gecko engine and JIT remain enabled.

This is a reversible isolation test for third-party native interference, not a demonstrated fix of a Gecko engine defect. The installer uses a verified on-disk Choicy preference update; actual device behaviour requires confirmation.
