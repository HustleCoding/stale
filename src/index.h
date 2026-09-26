#pragma once
#include <string>
#include <vector>

#include "scan.h"

namespace stale {

// Everything about an index besides the scan itself.
struct IndexMeta {
  double savedAt = 0;
  uint64_t eventId = 0;                  // FSEvents id current when saved; 0 = unknown
  std::vector<std::string> volumeUUIDs;  // FSEvents UUIDs of the volumes covered, root first
};

std::string indexDir();
std::string indexPath(const std::string& root);

// Encode the index (gone directories are dropped and ids compacted). Empty on failure.
std::string encodeIndex(const std::string& root, const ScanResult& r, const IndexMeta& meta);
// Atomically replace `file` with `bytes`.
bool writeIndex(const std::string& file, const std::string& bytes);

bool saveIndex(const std::string& file, const std::string& root, const ScanResult& r, const IndexMeta& meta);

// False if missing, corrupt, from another version, or for another root.
bool loadIndex(const std::string& file, const std::string& root, ScanResult& out, IndexMeta* meta);

}  // namespace stale
