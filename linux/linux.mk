# Linux build: `stale` (CLI + TUI), plus the desktop entry, Omarchy shell plugin and Waybar
# module installed by `make install` (see linux/README.md).
CXX ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -Wno-unused-parameter
LDFLAGS ?=
LDLIBS += -pthread
DESTDIR ?=
VERSION ?= 1.4.0

BUILD = build
SRC = src
CORE = $(BUILD)/scan.o $(BUILD)/recent_linux.o $(BUILD)/index.o $(BUILD)/finders_linux.o $(BUILD)/trash.o
OBJS = $(CORE) $(BUILD)/main.o $(BUILD)/status.o $(BUILD)/tui.o
HEADERS = $(wildcard $(SRC)/*.h)

all: $(BUILD)/stale
cli: $(BUILD)/stale

test: $(BUILD)/stale_test
	./$(BUILD)/stale_test

$(BUILD)/stale: $(OBJS)
	$(CXX) $(LDFLAGS) $(OBJS) $(LDLIBS) -o $@

$(BUILD)/stale_test: tests/stale_test.mm $(CORE) $(HEADERS)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -I$(SRC) -x c++ tests/stale_test.mm -x none $(CORE) $(LDFLAGS) $(LDLIBS) -o $@

$(BUILD)/%.o: $(SRC)/%.cpp $(HEADERS) | $(BUILD)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -c $< -o $@

$(BUILD):
	mkdir -p $(BUILD)

SHARE = $(DESTDIR)$(PREFIX)/share
install: $(BUILD)/stale
	install -Dm755 $(BUILD)/stale $(DESTDIR)$(PREFIX)/bin/stale
	install -Dm755 linux/stale-omarchy $(DESTDIR)$(PREFIX)/bin/stale-omarchy
	install -Dm644 linux/stale.desktop $(SHARE)/applications/stale.desktop
	install -Dm644 site/public/icon.png $(SHARE)/icons/hicolor/512x512/apps/stale.png
	install -Dm644 linux/omarchy/manifest.json $(SHARE)/stale/omarchy/manifest.json
	install -Dm644 linux/omarchy/BarWidget.qml $(SHARE)/stale/omarchy/BarWidget.qml
	install -Dm644 linux/waybar/stale.jsonc $(SHARE)/stale/waybar/stale.jsonc
	install -Dm644 linux/waybar/stale.css $(SHARE)/stale/waybar/stale.css
	install -Dm644 linux/systemd/stale-refresh.service $(DESTDIR)$(PREFIX)/lib/systemd/user/stale-refresh.service
	install -Dm644 linux/systemd/stale-refresh.timer $(DESTDIR)$(PREFIX)/lib/systemd/user/stale-refresh.timer
	install -Dm644 LICENSE $(SHARE)/licenses/stale/LICENSE

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/stale $(DESTDIR)$(PREFIX)/bin/stale-omarchy
	rm -f $(SHARE)/applications/stale.desktop $(SHARE)/icons/hicolor/512x512/apps/stale.png
	rm -rf $(SHARE)/stale $(SHARE)/licenses/stale
	rm -f $(DESTDIR)$(PREFIX)/lib/systemd/user/stale-refresh.service $(DESTDIR)$(PREFIX)/lib/systemd/user/stale-refresh.timer

clean:
	rm -rf $(BUILD) dist

.PHONY: all cli test install uninstall clean
