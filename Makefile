SWIFTC ?= swiftc
TARGET := arm64-apple-macos14
BUILD := build
SWIFTFLAGS := -O -target $(TARGET) -swift-version 5 -module-cache-path $(BUILD)/ModuleCache

SAVER := $(BUILD)/Nebula.saver
HARNESS := $(BUILD)/NebulaHarness.app
INSTALL_DIR := $(HOME)/Library/Screen Savers

SAVER_SOURCES := $(wildcard Sources/Saver/*.swift)
HARNESS_SOURCES := $(wildcard Sources/Harness/*.swift)
SHADERS := Sources/Saver/Shaders.metal
THUMBNAILS := $(SAVER)/Contents/Resources/thumbnail.png $(SAVER)/Contents/Resources/thumbnail@2x.png

.PHONY: all saver harness run snapshot thumbnail install clean

all: saver harness

saver: $(SAVER)/Contents/MacOS/Nebula $(SAVER)/Contents/Resources/Shaders.metal $(SAVER)/Contents/Info.plist $(THUMBNAILS)
	codesign --force --sign - $(SAVER)

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

$(SAVER)/Contents/Info.plist: Resources/Saver-Info.plist
	@mkdir -p $(@D)
	cp $< $@

$(HARNESS)/Contents/Info.plist: Resources/Harness-Info.plist
	@mkdir -p $(@D)
	cp $< $@

run: harness
	$(HARNESS)/Contents/MacOS/NebulaHarness

snapshot: harness
	$(HARNESS)/Contents/MacOS/NebulaHarness --snapshot $(BUILD)/snapshot.png --time $(or $(TIME),20) --size $(or $(SIZE),2880x1800) --scale $(or $(SCALE),2) --seed $(or $(SEED),1)

# regenerates the System Settings tile images (90x58 and 2x) from a fixed seed and time
thumbnail: harness
	$(HARNESS)/Contents/MacOS/NebulaHarness --snapshot $(BUILD)/thumbnail-source.png --time $(or $(TIME),30) --size 1440x928 --scale 1 --seed $(or $(SEED),3)
	sips -z 116 180 $(BUILD)/thumbnail-source.png --out Resources/thumbnail@2x.png
	sips -z 58 90 $(BUILD)/thumbnail-source.png --out Resources/thumbnail.png

install: saver
	@mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/Nebula.saver"
	cp -R $(SAVER) "$(INSTALL_DIR)/"
	-killall legacyScreenSaver 2>/dev/null

clean:
	rm -rf $(BUILD)
