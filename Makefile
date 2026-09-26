PREFIX ?= /usr/local
CXX ?= clang++
# Universal binary by default; ARCHS=arm64 for a quicker local build.
ARCHS ?= arm64 x86_64
ARCHFLAGS = $(foreach a,$(ARCHS),-arch $(a))
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min=12.0
OBJCXXFLAGS = $(CXXFLAGS) -fobjc-arc
LDFLAGS = $(ARCHFLAGS) -framework Foundation -framework CoreServices -framework AppKit

# Release metadata. VERSION is the user-facing version, BUILD the monotonically
# increasing bundle version (defaults to the commit count).
VERSION ?= 1.3.2
BUILD_NUMBER ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 1)

# Code signing. Default is ad-hoc (runs locally, Gatekeeper warns on other Macs).
# For distribution: make dist SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
SIGN_IDENTITY ?= -
ifeq ($(SIGN_IDENTITY),-)
SIGN_FLAGS = -s -
else
SIGN_FLAGS = -s "$(SIGN_IDENTITY)" --timestamp --options runtime
endif
# Notarization uses a keychain profile created once with:
#   xcrun notarytool store-credentials stale --apple-id you@example.com --team-id TEAMID
NOTARY_PROFILE ?= stale

# Sparkle auto-updates. The framework is fetched once and checked against a pinned hash.
# SPARKLE_PUBLIC_KEY is the EdDSA public key from Sparkle's generate_keys; when empty the
# app builds without its "Check for Updates…" item (e.g. local/dev builds).
SPARKLE_VERSION = 2.10.0
SPARKLE_SHA256 = c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
SPARKLE_PUBLIC_KEY ?= P+6QxTZeKqPsGYamKkuCQYwshob+0i/Ck0E8SLBX9nM=
SPARKLE_FEED = https://github.com/HustleCoding/stale/releases/latest/download/appcast.xml
SPARKLE_DIR = $(BUILD)/Sparkle-$(SPARKLE_VERSION)
SPARKLE_FW = $(SPARKLE_DIR)/Sparkle.framework

BUILD = build
SRC = src
CORE = $(BUILD)/scan.o $(BUILD)/spotlight.o $(BUILD)/index.o $(BUILD)/fsevents.o $(BUILD)/finders.o
OBJS = $(CORE) $(BUILD)/main.o
APP = $(BUILD)/Stale.app
APP_BIN = $(APP)/Contents/MacOS/Stale
ICON = $(BUILD)/Stale.icns
DMG_BG = $(BUILD)/dmg-background.tiff
DIST = dist
ZIP = $(DIST)/Stale-$(VERSION).zip
DMG = $(DIST)/Stale-$(VERSION).dmg

all: $(BUILD)/stale $(APP_BIN)

cli: $(BUILD)/stale
app: $(APP_BIN)

$(BUILD)/stale: $(OBJS)
	$(CXX) $(OBJS) $(LDFLAGS) -o $@
	codesign -f $(SIGN_FLAGS) $@

