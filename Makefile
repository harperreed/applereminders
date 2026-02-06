# ABOUTME: Build automation for reminders-mcp.
# ABOUTME: Provides targets for building, testing, installing, and cleaning the project.

PREFIX ?= /usr/local
INSTALL_DIR = $(PREFIX)/bin
BUILD_DIR = .build
RELEASE_BIN = $(BUILD_DIR)/release/reminders
DEBUG_BIN = $(BUILD_DIR)/debug/reminders

.PHONY: all build release test install uninstall clean lint tag

all: build

build:
	swift build

release:
	swift build -c release

test:
	swift test

install: release
	install -d $(INSTALL_DIR)
	install -m 755 $(RELEASE_BIN) $(INSTALL_DIR)/reminders

uninstall:
	rm -f $(INSTALL_DIR)/reminders

clean:
	swift package clean
	rm -rf $(BUILD_DIR)

lint:
	swift build 2>&1 | head -50

run: build
	$(DEBUG_BIN) --help

tag: test
	@if [ -z "$(VERSION)" ]; then echo "Usage: make tag VERSION=v1.0.0"; exit 1; fi
	git tag -a $(VERSION) -m "Release $(VERSION)"
	git push origin $(VERSION)
