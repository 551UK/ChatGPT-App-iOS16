# ChatGPT 1.30 — Adaptive header colour

The header strip follows the rendered Appearance button colour, falling back to the page background for transparent buttons. Theme changes refresh the strip, including root style/class and stylesheet changes. The painted edge ends exactly at the lowest visible header button after scaling, including a single-button Home header.

Based on stable v1.29. Only the presentation JavaScript, extension version, and Debian package version change; the patched XUL and native app are preserved byte-for-byte. The main branch contains the complete v1.30 source; stable-v1.29 preserves the previous baseline.

Validation: Firefox lifecycle tests plus live blue/pink colour updates, stylesheet changes, transparent-control fallback, exact button-edge alignment, and a single-button Home header. Device confirmation is still needed.
