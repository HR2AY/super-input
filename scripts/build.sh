#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
build_dir="${SUPERINPUT_BUILD_DIR:-$project_dir/.build}"
package_dir="${SUPERINPUT_PACKAGE_DIR:-$project_dir/dist}"
mkdir -p "$package_dir"
xcodebuild build -project SuperInput.xcodeproj -scheme SuperInput \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$build_dir" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO
app_path="$build_dir/Build/Products/Release/Super Input.app"
codesign --force --sign - --options runtime "$app_path"
codesign --verify --deep --strict "$app_path"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
archive_path="$package_dir/Super-Input-Feishu-v$version-macOS.zip"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive_path"
(cd "$package_dir" && shasum -a 256 "$(basename "$archive_path")" > SHA256SUMS.txt)
printf 'Built %s\n' "$archive_path"
