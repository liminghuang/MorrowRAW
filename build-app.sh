#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$script_dir"

swift build -c release --arch arm64 --build-path "$script_dir/.build/release-arm64"

app_dir="$script_dir/dist/MorrowRAW.app"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
binary_path="$script_dir/.build/release-arm64/arm64-apple-macosx/release/MorrowRAW"
if [[ ! -x "$binary_path" ]]; then
    binary_path="$script_dir/.build/release-arm64/out/Products/Release/MorrowRAW"
fi
if [[ ! -x "$binary_path" ]]; then
    echo "Release executable not found under .build/release-arm64" >&2
    exit 1
fi
cp "$binary_path" "$app_dir/Contents/MacOS/MorrowRAW"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp Resources/MorrowRAW.icns "$app_dir/Contents/Resources/MorrowRAW.icns"

resource_bundle="$script_dir/.build/release-arm64/arm64-apple-macosx/release/MorrowRAW_MorrowRAW.bundle"
if [[ ! -d "$resource_bundle" ]]; then
    resource_bundle="$script_dir/.build/release-arm64/out/Products/Release/MorrowRAW_MorrowRAW.bundle"
fi
if [[ ! -d "$resource_bundle" ]]; then
    echo "SwiftPM resource bundle not found under .build/release-arm64" >&2
    exit 1
fi
cp -R "$resource_bundle" "$app_dir/Contents/Resources/"

if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    codesign --force --deep --options runtime --timestamp \
        --sign "$SIGNING_IDENTITY" "$app_dir"
else
    codesign --force --deep --sign - "$app_dir"
fi
codesign --verify --deep --strict "$app_dir"

echo "Built $app_dir"
