#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$script_dir"

swift build -c release --arch arm64 --build-path "$script_dir/.build/release-arm64"

app_dir="$script_dir/dist/MorrowRAW.app"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp .build/release-arm64/arm64-apple-macosx/release/MorrowRAW \
    "$app_dir/Contents/MacOS/MorrowRAW"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp Resources/MorrowRAW.icns "$app_dir/Contents/Resources/MorrowRAW.icns"

if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    codesign --force --deep --options runtime --timestamp \
        --sign "$SIGNING_IDENTITY" "$app_dir"
else
    codesign --force --deep --sign - "$app_dir"
fi
codesign --verify --deep --strict "$app_dir"

echo "Built $app_dir"
