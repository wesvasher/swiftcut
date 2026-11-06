#!/bin/zsh
# Rebuild SwiftCut and relaunch it: regenerates the Xcode project, builds Debug
# into ./DerivedData, quits the running copy, and opens the new build.
set -euo pipefail
cd "${0:A:h}"

xcodegen generate --quiet

xcodebuild build \
  -project SwiftCut.xcodeproj \
  -scheme SwiftCut \
  -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath DerivedData \
  -quiet

APP="DerivedData/Build/Products/Debug/SwiftCut.app"

# Quit the copy that's running, if any, so the new build opens fresh.
if pgrep -xq SwiftCut; then
  osascript -e 'quit app "SwiftCut"' 2>/dev/null || true
  for _ in {1..50}; do pgrep -xq SwiftCut || break; sleep 0.1; done
  pkill -x SwiftCut 2>/dev/null || true
fi

open "$APP"
echo "Launched $APP"
