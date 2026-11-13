SWIFTC ?= swiftc
TARGET := arm64-apple-macos14
BUILD := build
SWIFTFLAGS := -O -target $(TARGET) -swift-version 5 -module-cache-path $(BUILD)/ModuleCache

SAVER := $(BUILD)/Nebula.saver
HARNESS := $(BUILD)/NebulaHarness.app
INSTALL_DIR := $(HOME)/Library/Screen Savers

# a plain release number, not semver; it is both the bundle's short version and its build number
VERSION := $(shell cat VERSION)
ZIP := $(BUILD)/nebula-$(VERSION).zip

# first developer id in the keychain, falling back to ad-hoc; override with make SIGN_IDENTITY=...
SIGN_IDENTITY ?= $(or $(shell security find-identity -v -p codesigning | grep -m1 -o '"Developer ID Application[^"]*"' | tr -d '"'),-)
# notarisation needs a secure timestamp, which needs the network; skipped for local builds
TIMESTAMP := --timestamp=none
# stored with: xcrun notarytool store-credentials notarytool
NOTARY_PROFILE := notarytool

SAVER_SOURCES := $(wildcard Sources/Saver/*.swift)
HARNESS_SOURCES := $(wildcard Sources/Harness/*.swift)
SHADERS := Sources/Saver/Shaders.metal
THUMBNAILS := $(SAVER)/Contents/Resources/thumbnail.png $(SAVER)/Contents/Resources/thumbnail@2x.png

.PHONY: all saver harness run snapshot thumbnail install notarise dist release clean check-notarise

all: saver harness

saver: $(SAVER)/Contents/MacOS/Nebula $(SAVER)/Contents/Resources/Shaders.metal $(SAVER)/Contents/Info.plist $(THUMBNAILS)
	codesign --force --options runtime $(TIMESTAMP) --sign "$(SIGN_IDENTITY)" $(SAVER)

harness: $(HARNESS)/Contents/MacOS/NebulaHarness $(HARNESS)/Contents/Resources/Shaders.metal $(HARNESS)/Contents/Info.plist
	codesign --force --sign - $(HARNESS)

$(SAVER)/Contents/MacOS/Nebula: $(SAVER_SOURCES)
	@mkdir -p $(@D)
	$(SWIFTC) $(SWIFTFLAGS) -module-name Nebula -emit-library -Xlinker -bundle -o $@ $(SAVER_SOURCES)

$(HARNESS)/Contents/MacOS/NebulaHarness: $(SAVER_SOURCES) $(HARNESS_SOURCES)
	@mkdir -p $(@D)
	$(SWIFTC) $(SWIFTFLAGS) -module-name NebulaHarness -o $@ $(SAVER_SOURCES) $(HARNESS_SOURCES)

$(SAVER)/Contents/Resources/Shaders.metal $(HARNESS)/Contents/Resources/Shaders.metal: $(SHADERS)
	@mkdir -p $(@D)
	cp $< $@

$(SAVER)/Contents/Resources/thumbnail%: Resources/thumbnail%
	@mkdir -p $(@D)
	cp $< $@

$(SAVER)/Contents/Info.plist: Resources/Saver-Info.plist VERSION
	@mkdir -p $(@D)
	cp $< $@
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" $@
	plutil -replace CFBundleVersion -string "$(VERSION)" $@

$(HARNESS)/Contents/Info.plist: Resources/Harness-Info.plist
	@mkdir -p $(@D)
	cp $< $@

run: harness
	$(HARNESS)/Contents/MacOS/NebulaHarness

snapshot: harness
	$(HARNESS)/Contents/MacOS/NebulaHarness --snapshot $(BUILD)/snapshot.png --time $(or $(TIME),60) --size $(or $(SIZE),2880x1800) --scale $(or $(SCALE),2) --seed $(or $(SEED),1)

# regenerates the System Settings tile images (90x58 and 2x) from a fixed seed and time
thumbnail: harness
	$(HARNESS)/Contents/MacOS/NebulaHarness --snapshot $(BUILD)/thumbnail-source.png --time $(or $(TIME),60) --size 1440x928 --scale 1 --seed $(or $(SEED),3)
	sips -z 116 180 $(BUILD)/thumbnail-source.png --out Resources/thumbnail@2x.png
	sips -z 58 90 $(BUILD)/thumbnail-source.png --out Resources/thumbnail.png

install: saver
	@mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/Nebula.saver"
	cp -R $(SAVER) "$(INSTALL_DIR)/"
	killall legacyScreenSaver 2>/dev/null || true

# stapling fails unless notarisation was accepted
notarise: TIMESTAMP := --timestamp
notarise: check-notarise saver
	ditto -c -k --keepParent $(SAVER) $(BUILD)/notarise.zip
	xcrun notarytool submit $(BUILD)/notarise.zip --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple $(SAVER)
	rm $(BUILD)/notarise.zip

# a clean, notarised build zipped on its own; ditto preserves the bundle's signature
dist:
	rm -rf $(BUILD)
	$(MAKE) notarise
	ditto -c -k --keepParent $(SAVER) $(ZIP)

# only publishes what's on github; the tag is created at the exact local commit
release:
	git fetch
	test -z "$$(git status --porcelain)" || { echo "cannot publish with uncommitted changes" >&2; exit 1; }
	test -z "$$(git log HEAD --not --remotes --format=%H)" || { echo "cannot publish with unpushed changes" >&2; exit 1; }
	test "$$(git rev-list --count HEAD..origin/main)" = 0 || { echo "cannot publish as local clone is behind origin" >&2; exit 1; }
	! gh release view "v$(VERSION)" >/dev/null 2>&1 || { echo "v$(VERSION) has already been published" >&2; exit 1; }
	$(MAKE) dist
	gh release create "v$(VERSION)" "$(ZIP)" --target "$$(git rev-parse HEAD)" \
		--title "Nebula $(VERSION)" --generate-notes

clean:
	rm -rf $(BUILD)

check-notarise:
	@test "$(SIGN_IDENTITY)" != - || { echo "notarisation needs a developer id application certificate in the keychain" >&2; exit 1; }
