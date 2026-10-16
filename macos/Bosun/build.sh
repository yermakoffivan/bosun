#!/bin/bash
# Builds Bosun.app into macos/Bosun/build/Bosun.app.
#   ./build.sh          Release build
#   ./build.sh test     run the unit tests (BosunCoreTests)
# Needs xcodegen and the libghostty xcframework at ../../../ghostty/macos/GhosttyKit.xcframework (see README.md).
set -euo pipefail
cd "$(dirname "$0")"
xcodegen generate --quiet

if [[ "${1:-}" == "test" ]]; then
  mkdir -p build
  set +e
  xcodebuild -project Bosun.xcodeproj -scheme Bosun -derivedDataPath build/DerivedData \
    -destination 'platform=macOS,arch=arm64' test > build/test.log 2>&1
  status=$?
  set -e
  grep -E "error:|failed|Executed|\*\* TEST" build/test.log | grep -v "exit code 0 but produced" || true
  exit $status
fi

set +e
xcodebuild -project Bosun.xcodeproj -scheme Bosun -configuration Release \
  -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' build -quiet 2>&1 \
  | grep -v "failed with exit code 0 but produced no further output"
status=${PIPESTATUS[0]}
set -e
if [[ $status != 0 ]]; then echo "build failed ($status)" >&2; exit "$status"; fi
rm -rf build/Bosun.app
cp -R build/DerivedData/Build/Products/Release/Bosun.app build/
echo "built $(pwd)/build/Bosun.app"
