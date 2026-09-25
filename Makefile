PREFIX ?= /usr/local
CXX ?= clang++
# Universal binary by default; ARCHS=arm64 for a quicker local build.
ARCHS ?= arm64 x86_64
ARCHFLAGS = $(foreach a,$(ARCHS),-arch $(a))
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min=12.0
OBJCXXFLAGS = $(CXXFLAGS) -fobjc-arc
LDFLAGS = $(ARCHFLAGS) -framework Foundation -framework CoreServices

# Release metadata. VERSION is the user-facing version, BUILD the monotonically
# increasing bundle version (defaults to the commit count).
VERSION ?= 1.0.0
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

BUILD = build
SRC = src
CORE = $(BUILD)/scan.o $(BUILD)/spotlight.o
OBJS = $(CORE) $(BUILD)/main.o
APP = $(BUILD)/Stale.app
APP_BIN = $(APP)/Contents/MacOS/Stale
ICON = $(BUILD)/Stale.icns
DIST = dist
ZIP = $(DIST)/Stale-$(VERSION).zip
DMG = $(DIST)/Stale-$(VERSION).dmg

all: $(BUILD)/stale $(APP_BIN)

cli: $(BUILD)/stale
app: $(APP_BIN)

$(BUILD)/stale: $(OBJS)
	$(CXX) $(OBJS) $(LDFLAGS) -o $@
	codesign -f $(SIGN_FLAGS) $@

$(APP_BIN): $(CORE) $(BUILD)/app.o app/Info.plist app/Stale.entitlements $(ICON)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	sed -e 's/@VERSION@/$(VERSION)/' -e 's/@BUILD@/$(BUILD_NUMBER)/' app/Info.plist > $(APP)/Contents/Info.plist
	cp $(ICON) $(APP)/Contents/Resources/Stale.icns
	$(CXX) $(CORE) $(BUILD)/app.o $(LDFLAGS) -framework Cocoa -o $@
	codesign -f $(SIGN_FLAGS) --entitlements app/Stale.entitlements $(APP)

$(BUILD)/app.o: app/main.mm $(SRC)/scan.h | $(BUILD)
	$(CXX) $(OBJCXXFLAGS) $(ARCHFLAGS) -c $< -o $@

$(BUILD)/mkicon: app/mkicon.mm | $(BUILD)
	$(CXX) $(OBJCXXFLAGS) $< -framework Cocoa -o $@

$(ICON): $(BUILD)/mkicon
	rm -rf $(BUILD)/Stale.iconset
	$(BUILD)/mkicon $(BUILD)/Stale.iconset
	iconutil -c icns $(BUILD)/Stale.iconset -o $@

run: $(APP_BIN)
	open $(APP)

$(BUILD)/%.o: $(SRC)/%.cpp $(SRC)/scan.h | $(BUILD)
	$(CXX) $(CXXFLAGS) $(ARCHFLAGS) -c $< -o $@

$(BUILD)/%.o: $(SRC)/%.mm $(SRC)/scan.h | $(BUILD)
	$(CXX) $(OBJCXXFLAGS) $(ARCHFLAGS) -c $< -o $@

$(BUILD):
	mkdir -p $(BUILD)

# ── distribution ──────────────────────────────────────────────────────────────

dist: $(ZIP) $(DMG)

$(ZIP): $(APP_BIN)
	mkdir -p $(DIST)
	rm -f $@
	ditto -c -k --keepParent $(APP) $@

$(DMG): $(APP_BIN)
	mkdir -p $(DIST) $(BUILD)/dmg
	rm -rf $(BUILD)/dmg/* $@
	cp -R $(APP) $(BUILD)/dmg/
	ln -s /Applications $(BUILD)/dmg/Applications
	hdiutil create -quiet -volname "Stale" -srcfolder $(BUILD)/dmg -ov -format UDZO $@
	@if [ "$(SIGN_IDENTITY)" != "-" ]; then codesign -f $(SIGN_FLAGS) $@; fi

# Submits the DMG to Apple, waits for the verdict, then staples the ticket so the
# app opens offline without a Gatekeeper warning. Requires SIGN_IDENTITY.
notarize: $(DMG)
	xcrun notarytool submit $(DMG) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(DMG)
	xcrun stapler staple $(APP)
	spctl -a -vv -t open --context context:primary-signature $(DMG)

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
