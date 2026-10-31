#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
file=dist/com.551uk.chatgptgecko_0.19.0-130_iphoneos-arm64.deb
curl -fL --retry 3 https://github.com/551UK/ChatGPT-App-iOS16/releases/download/chatgpt-appearance-v130/com.551uk.chatgptgecko_0.19.0-130_iphoneos-arm64.deb -o "$file"
echo "b96fc3db45d65e91cc8c404a1e0f3d266b190809e10d1ba0fabe0805f8546bb3  $file" | sha256sum -c -
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
dpkg-deb -x "$file" "$work"
embedded=$(find "$work" -path '*/extensions/readerview/chatgpt-app-shell.js' -type f)
test -n "$embedded"
cmp web/chatgpt-app-shell.js "$embedded"
test "$(dpkg-deb -f "$file" Version)" = "0.19.0-130"
echo "Verified exact released v1.30 package and matching presentation source"
