// One-line disk summary for status bars (Waybar, the Omarchy shell bar).
#pragma once

#include <cstdint>
#include <string>

#include "scan.h"

namespace stale {

std::string humanBytes(uint64_t bytes);  // "12.3G"

// Totals of the last scan of home, written by `stale status --refresh` and `stale tui`.
struct Summary {
  double scannedAt = 0;
  uint64_t scanned = 0, reclaimable = 0, unused = 0, files = 0;
};
Summary summarize(const ScanResult& r);
bool writeSummary(const Summary& s);
bool readSummary(Summary& s);

// Prints disk usage of home's file system plus the last scan's totals, as text or as a
// Waybar custom-module JSON object.
int printStatus(const std::string& home, bool json);
// Rescans home, stores the summary (and the index on Linux), then prints the status.
int refreshStatus(const std::string& home, int threads, bool json);

}  // namespace stale
