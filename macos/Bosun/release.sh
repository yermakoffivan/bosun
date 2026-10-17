#!/bin/bash
# Bosun for Mac: a signed, notarized release build, the same pipeline as the SkulkWorks apps (Den):
# a Release build signed with Developer ID and the hardened runtime, notarized with notarytool and stapled,
# then a DMG that is signed, notarized and stapled too.
#
#   ./release.sh            build → sign → notarize → DMG (into build-dist/)
#   ./release.sh package    only the notarizing and the DMG, for an app already built into build-dist/
#   ./release.sh verify     check the built app and DMG: signature, hardened runtime, tickets, Gatekeeper
#   ./release.sh publish    put the DMG on the GitHub release for v<version> (made by the tag's CI run) as
#                           Bosun-<version>.dmg, and write the `bosun-app` cask into the Homebrew tap
#
# The app ships as YetiDevWorks, beside the CLI: the same version, the same GitHub release, the same tap
# (yetidevworks/homebrew-bosun). Notarizing needs the keychain, so this runs here rather than in CI: cut the
# tag, let its release run finish, then `./release.sh && ./release.sh publish`.
#
# Signing settings are passed to xcodebuild here, not set in project.yml, so day-to-day and test builds
# (build.sh) stay ad hoc and never wait on the keychain.
#
# Settings (env):
#   NOTARY_PROFILE  notarytool keychain profile (as for the SkulkWorks apps; create one with
#                   `xcrun notarytool store-credentials <name>`). Unset: the build is signed but not notarized.
#   SIGN_IDENTITY   default "Developer ID Application"
#   TEAM_ID         default M5N5FDK55S
#   DEN_DIR         a skulkworks/den checkout, for the laid-out DMG window (default ../../../../skulkworks/den);
#                   without it the DMG is a plain one.
# The version is the bosun crate's (Cargo.toml), so the app and the daemon it talks to ship as one; the
# build number is the commit count.
set -euo pipefail
cd "$(dirname "$0")"
HERE="$(pwd)"
REPO="$(cd ../.. && pwd)"
OUT="$HERE/build-dist"
APP_NAME="Bosun"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
TEAM_ID="${TEAM_ID:-M5N5FDK55S}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
DEN_DIR="${DEN_DIR:-$REPO/../../skulkworks/den}"
# Den's DMG step works in <its PROJECT_ROOT>/build: give it a folder of its own under build-dist.
DEN_ROOT="$OUT/den"
APP="$DEN_ROOT/build/$APP_NAME.app"
DMG="$DEN_ROOT/build/$APP_NAME.dmg"

VERSION="$(grep -m1 '^version = ' "$REPO/Cargo.toml" | cut -d'"' -f2)"
BUILD_NUMBER="$(git -C "$REPO" rev-list --count HEAD)"

info() { echo "[INFO] $*"; }
# Read codesign's output into a variable first: `codesign | grep -q` under pipefail fails whenever grep
# stops reading early (SIGPIPE), match or not.
hardened() { local sig; sig="$(codesign -dvv "$1" 2>&1)"; [[ "$sig" == *"(runtime)"* ]]; }
fail() { echo "[ERROR] $*" >&2; exit 1; }

verify() {
    [ -d "$APP" ] || fail "no app at $APP (run ./release.sh first)"
    info "Signature"
    codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2
    local sig; sig="$(codesign -dvv "$APP" 2>&1)"
    grep -E "^(Authority|TeamIdentifier|Timestamp|Runtime Version)=|flags=" <<<"$sig" | head -6
    hardened "$APP" || fail "the hardened runtime is off"
    info "Version $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist"))"
    if [ -n "$NOTARY_PROFILE" ]; then
        info "Notarization tickets"
        xcrun stapler validate "$APP"
        [ -f "$DMG" ] && xcrun stapler validate "$DMG"
        info "Gatekeeper"
        spctl --assess --type execute --verbose=2 "$APP" 2>&1 | head -3
        [ -f "$DMG" ] && spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" 2>&1 | head -3
    fi
    [ -f "$DMG" ] && info "DMG $DMG ($(du -h "$DMG" | cut -f1))"
}

notarize() {
    local path="$1" submit="$1"
    if [ -z "$NOTARY_PROFILE" ]; then
        echo "[WARN] NOTARY_PROFILE unset: $path is signed but not notarized, and Gatekeeper will refuse it on other Macs." >&2
        return 0
    fi
    if [ -d "$path" ]; then
        submit="$OUT/$(basename "$path").zip"
        ditto -c -k --keepParent "$path" "$submit"
    fi
    info "Notarizing $(basename "$path") (notarytool waits for Apple's answer)..."
    xcrun notarytool submit "$submit" --keychain-profile "$NOTARY_PROFILE" --wait | tee "$OUT/notary.log"
    grep -q "status: Accepted" "$OUT/notary.log" || fail "notarization of $(basename "$path") was not accepted (see $OUT/notary.log)"
    [ "$submit" != "$path" ] && rm -f "$submit"
    xcrun stapler staple "$path"
}

