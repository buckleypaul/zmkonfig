# Build and bundle Zmkonfig with Command Line Tools only — no Xcode, no
# .xcodeproj. `make run` produces a real .app and launches it.

APP_NAME        := Zmkonfig
BUNDLE_ID       := com.buckleypaul.zmkonfig
VERSION         := 0.1.0
CONFIG          ?= release

BUILD_DIR       := .build
APP             := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS        := $(APP)/Contents
MACOS_DIR       := $(CONTENTS)/MacOS
RESOURCES_DIR   := $(CONTENTS)/Resources
# SwiftPM names resource bundles <package>_<target>.bundle.
RESOURCE_BUNDLE := Zmkonfig_ZmkonfigKit.bundle

# Deferred: only valid once `swift build` has run.
BIN_PATH         = $(shell swift build -c $(CONFIG) --show-bin-path)

# Who signs the app. An ad-hoc signature (`-`) needs no setup, but it gives the
# app a different code identity on every rebuild — so the keychain no longer
# recognises it, and macOS asks for your login password again to hand over the
# saved Anthropic API key. "Always Allow" only holds until the next build.
#
# Any real certificate fixes that: the identity stays the same across rebuilds,
# so you authorise the app once and it sticks. The first of these that exists is
# used, in this order:
#
#   1. A self-signed "Zmkonfig Local" code-signing certificate. Nothing to buy
#      and nothing expires out from under you if you give it a long validity.
#      Keychain Access → Certificate Assistant → Create a Certificate…
#        Name: Zmkonfig Local · Self Signed Root · Code Signing
#   2. A Developer ID Application certificate — what you would ship with.
#   3. An Apple Development certificate, which a free Apple ID already gives you.
#      These expire yearly; when yours does, the password prompt comes back and
#      renewing the certificate is the fix, not a code change.
#
# Revoked certificates are skipped. The SHA-1 hash is passed to codesign rather
# than the name, so identities with awkward characters still work. Override with
# `make CODESIGN_IDENTITY="Some Other Identity" run`, or force ad hoc with
# `make CODESIGN_IDENTITY=- run`.
SIGNING_CERT    := Zmkonfig Local
FOUND_IDENTITY  := $(shell ids=$$(security find-identity -v -p codesigning 2>/dev/null | grep -v CSSMERR); \
	for pat in "$(SIGNING_CERT)" "Developer ID Application" "Apple Development"; do \
		hash=$$(printf '%s\n' "$$ids" | grep -F "$$pat" | head -1 | awk '{print $$2}'); \
		if [ -n "$$hash" ]; then echo "$$hash"; break; fi; \
	done)
CODESIGN_IDENTITY ?= $(if $(FOUND_IDENTITY),$(FOUND_IDENTITY),-)

.PHONY: all build bundle run test clean

all: bundle

## Compile the executable and its resource bundle.
build:
	swift build -c $(CONFIG)

## Assemble .build/Zmkonfig.app around the compiled executable.
bundle: build
	rm -rf "$(APP)"
	mkdir -p "$(MACOS_DIR)" "$(RESOURCES_DIR)"
	cp "$(BIN_PATH)/$(APP_NAME)" "$(MACOS_DIR)/$(APP_NAME)"
	# The kit's resources (ZMK behaviors and keycodes). Contents/Resources is
	# the only place codesign will seal a nested bundle; AppResources.kit knows
	# to look here.
	@test -d "$(BIN_PATH)/$(RESOURCE_BUNDLE)" || \
	  { echo "$(RESOURCE_BUNDLE) is missing from $(BIN_PATH)"; exit 1; }
	cp -R "$(BIN_PATH)/$(RESOURCE_BUNDLE)" "$(RESOURCES_DIR)/$(RESOURCE_BUNDLE)"
	@printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0">' \
	  '<dict>' \
	  '  <key>CFBundleDevelopmentRegion</key><string>en</string>' \
	  '  <key>CFBundleExecutable</key><string>$(APP_NAME)</string>' \
	  '  <key>CFBundleIdentifier</key><string>$(BUNDLE_ID)</string>' \
	  '  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>' \
	  '  <key>CFBundleName</key><string>$(APP_NAME)</string>' \
	  '  <key>CFBundleDisplayName</key><string>$(APP_NAME)</string>' \
	  '  <key>CFBundlePackageType</key><string>APPL</string>' \
	  '  <key>CFBundleShortVersionString</key><string>$(VERSION)</string>' \
	  '  <key>CFBundleVersion</key><string>$(VERSION)</string>' \
	  '  <key>LSMinimumSystemVersion</key><string>15.0</string>' \
	  '  <key>NSHighResolutionCapable</key><true/>' \
	  '  <key>NSSupportsAutomaticTermination</key><true/>' \
	  '</dict>' \
	  '</plist>' \
	  > "$(CONTENTS)/Info.plist"
	# Unsigned binaries are killed on Apple silicon, so this is not optional.
	codesign --force --sign "$(CODESIGN_IDENTITY)" "$(APP)"
	@if [ "$(CODESIGN_IDENTITY)" = "-" ]; then echo \
	  "Signed ad hoc — macOS will re-ask for keychain access after every build. See CODESIGN_IDENTITY in the Makefile."; \
	else security find-identity -v -p codesigning | grep -F "$(CODESIGN_IDENTITY)" \
	  | sed -e 's/^ *[0-9]*) /Signed with /'; fi
	@echo "Bundled $(APP)"

## Bundle, then launch it.
run: bundle
	open "$(APP)"

# swift-testing ships in the active developer directory, which SwiftPM does not
# add to the framework search path. Bare `swift test` builds and then runs zero
# tests, and Command Line Tools has no `xctest` to fall back to. The flags must
# be global — SwiftPM's generated runner target needs them too, so putting them
# in Package.swift's testTarget is not enough. Resolved against whichever
# toolchain is selected, so this works with or without Xcode.
TESTING_FW := $(shell d=$$(xcode-select -p); \
	for c in "$$d/Library/Developer/Frameworks" "$$d/Library/Frameworks"; do \
		[ -d "$$c/Testing.framework" ] && echo "$$c" && break; \
	done)
TESTING_LIB := $(shell d=$$(xcode-select -p); \
	for c in "$$d/Library/Developer/usr/lib" "$$d/usr/lib"; do \
		[ -d "$$c" ] && echo "$$c" && break; \
	done)

test:
	@[ -n "$(TESTING_FW)" ] || { echo "Testing.framework not found under $$(xcode-select -p)"; exit 1; }
	swift test \
	  -Xswiftc -F -Xswiftc "$(TESTING_FW)" \
	  -Xlinker -F -Xlinker "$(TESTING_FW)" \
	  -Xlinker -rpath -Xlinker "$(TESTING_FW)" \
	  -Xlinker -rpath -Xlinker "$(TESTING_LIB)"

clean:
	rm -rf "$(BUILD_DIR)"
