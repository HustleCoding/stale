PREFIX ?= /usr/local
CXX ?= clang++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -Wno-unused-parameter
OBJCXXFLAGS = $(CXXFLAGS) -fobjc-arc
LDFLAGS = -framework Foundation -framework CoreServices

BUILD = build
SRC = src
OBJS = $(BUILD)/scan.o $(BUILD)/spotlight.o $(BUILD)/main.o

all: $(BUILD)/stale

$(BUILD)/stale: $(OBJS)
	$(CXX) $(OBJS) $(LDFLAGS) -o $@
	codesign -s - -f $@ 2>/dev/null || true

$(BUILD)/%.o: $(SRC)/%.cpp $(SRC)/scan.h | $(BUILD)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(BUILD)/%.o: $(SRC)/%.mm $(SRC)/scan.h | $(BUILD)
	$(CXX) $(OBJCXXFLAGS) -c $< -o $@

$(BUILD):
	mkdir -p $(BUILD)

install: $(BUILD)/stale
	install -d $(PREFIX)/bin
	install -m 755 $(BUILD)/stale $(PREFIX)/bin/stale

uninstall:
	rm -f $(PREFIX)/bin/stale

clean:
	rm -rf $(BUILD)

.PHONY: all install uninstall clean
