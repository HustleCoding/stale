#pragma once
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

namespace stale {

// Age buckets by "last used" (max of Spotlight last-opened and mtime).
enum Bucket : int { HOT = 0, WARM, COLD, STALE, FROZEN, NBUCKETS };
extern const char* const kBucketNames[NBUCKETS];
extern const int kBucketMaxDays[NBUCKETS];  // upper bound in days, last is INT_MAX

Bucket bucketFor(double lastUsed, double now);

// Reclaimable / semantic categories for directories.
enum Category : int {
  CAT_NONE = 0,
  CAT_NODE_MODULES,
  CAT_BUILD,        // dist/build/target/.next/...
  CAT_VENV,         // python venvs, __pycache__
  CAT_CACHE,        // ~/Library/Caches, ~/.cache, npm/yarn/pip caches
  CAT_XCODE,        // DerivedData, simulators, archives, device support
  CAT_DOCKER,
  CAT_DOWNLOADS,
  CAT_TRASH,
  CAT_GIT,          // .git internals
  CAT_APP,          // *.app bundle
  CAT_BUNDLE,       // other package bundles (.photoslibrary, .xcodeproj, ...)
  NCATEGORIES
};
extern const char* const kCategoryNames[NCATEGORIES];
// Categories whose contents are safe to regenerate/redownload.
bool categoryReclaimable(Category c);

struct FileRec {
  std::string path;
  uint64_t size = 0;      // allocated bytes
  double lastUsed = 0;    // unix seconds
  bool neverOpened = false;
};

struct DirNode {
  std::string path;
  int32_t parent = -1;
  Category category = CAT_NONE;
  bool unit = false;       // treat as a leaf in reports (node_modules, .app, .git ...)
  uint64_t size = 0;       // recursive allocated bytes
  uint64_t files = 0;      // recursive file count
  uint64_t bucketSize[NBUCKETS] = {0, 0, 0, 0, 0};
  uint64_t neverOpenedSize = 0;
  uint64_t reclaimableSize = 0;  // bytes inside reclaimable unit descendants
  uint64_t reclaimableBucketSize[NBUCKETS] = {0, 0, 0, 0, 0};
  double lastUsed = 0;     // newest lastUsed among descendants (and itself)
  double mdLastUsed = 0;   // Spotlight last-opened for the directory itself
  std::vector<int32_t> children;
};

struct ScanOptions {
  std::string root;
  int threads = 0;                 // 0 = hw concurrency
  bool useAtime = false;           // also treat atime as a usage signal
  uint64_t bigFileBytes = 100ull << 20;
  bool sameDevice = true;
  bool spotlight = true;
};

struct ScanResult {
  std::vector<DirNode> dirs;       // dirs[0] is root
  std::vector<FileRec> bigFiles;  // files >= bigFileBytes
  uint64_t files = 0;
  uint64_t errors = 0;
  double now = 0;
  double seconds = 0;
  size_t spotlightHits = 0;
};

// Spotlight: path -> last used (unix seconds) for everything under root.
std::unordered_map<std::string, double> spotlightLastUsed(const std::string& root);

ScanResult scan(const ScanOptions& opts);

// Rollup helper used by reports: mark nodes below `unit` nodes.
Category classifyDir(const std::string& path, const std::string& name, const std::string& home);

}  // namespace stale
