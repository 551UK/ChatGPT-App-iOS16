#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/jit-v128 dist
BASE=build/jit-v128/base.deb
ROOT=build/jit-v128/root
curl -fL --retry 3 https://github.com/551UK/ChatGPT-App-iOS16/releases/download/v1.26/com.551uk.chatgptgecko_0.19.0-126_iphoneos-arm64.deb -o "$BASE"
echo 'de69e45be9e129c042cfe45f8ce2da842b4e6e252a7ddfaee671e6e0d3354545  build/jit-v128/base.deb' | sha256sum -c -
test ! -e "$ROOT"
dpkg-deb -R "$BASE" "$ROOT"
XUL="$ROOT/var/jb/Applications/ChatGPT.app/Frameworks/XUL"
python3 tests/jit-active-stub-v128.py "$XUL"
node tests/header-only-v126.test.cjs
ldid -e "$XUL" > build/jit-v128/original-entitlements.xml
# The pinned XUL has no entitlements. Keep the separately signed app/helper intact.
test ! -s build/jit-v128/original-entitlements.xml
python3 scripts/patch_xul_active_stub.py "$XUL"
ldid -S "$XUL"
python3 - <<'PY'
from pathlib import Path
p=Path('build/jit-v128/root/DEBIAN/control')
s=p.read_text()
assert 'Version: 0.19.0-126\n' in s
p.write_text(s.replace('Version: 0.19.0-126\n', 'Version: 0.19.0-128\n'))
PY
dpkg-deb --root-owner-group -Zxz --build "$ROOT" dist/com.551uk.chatgptgecko_0.19.0-128_iphoneos-arm64.deb
dpkg-deb --info dist/com.551uk.chatgptgecko_0.19.0-128_iphoneos-arm64.deb
sha256sum dist/com.551uk.chatgptgecko_0.19.0-128_iphoneos-arm64.deb