publish() {
    local repo="yetidevworks/bosun" tap="yetidevworks/homebrew-bosun" tag="v$VERSION"
    local asset="$APP_NAME-$VERSION.dmg"
    [ -f "$DMG" ] || fail "no DMG at $DMG (run ./release.sh first)"
    local built; built="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
    [ "$built" = "$VERSION" ] || fail "the built app is $built, Cargo.toml says $VERSION: run ./release.sh again"
    xcrun stapler validate "$DMG" >/dev/null || fail "the DMG isn't notarized (set NOTARY_PROFILE and run ./release.sh)"
    gh release view "$tag" --repo "$repo" >/dev/null 2>&1 || fail "no GitHub release $tag yet: push the tag and let its release run finish"
    local sha; sha="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
    info "Uploading $asset to $repo $tag"
    cp "$DMG" "$OUT/$asset"
    gh release upload "$tag" "$OUT/$asset" --repo "$repo" --clobber
    rm -f "$OUT/$asset"

    info "Writing Casks/bosun-app.rb in $tap"
    local work="$OUT/tap"
    rm -rf "$work"
    gh repo clone "$tap" "$work" -- --quiet
    mkdir -p "$work/Casks"
    cat > "$work/Casks/bosun-app.rb" <<CASK
cask "bosun-app" do
  version "$VERSION"
  sha256 "$sha"

  url "https://github.com/$repo/releases/download/v#{version}/$APP_NAME-#{version}.dmg"
  name "Bosun"
  desc "Terminal workspace for tmux-native AI agent sessions"
  homepage "https://github.com/$repo"

  depends_on arch: :arm64
  depends_on formula: "yetidevworks/bosun/bosun"
  depends_on macos: :sequoia

  app "$APP_NAME.app"

  zap trash: [
    "~/Library/Application Support/dev.yetidevworks.bosun-mac",
    "~/Library/Caches/dev.yetidevworks.bosun-mac",
    "~/Library/Preferences/dev.yetidevworks.bosun-mac.plist",
    "~/Library/Saved Application State/dev.yetidevworks.bosun-mac.savedState",
  ]
end
CASK
    git -C "$work" add Casks/bosun-app.rb
    if git -C "$work" diff --cached --quiet; then
        info "The cask is already at $VERSION"
    else
        git -C "$work" commit --quiet -m "bosun-app $VERSION"
        git -C "$work" push --quiet
    fi
    rm -rf "$work"
    info "Published: brew install --cask yetidevworks/bosun/bosun-app"
}

if [ "${1:-}" = "verify" ]; then verify; exit 0; fi
if [ "${1:-}" = "publish" ]; then publish; exit 0; fi
# `./release.sh package` picks up after a build: notarize the app, then the DMG.
if [ "${1:-}" = "package" ]; then SKIP_BUILD=1; fi

security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY.*($TEAM_ID)" \
    || fail "no \"$SIGN_IDENTITY\" identity for team $TEAM_ID in the keychain"

info "Bosun $VERSION ($BUILD_NUMBER), signed by \"$SIGN_IDENTITY\" ($TEAM_ID)"
if [ -z "${SKIP_BUILD:-}" ]; then
rm -rf "$OUT"
mkdir -p "$DEN_ROOT/build"
xcodegen generate --quiet
set +e
xcodebuild -project Bosun.xcodeproj -scheme Bosun -configuration Release \
    -derivedDataPath "$OUT/DerivedData" -destination 'platform=macOS,arch=arm64' \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" \
    ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    build -quiet 2>&1 | grep -v "failed with exit code 0 but produced no further output"
status=${PIPESTATUS[0]}
set -e
[ "$status" = 0 ] || fail "xcodebuild failed ($status)"
cp -R "$OUT/DerivedData/Build/Products/Release/$APP_NAME.app" "$APP"
codesign --verify --deep --strict "$APP" || fail "the built app's signature doesn't verify"
hardened "$APP" || fail "the built app has no hardened runtime"
fi
[ -d "$APP" ] || fail "no app at $APP"

notarize "$APP"

info "Creating the DMG..."
if [ -x "$DEN_DIR/scripts/build-release.sh" ]; then
    APP_NAME="$APP_NAME" PROJECT_ROOT="$DEN_ROOT" "$DEN_DIR/scripts/build-release.sh" --dmg
else
    echo "[WARN] no Den checkout at $DEN_DIR: a plain DMG, without the laid-out window" >&2
    staging="$OUT/dmg"
    mkdir -p "$staging"
    cp -R "$APP" "$staging/"
    ln -s /Applications "$staging/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$staging" -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$staging"
fi
[ -f "$DMG" ] || fail "no DMG was made"
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"
notarize "$DMG"

verify
info "Done: $DMG"
