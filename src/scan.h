#pragma once
#include <atomic>
#include <cstdint>
#include <functional>
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

// What a directory holds directly: its own entry plus the files immediately inside it.
// Stored in the index; the recursive totals below are rebuilt from it (see rollup).
struct DirOwn {
  uint64_t size = 0;
  uint64_t files = 0;
  uint64_t bucketSize[NBUCKETS] = {0, 0, 0, 0, 0};
  uint64_t neverOpenedSize = 0;
  double lastUsed = 0;
};

struct DirNode {
  std::string path;        // empty (for id != 0): gone, skipped or never scanned — ignore
  int32_t parent = -1;
  Category category = CAT_NONE;
  bool unit = false;       // treat as a leaf in reports (node_modules, .app, .git ...)
  DirOwn own;
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
  uint64_t bigFileBytes = 4ull << 20;  // files this big are kept in the index (duplicate candidates)
  bool sameDevice = true;
  bool spotlight = true;
  std::atomic<uint64_t>* progressFiles = nullptr;  // updated while scanning (optional)
  std::atomic<bool>* cancel = nullptr;             // set to stop early (optional)
};

// "Big unused files" reports files at least this big.
constexpr uint64_t kBigFileReport = 100ull << 20;

struct ScanResult {
  std::vector<DirNode> dirs;       // dirs[0] is root; children always have larger ids than parents
  std::vector<FileRec> bigFiles;  // files >= bigFileBytes
  uint64_t bigFileBytes = 0;
  uint64_t files = 0;
  uint64_t errors = 0;
  double now = 0;
  double seconds = 0;
  size_t spotlightHits = 0;
  std::unordered_map<std::string, double> spotlight;  // path -> last opened, for on-demand file rows
};

// Spotlight: path -> last used (unix seconds) for everything under root.
std::unordered_map<std::string, double> spotlightLastUsed(const std::string& root);
// Same, restricted to the given folders (recursively).
std::unordered_map<std::string, double> spotlightLastUsedIn(const std::vector<std::string>& dirs);

ScanResult scan(const ScanOptions& opts);

// Recompute every directory's recursive totals from `own` and its children.
void rollup(ScanResult& r);

// Walks root→leaf by path components; -1 when `path` isn't a live directory of `r`.
int32_t findDir(const ScanResult& r, const std::string& path);

// Detach `id` and everything below it from the model (after trashing or when FSEvents says it
// vanished). Totals are not touched; call rollup.
void markGone(ScanResult& r, int32_t id);

// ───── incremental refresh ─────
// A changed folder reported by FSEvents. `subtree` = the whole hierarchy below must be re-read.
struct RefreshRequest {
  std::string path;
  bool subtree = false;
};

// Work for one folder, resolved against the model on the owning thread so the I/O can run
// elsewhere without touching `r`.
struct RefreshJob {
  int32_t id = -1;
  std::string path;
  bool subtree = false;
  std::vector<std::pair<std::string, int32_t>> children;  // live child name -> id
};

struct RefreshPlan {
  std::vector<RefreshJob> jobs;
  int32_t idBase = 0;     // dirs.size() when planned; new nodes are numbered from here
  bool tooMuch = false;   // a full scan is cheaper / safer
};

struct RefreshPatch {
  struct Relist {
    int32_t id = -1;
    bool gone = false;        // the folder itself no longer exists
    bool unreadable = false;  // keep the old numbers
    DirOwn own;
    std::vector<int32_t> goneChildren;
    std::vector<int32_t> newChildren;  // ids >= idBase, roots of `newNodes` subtrees
  };
  int32_t idBase = 0;
  std::vector<Relist> relists;
  std::vector<DirNode> newNodes;             // absolute ids idBase.., parents may point into r
  std::vector<std::string> dropBigUnder;     // dirname == p  (relisted folders)
  std::vector<std::string> dropBigBelow;     // path prefix   (rescanned subtrees)
  std::vector<FileRec> newBig;
  std::vector<std::string> dropSpotlightBelow;
  std::unordered_map<std::string, double> spotlight;
  uint64_t errors = 0;
};

// Trailing slashes off, `/System/Volumes/Data` folded onto `/` (done by planRefresh too).
std::string normalizeEventPath(std::string p);
// 1. On the thread that owns `r`: resolve requests to jobs (dedupes, drops nested ones).
RefreshPlan planRefresh(const ScanResult& r, std::vector<RefreshRequest> changes);
// 2. Anywhere: do the file-system work. `md` is r.spotlight (read only).
RefreshPatch collectRefresh(const ScanOptions& opts, const RefreshPlan& plan,
                            const std::unordered_map<std::string, double>& md);
// 3. On the owning thread again: apply and roll up. Returns false if `r` changed shape meanwhile.
bool applyRefresh(ScanResult& r, RefreshPatch&& patch);

// Rollup helper used by reports: mark nodes below `unit` nodes.
Category classifyDir(const std::string& path, const std::string& name, const std::string& home);

// Top-most unit directories (not nested inside another unit) accepted by `pred`.
void collectUnits(const ScanResult& r, int32_t id, std::vector<int32_t>& out,
                  const std::function<bool(const DirNode&)>& pred);

// Highest-level folders (not inside units) whose non-reclaimable content is >=90% stale/frozen
// and at least `minBytes`.
void collectForgotten(const ScanResult& r, int32_t id, std::vector<int32_t>& out, uint64_t minBytes);

}  // namespace stale
