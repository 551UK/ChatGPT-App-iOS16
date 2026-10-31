# Crash repair retained in v1.30\n\nHistorical investigation notes for the active-stub repair introduced in v1.28.\n\nChatGPT v1.28 is a targeted **test candidate** for the recurring Reynard Helper
crash. Device stability is not yet confirmed.

Two ARM64 branches restore Mozilla's original active-stub-only tracing in
Baseline GC and weak GC. Reynard's added traversal can follow an unlinked active
stub's stale next pointer. The observed crash instructions are 0x696e8e8 and
0x696f910. Active-stub trace calls and local tracing slots remain intact.

JIT stays enabled. Ion tracing, startup preferences, helper/app entitlements,
v1.26 native code, presentation JavaScript, sessions and login data are unchanged.
This package does not change Choicy settings. Close ChatGPT fully before updating.

Evidence and scope:

- Reynard 0.19.0 commit 24a99b7, `patches/js/src/jit/JitFrames.cpp.patch` adds
  linked-stub traversal to both Baseline frame tracing functions.
- Its Firefox submodule is 9378fbc58660847fbc02c3486a0ecd6049978e25
  (FIREFOX_158_0_1_RELEASE). Original `js/src/jit/JitFrames.cpp` traces only the
  stack's active stub; `BaselineIC.cpp` documents that unlinked callable stubs
  can remain referenced by a stack frame. Live IC chains are traced separately.
- Input DEB and XUL are SHA-256 pinned. Any other binary is rejected. Exactly
  two four-byte instructions are replaced before re-signing XUL.
- Unicorn tests execute the original ARM64 blocks and reproduce unmapped-next
  faults, then check 18 patched cases (normal/fallback/null active stubs with
  null/stale/cyclic next pointers). Trace callees are mocked: these are control
  flow checks, not a complete Gecko runtime or garbage-collector test.
- Current header regression coverage is in tests/header-appearance-v130.cjs. Real-device testing is required
  to establish whether this resolves all observed crashes; a shared crash
  location alone does not prove the initiating lifetime bug.

The current source and release are v1.30.
