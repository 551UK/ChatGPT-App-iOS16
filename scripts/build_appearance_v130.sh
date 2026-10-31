#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/appearance-v130 dist
BASE=build/appearance-v130/base.deb
ROOT=build/appearance-v130/root
curl -fL --retry 3 https://github.com/551UK/ChatGPT-App-iOS16/releases/download/chatgpt-header-v129/com.551uk.chatgptgecko_0.19.0-129_iphoneos-arm64.deb -o "$BASE"
echo '073e0a827d6bb75d52f3d4fbbd9d11fb651e65ce959aac175d05a8ada54e589c  build/appearance-v130/base.deb' | sha256sum -c -
test ! -e "$ROOT"
dpkg-deb -R "$BASE" "$ROOT"
python3 - <<'PY'
import hashlib,json
from pathlib import Path
root=Path('build/appearance-v130/root')
app=root/'var/jb/Applications/ChatGPT.app'
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
before={str(p.relative_to(root)):digest(p) for p in root.rglob('*') if p.is_file() and not p.is_symlink()}
manifest=next(app.rglob('extensions/readerview/manifest.json'))
shell=manifest.parent/'chatgpt-app-shell.js'
source=Path('web/chatgpt-app-shell.js')
shell.write_bytes(source.read_bytes())
m=json.loads(manifest.read_text())
assert m['version']=='1.0.129'
m['version']='1.0.130'
manifest.write_text(json.dumps(m,indent=2)+'\n')
control=root/'DEBIAN/control'
s=control.read_text()
assert 'Version: 0.19.0-129\n' in s
control.write_text(s.replace('Version: 0.19.0-129\n','Version: 0.19.0-130\n'))
allowed={str(p.relative_to(root)) for p in [manifest,shell,control]}
after={str(p.relative_to(root)):digest(p) for p in root.rglob('*') if p.is_file() and not p.is_symlink()}
assert before.keys()==after.keys()
changed={p for p in before if before[p]!=after[p]}
assert changed==allowed,(changed,allowed)
assert shell.read_bytes()==source.read_bytes()
xul=app/'Frameworks/XUL'
print('PASS: only presentation JS, extension version and package version changed')
assert digest(xul)=='83c25b0f693d656206c300a7ca302d81420b6822f279364f3218d58e9e7470e5'
print('Preserved patched XUL SHA256:',digest(xul))
PY
dpkg-deb --root-owner-group -Zxz --build "$ROOT" dist/com.551uk.chatgptgecko_0.19.0-130_iphoneos-arm64.deb
dpkg-deb --info dist/com.551uk.chatgptgecko_0.19.0-130_iphoneos-arm64.deb
sha256sum dist/com.551uk.chatgptgecko_0.19.0-130_iphoneos-arm64.deb
