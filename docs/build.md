# Build and verify 1.30

The repository contains the native app shell (src), settings bundle (prefs), Gecko presentation script (web), packaging tools (scripts), and regression tests (tests).

For a source build, use macOS with Xcode/iOS SDK, Theos and its SDKs, ldid, dpkg-deb, Python 3 and Pillow. Set THEOS to the Theos checkout, then run:

```sh
bash scripts/package.sh
```

This downloads upstream Reynard 0.19.0, compiles the native shell and settings bundle, applies the guarded XUL repair, signs the binaries, and packages version 0.19.0-130 in dist. Upstream Gecko is a downloaded dependency, not vendored source.

To download and verify the exact published package on Linux:

```sh
bash scripts/verify_release_v130.sh
```

This checks its SHA-256, package version and embedded presentation script against this checkout. The published package preserves the v1.29 native binaries; a fresh source build is not guaranteed byte-identical.

Firefox regression tests:

```sh
npm install --no-save playwright@1.56.1
npx playwright install --with-deps firefox
node tests/header-appearance-v130.cjs
```

The guarded XUL patch and its ARM64 regression harness remain in scripts/patch_xul_active_stub.py and tests/jit-active-stub-v128.py; see docs/jit-v128.md for the original investigation.
