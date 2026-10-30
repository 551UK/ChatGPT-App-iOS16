ChatGPT v1.29 fixes header styling recovery when entering/leaving chats.
- Recognised header icons receive black ink and 1.40x sidebar / 1.50x New Chat sizing immediately through CSS, even when React replaces classes or SVGs.
- Header-only attribute observation restores unlabelled controls. Direct-child watchers along the header's ancestor path catch larger route-container replacement without observing message descendants.
- Finite navigation recovery checks cover delayed hydration even when an old or empty header remains connected.
- Semantic headers get the white strip before JavaScript measures the replacement controls.
- Styling writes are isolated from the header observer to avoid self-triggering loops.

Based on the exact v1.28 package. The patched XUL engine, JIT, native app, entitlements and session code are byte-identical. Only the presentation script, extension version and package version change.

Firefox tests exercise class/SVG replacement, swapped icons, delayed hydration, ancestor replacement, unlabelled icons, sidebar exclusion, white header background and 5000 actual message mutations with no additional chrome scans. These fixture tests do not replace testing on the iPhone with ChatGPT's live markup. Keep v1.28 available as a fallback.