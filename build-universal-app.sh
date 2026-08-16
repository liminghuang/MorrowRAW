#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
cd "$script_dir"

arm_build="$script_dir/.build/release-arm64"
x86_build="$script_dir/.build/release-x86_64"
app_dir="$script_dir/dist/MorrowRAW-universal.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"

swift build -c release --arch arm64 --build-path "$arm_build"
swift build -c release --arch x86_64 --build-path "$x86_build"

rm -rf "$app_dir"
mkdir -p "$macos_dir"
lipo -create \
    "$arm_build/arm64-apple-macosx/release/MorrowRAW" \
    "$x86_build/x86_64-apple-macosx/release/MorrowRAW" \
    -output "$macos_dir/MorrowRAW"
cp "$script_dir/Resources/Info.plist" "$contents_dir/Info.plist"
mkdir -p "$contents_dir/Resources"
cp "$script_dir/Resources/MorrowRAW.icns" "$contents_dir/Resources/MorrowRAW.icns"
chmod +x "$macos_dir/MorrowRAW"

if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    codesign --force --deep --options runtime --timestamp \
        --sign "$SIGNING_IDENTITY" "$app_dir"
else
    codesign --force --deep --sign - "$app_dir"
fi
codesign --verify --deep --strict "$app_dir"

plutil -lint "$contents_dir/Info.plist"
echo "Built $app_dir"
