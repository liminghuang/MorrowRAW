#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$script_dir"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
app_dir="$script_dir/dist/MorrowRAW.app"
staging_dir="$script_dir/.dmg-staging"
dmg_path="$script_dir/dist/MorrowRAW-${version}-arm64.dmg"

"$script_dir/build-app.sh"
rm -rf "$staging_dir"
mkdir -p "$staging_dir"
cp -R "$app_dir" "$staging_dir/MorrowRAW.app"
ln -s /Applications "$staging_dir/Applications"

rm -f "$dmg_path"
hdiutil create \
    -volname "MorrowRAW ${version}" \
    -srcfolder "$staging_dir" \
    -ov \
    -format UDZO \
    "$dmg_path"

if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$dmg_path"
fi

codesign --verify --deep --strict "$app_dir"
hdiutil imageinfo "$dmg_path" >/dev/null
rm -rf "$staging_dir"
echo "Packaged $dmg_path"
