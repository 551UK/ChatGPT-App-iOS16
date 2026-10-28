# Best known version so far: v0.94

User confirmed **THIS VERSION WORKS** on 28 October 2026.

Preserved branch: `best-known-v0.94`. Keep this snapshot as the known-good baseline; make future experiments on separate branches.

## Source and behaviour
Based on untouched v0.84 commit bc94d99bb31e8e93aae0b72194f06723af6f287e.
The exact JavaScript shipped in the confirmed v0.94 DEB is in web/chatgpt-app-shell.js.
Sidebar uses 1.40x and New Chat uses 1.50x, following recognised icon identity across reordered and reused controls.
Nested controls are filtered to avoid double scaling; generic menu labels are not classified as sidebar.

## Confirmed package
Filename: com.551uk.chatgptgecko_0.19.0-94_iphoneos-arm64.deb
SHA-256: 5e8e2a5991fa2eb6c5f6b1116e22cc78c6bb8fc755dcd4293f8d4ab827e3734e

The tested DEB was repackaged from v0.84, retaining all original native binaries.
All payload paths, modes, owners, entry types and symlinks were compared against the original v0.84 archive and matched exactly.
Only app-shell JavaScript payload bytes changed; DEBIAN/control identifies version 0.19.0-94.
v0.93 is superseded because its root-only permissions caused the XUL launch failure.

The inherited native source and build scripts are preserved here, with package version updated to v0.94. A fresh native compilation is not claimed to be byte-identical to the tested repackaged binary.
Manual workflow validates source syntax only; it does not publish or replace the known-good package.

## Validation
JavaScript syntax and identity checks passed for reversed order, reused controls, recreated recognised artwork, conflicting artwork, unrelated menus and text-only controls.
Previously unseen unlabelled artwork remains unclassified rather than guessed.
