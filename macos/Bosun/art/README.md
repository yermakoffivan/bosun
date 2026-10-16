# App icon

`bosun-icon.png` is the source artwork. `make-icon.swift` crops it to its opaque area and places it on the macOS icon grid (an 824 px body on a 1024 px canvas, scaled for each size, with a soft drop shadow). Regenerate `../Assets.xcassets/AppIcon.appiconset` from the repo's `macos/Bosun` directory with:

```sh
swiftc -O art/make-icon.swift -o /tmp/make-icon
for sz in 16 32 128 256 512; do for sc in 1 2; do px=$((sz*sc)); /tmp/make-icon art/bosun-icon.png "Assets.xcassets/AppIcon.appiconset/icon_${sz}x${sz}@${sc}x.png" $px $((px*824/1024)); done; done
```
