#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
file=dist/com.551uk.chatgptgecko_0.19.0-132_iphoneos-arm64.deb
curl -fL --retry 3 https://github.com/551UK/ChatGPT-App-iOS16/releases/download/chatgpt-v132/com.551uk.chatgptgecko_0.19.0-132_iphoneos-arm64.deb -o "$file"
echo "a4f7cba1a1d9f95dd18b831c3cb86f34af2a145e9a8d6703e2c2adfd44081085  $file" | sha256sum -c -
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
dpkg-deb -x "$file" "$work"
embedded=$(find "$work" -path '*/extensions/readerview/chatgpt-app-shell.js' -type f)
test -n "$embedded"
cmp web/chatgpt-app-shell.js "$embedded"
test "$(dpkg-deb -f "$file" Version)" = "0.19.0-132"
echo "Verified exact released v1.32 package and matching presentation source"
