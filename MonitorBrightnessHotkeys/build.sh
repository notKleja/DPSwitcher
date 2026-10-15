#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
build_dir="$project_dir/build"
app_dir="$build_dir/MonitorBrightnessHotkeys.app"
helper_dir="$app_dir/Contents/Library/LoginItems/MonitorBrightnessHotkeysLoginItem.app"
module_cache="${TMPDIR:-/tmp}/MonitorBrightnessHotkeysModuleCache"

rm -rf "$build_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$helper_dir/Contents/MacOS"

swiftc \
  -swift-version 5 \
  -module-cache-path "$module_cache" \
  -import-objc-header "$project_dir/Sources/Bridging-Header.h" \
  "$project_dir/Sources/CoreLogic.swift" \
  "$project_dir/Sources/MonitorControlDDC.swift" \
  "$project_dir/Sources/GlobalHotKeyController.swift" \
  "$project_dir/Sources/PersistentBlackShade.swift" \
  "$project_dir/Sources/ShortcutCaptureField.swift" \
  "$project_dir/Sources/AppDelegate.swift" \
  "$project_dir/Sources/main.swift" \
  -o "$app_dir/Contents/MacOS/MonitorBrightnessHotkeys" \
  -framework Cocoa \
  -framework Carbon \
  -framework IOKit \
  -framework ServiceManagement \
  -F /System/Library/PrivateFrameworks \
  -framework DisplayServices

swiftc \
  -swift-version 5 \
  -module-cache-path "$module_cache" \
  "$project_dir/LoginItem/main.swift" \
  -o "$helper_dir/Contents/MacOS/MonitorBrightnessHotkeysLoginItem" \
  -framework Cocoa

cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Resources/LoginItem-Info.plist" "$helper_dir/Contents/Info.plist"
cp "$project_dir/LICENSE-MonitorControl.txt" "$app_dir/Contents/Resources/"

codesign --force --sign - --timestamp=none "$helper_dir"
codesign --force --sign - --timestamp=none "$app_dir"

echo "$app_dir"
