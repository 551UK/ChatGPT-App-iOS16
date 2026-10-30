#!/usr/bin/env bash
# Retrieve and verify the exact stable v1.29 baseline without deleted old releases.
# For a clean source build use scripts/package.sh on macOS with Theos.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
f=dist/com.551uk.chatgptgecko_0.19.0-129_iphoneos-arm64.deb
curl -fL --retry 3 https://github.com/551UK/ChatGPT-App-iOS16/releases/download/chatgpt-header-v129/com.551uk.chatgptgecko_0.19.0-129_iphoneos-arm64.deb -o "$f"
echo "073e0a827d6bb75d52f3d4fbbd9d11fb651e65ce959aac175d05a8ada54e589c  $f" | sha256sum -c -
temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT
dpkg-deb -x "$f" "$temp_dir"
embedded=$(find "$temp_dir" -path '*/extensions/readerview/chatgpt-app-shell.js' -type f)
test -n "$embedded"
cmp web/chatgpt-app-shell.js "$embedded"
test "$(dpkg-deb -f "$f" Version)" = "0.19.0-129"
echo "Verified exact stable v1.29 package and matching source"
