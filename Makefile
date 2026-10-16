PREFIX ?= $(HOME)/.local

.PHONY: install
install:
	cargo install --locked --force --path . --root $(PREFIX)

MAC_APPS ?= $(HOME)/Applications

# Builds the Mac app into its own folder (never the build/ a dev copy runs from)
# and installs it to ~/Applications. Quit the installed app first.
.PHONY: install-mac
install-mac:
	@if pgrep -f "$(MAC_APPS)/Bosun.app/Contents/MacOS/Bosun" >/dev/null; then echo "quit Bosun.app in $(MAC_APPS) first" >&2; exit 1; fi
	BOSUN_BUILD_DIR=build-release macos/Bosun/build.sh
	mkdir -p "$(MAC_APPS)"
	rm -rf "$(MAC_APPS)/Bosun.app"
	cp -R macos/Bosun/build-release/Bosun.app "$(MAC_APPS)/"
	@echo "installed $(MAC_APPS)/Bosun.app"
