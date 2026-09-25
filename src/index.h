#pragma once
#include <string>

#include "scan.h"

namespace stale {

// On-disk copy of a completed scan so the app opens instantly and only rescans on demand.
// Files live in ~/Library/Application Support/Stale/, one per scanned root.

std::string indexDir();
std::string indexPath(const std::string& root);

// Serialize without touching the disk (fast enough for the main thread), then write
// atomically (tmp file + rename) from any thread.
std::string encodeIndex(const std::string& root, const ScanResult& r, double savedAt);
bool writeIndex(const std::string& file, const std::string& bytes);

// encodeIndex + writeIndex. `savedAt` is unix seconds.
bool saveIndex(const std::string& file, const std::string& root, const ScanResult& r, double savedAt);

// Returns false (and leaves `out` untouched) for a missing, corrupt, foreign-root or
// incompatible-version file.
bool loadIndex(const std::string& file, const std::string& root, ScanResult& out, double* savedAt);

}  // namespace stale
