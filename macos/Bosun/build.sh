#!/bin/bash
# Builds Bosun.app into macos/Bosun/$BOSUN_BUILD_DIR/Bosun.app (default: build/Bosun.app).
#   ./build.sh          Release build
#   ./build.sh test     run the unit tests (BosunCoreTests)
# BOSUN_BUILD_DIR picks another output directory (relative to this one, or absolute), so a second
# build never replaces a Bosun.app that is running from build/.
# Needs xcodegen and the libghostty xcframework at ../../../ghostty/macos/GhosttyKit.xcframework (see README.md).
set -euo pipefail
cd "$(dirname "$0")"
OUT="${BOSUN_BUILD_DIR:-build}"
xcodegen generate --quiet

if [[ "${1:-}" == "test" ]]; then
  mkdir -p "$OUT"
  set +e
  xcodebuild -project Bosun.xcodeproj -scheme Bosun -derivedDataPath "$OUT/DerivedData" \
    -destination 'platform=macOS,arch=arm64' test > "$OUT/test.log" 2>&1
  status=$?
  set -e
  grep -E "error:|failed|Executed|\*\* TEST" "$OUT/test.log" | grep -v "exit code 0 but produced" || true
  exit $status
fi

set +e
xcodebuild -project Bosun.xcodeproj -scheme Bosun -configuration Release \
  -derivedDataPath "$OUT/DerivedData" -destination 'platform=macOS,arch=arm64' build -quiet 2>&1 \
  | grep -v "failed with exit code 0 but produced no further output"
status=${PIPESTATUS[0]}
set -e
if [[ $status != 0 ]]; then echo "build failed ($status)" >&2; exit "$status"; fi
rm -rf "$OUT/Bosun.app"
cp -R "$OUT/DerivedData/Build/Products/Release/Bosun.app" "$OUT/"
echo "built $(cd "$OUT" && pwd)/Bosun.app"
