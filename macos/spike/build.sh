#!/bin/bash
# Generates the Xcode project and builds BosunSpike.app into macos/spike/build/.
# Requires the libghostty xcframework at ../../../ghostty/macos/GhosttyKit.xcframework (see README.md).
set -euo pipefail
cd "$(dirname "$0")"
xcodegen generate --quiet
xcodebuild -project BosunSpike.xcodeproj -scheme BosunSpike -configuration Release \
  -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' build -quiet
rm -rf build/BosunSpike.app
cp -R build/DerivedData/Build/Products/Release/BosunSpike.app build/
echo "built $(pwd)/build/BosunSpike.app"
