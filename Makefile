PREFIX ?= $(HOME)/.local

.PHONY: install
install:
	cargo install --locked --force --path . --root $(PREFIX)