$(APP_BIN): $(CORE) $(BUILD)/app.o app/Info.plist app/Stale.entitlements $(ICON) $(SPARKLE_FW)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources $(APP)/Contents/Frameworks
	sed -e 's/@VERSION@/$(VERSION)/' -e 's/@BUILD@/$(BUILD_NUMBER)/' \
	    -e 's|@SPARKLE_FEED@|$(SPARKLE_FEED)|' -e 's|@SPARKLE_PUBLIC_KEY@|$(SPARKLE_PUBLIC_KEY)|' \
	    app/Info.plist > $(APP)/Contents/Info.plist
	cp $(ICON) $(APP)/Contents/Resources/Stale.icns
	$(CXX) $(CORE) $(BUILD)/app.o $(LDFLAGS) -framework Cocoa -framework Quartz \
	    -F$(SPARKLE_DIR) -framework Sparkle -Wl,-rpath,@executable_path/../Frameworks -o $@
	ditto $(SPARKLE_FW) $(APP)/Contents/Frameworks/Sparkle.framework
	@# Stale isn't sandboxed, so Sparkle's XPC services are unused (per Sparkle's sandboxing docs).
	rm -rf $(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices \
	       $(APP)/Contents/Frameworks/Sparkle.framework/XPCServices
	codesign -f $(SIGN_FLAGS) $(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate
	codesign -f $(SIGN_FLAGS) $(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app
	codesign -f $(SIGN_FLAGS) $(APP)/Contents/Frameworks/Sparkle.framework
	codesign -f $(SIGN_FLAGS) --entitlements app/Stale.entitlements $(APP)

$(BUILD)/app.o: app/main.mm $(SRC)/scan.h $(SRC)/index.h $(SRC)/fsevents.h $(SRC)/finders.h $(SPARKLE_FW) | $(BUILD)
	$(CXX) $(OBJCXXFLAGS) $(ARCHFLAGS) -F$(SPARKLE_DIR) -c $< -o $@

$(SPARKLE_FW): | $(BUILD)
	curl -fsSL -o $(BUILD)/Sparkle-$(SPARKLE_VERSION).tar.xz \
	    https://github.com/sparkle-project/Sparkle/releases/download/$(SPARKLE_VERSION)/Sparkle-$(SPARKLE_VERSION).tar.xz
	echo "$(SPARKLE_SHA256)  $(BUILD)/Sparkle-$(SPARKLE_VERSION).tar.xz" | shasum -a 256 -c -
	rm -rf $(SPARKLE_DIR) && mkdir -p $(SPARKLE_DIR)
	tar -xJf $(BUILD)/Sparkle-$(SPARKLE_VERSION).tar.xz -C $(SPARKLE_DIR)
	touch $@

$(BUILD)/mkicon: app/mkicon.mm | $(BUILD)
	$(CXX) $(OBJCXXFLAGS) $< -framework Cocoa -o $@

$(ICON): $(BUILD)/mkicon
	rm -rf $(BUILD)/Stale.iconset
	$(BUILD)/mkicon $(BUILD)/Stale.iconset
	iconutil -c icns $(BUILD)/Stale.iconset -o $@

$(BUILD)/mkdmgbg: app/mkdmgbg.mm | $(BUILD)
	$(CXX) $(OBJCXXFLAGS) $< -framework Cocoa -o $@

$(DMG_BG): $(BUILD)/mkdmgbg
	$(BUILD)/mkdmgbg $(BUILD)/dmg-bg.png $(BUILD)/dmg-bg@2x.png
	tiffutil -cathidpicheck $(BUILD)/dmg-bg.png $(BUILD)/dmg-bg@2x.png -out $@

run: $(APP_BIN)
	open $(APP)

$(BUILD)/%.o: $(SRC)/%.cpp $(SRC)/scan.h $(SRC)/index.h | $(BUILD)
	$(CXX) $(CXXFLAGS) $(ARCHFLAGS) -c $< -o $@

$(BUILD)/%.o: $(SRC)/%.mm $(SRC)/scan.h $(SRC)/fsevents.h $(SRC)/finders.h | $(BUILD)
	$(CXX) $(OBJCXXFLAGS) $(ARCHFLAGS) -c $< -o $@

$(BUILD):
	mkdir -p $(BUILD)

# ── distribution ──────────────────────────────────────────────────────────────

dist: $(ZIP) $(DMG)

$(ZIP): $(APP_BIN)
	mkdir -p $(DIST)
	rm -f $@
	ditto -c -k --keepParent $(APP) $@

$(DMG): $(APP_BIN) $(DMG_BG) app/dmg.sh
	mkdir -p $(DIST)
	bash app/dmg.sh $(APP) $(DMG_BG) $(ICON) $@
	@if [ "$(SIGN_IDENTITY)" != "-" ]; then codesign -f $(SIGN_FLAGS) $@; fi

# Notarizes the app, staples it, repackages the stapled app into zip + DMG, then
# notarizes and staples the DMG so both open offline without a Gatekeeper warning.
# Requires SIGN_IDENTITY and a notarytool keychain profile (NOTARY_PROFILE).
notarize: $(APP_BIN)
	@test "$(SIGN_IDENTITY)" != "-" || { echo "notarize needs SIGN_IDENTITY=\"Developer ID Application: ...\""; exit 1; }
	ditto -c -k --keepParent $(APP) $(BUILD)/notarize.zip
	xcrun notarytool submit $(BUILD)/notarize.zip --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(APP)
	rm -f $(ZIP) $(DMG)
	$(MAKE) $(ZIP) $(DMG) SIGN_IDENTITY="$(SIGN_IDENTITY)" VERSION="$(VERSION)"
	xcrun notarytool submit $(DMG) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(DMG)
	spctl -a -vv -t open --context context:primary-signature $(DMG)
	spctl -a -vv $(APP)

verify: $(APP_BIN)
	codesign --verify --deep --strict --verbose=2 $(APP)
	spctl -a -vv $(APP) || true

install: $(BUILD)/stale $(APP_BIN)
	install -d $(PREFIX)/bin
	install -m 755 $(BUILD)/stale $(PREFIX)/bin/stale
	rm -rf /Applications/Stale.app && cp -R $(APP) /Applications/Stale.app

uninstall:
	rm -f $(PREFIX)/bin/stale
	rm -rf /Applications/Stale.app

clean:
	rm -rf $(BUILD) $(DIST)

.PHONY: all cli app run dist notarize verify install uninstall clean
