#!/bin/bash
set -euo pipefail
project_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_dir"
icon_source="$project_dir/app/MacUse.png"
iconset="$project_dir/.build/MacUse.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$icon_source" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  retina_size=$((size * 2))
  sips -z "$retina_size" "$retina_size" "$icon_source" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns "$iconset" --output "$project_dir/.build/MacUse.icns"
swift build -c release --arch arm64
if [ -f .build/arm64-apple-macosx/release/MacUse ]; then
  bin_path=".build/arm64-apple-macosx/release/MacUse"
elif [ -f .build/release/MacUse ]; then
  bin_path=".build/release/MacUse"
else
  echo "Release MacUse binary not found under .build" >&2
  exit 1
fi
app_path="$project_dir/dist/MacUse Helper.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp app/Info.plist "$app_path/Contents/Info.plist"
cp .build/MacUse.icns "$app_path/Contents/Resources/MacUse.icns"
cp "$bin_path" "$app_path/Contents/MacOS/MacUse"
chmod 755 "$app_path/Contents/MacOS/MacUse"
codesign --force --sign "${MACUSE_SIGN_IDENTITY:--}" --identifier io.macuse.helper "$app_path"
codesign --verify --strict "$app_path"
printf '%s\n' "$app_path"
