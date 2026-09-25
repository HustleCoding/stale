#include "scan.h"

#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <climits>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <thread>

namespace stale {

const char* const kBucketNames[NBUCKETS] = {"hot", "warm", "cold", "stale", "frozen"};
const int kBucketMaxDays[NBUCKETS] = {7, 30, 180, 365, INT_MAX};

const char* const kCategoryNames[NCATEGORIES] = {
    "",        "node_modules", "build", "venv",  "cache", "xcode",
    "docker",  "downloads",    "trash", "git",   "app",   "bundle"};

bool categoryReclaimable(Category c) {
  switch (c) {
    case CAT_NODE_MODULES:
    case CAT_BUILD:
    case CAT_VENV:
    case CAT_CACHE:
    case CAT_XCODE:
    case CAT_DOCKER:
    case CAT_TRASH:
      return true;
    default:
      return false;
  }
}

Bucket bucketFor(double lastUsed, double now) {
  double days = (now - lastUsed) / 86400.0;
  for (int i = 0; i < NBUCKETS - 1; ++i)
    if (days < kBucketMaxDays[i]) return static_cast<Bucket>(i);
  return FROZEN;
}

namespace {

bool endsWith(const std::string& s, const char* suf) {
  size_t n = strlen(suf);
  return s.size() >= n && s.compare(s.size() - n, n, suf) == 0;
}

bool exists(const std::string& p) {
  struct stat st;
  return ::lstat(p.c_str(), &st) == 0;
}

bool hasProjectMarker(const std::string& parent) {
  static const char* markers[] = {"package.json", "Cargo.toml",    "CMakeLists.txt",
                                  "pyproject.toml", "setup.py",    "go.mod",
                                  "Package.swift",  "build.gradle", "build.gradle.kts",
                                  "pom.xml",        "Makefile",    "meson.build"};
  for (const char* m : markers)
    if (exists(parent + "/" + m)) return true;
  return false;
}

bool inSet(const std::string& s, std::initializer_list<const char*> set) {
  for (const char* x : set)
    if (s == x) return true;
  return false;
}

// Relative path from home (without leading slash), or "" if not under home.
std::string relHome(const std::string& path, const std::string& home) {
  if (home.empty() || path.size() <= home.size() || path.compare(0, home.size(), home) != 0 ||
      path[home.size()] != '/')
    return "";
  return path.substr(home.size() + 1);
}

}  // namespace

Category classifyDir(const std::string& path, const std::string& name, const std::string& home) {
  if (name == "node_modules") return CAT_NODE_MODULES;
  if (name == ".git") return CAT_GIT;
  if (name == ".Trash") return CAT_TRASH;
  if (endsWith(name, ".app")) return CAT_APP;
  if (inSet(name, {".next", ".turbo", ".nuxt", ".svelte-kit", ".parcel-cache", ".output",
                   ".angular", ".gradle", ".dart_tool", "DerivedData", ".build", ".vercel",
                   ".wrangler", ".open-next", ".serverless", ".terraform", "bazel-out"}))
    return CAT_BUILD;
  if (inSet(name, {"__pycache__", ".venv", "venv", ".tox", ".mypy_cache", ".pytest_cache",
                   ".ruff_cache", ".ipynb_checkpoints"}))
    return CAT_VENV;
  if (name == "env" && exists(path + "/pyvenv.cfg")) return CAT_VENV;

  std::string parent = path.substr(0, path.find_last_of('/'));
  if (inSet(name, {"dist", "build", "out", "target", "_build", "cmake-build-debug",
                   "cmake-build-release", "Pods", "vendor", ".dist"}) &&
      hasProjectMarker(parent))
    return CAT_BUILD;

  static const char* bundleExts[] = {
      ".photoslibrary", ".xcodeproj",  ".xcworkspace", ".framework",  ".bundle",
      ".playground",    ".xcarchive",  ".imovielibrary", ".fcpbundle", ".sparsebundle",
      ".tvlibrary",     ".musiclibrary", ".logicx",     ".key",        ".pages",
      ".numbers",       ".band",       ".pkg",         ".xcappdata",  ".appex",
      ".qlgenerator",   ".plugin",     ".kext",        ".dSYM",       ".scptd",
      ".rtfd",          ".download",   ".prefPane",    ".vmwarevm",   ".pvm",
      ".utm"};
  for (const char* e : bundleExts)
    if (endsWith(name, e)) return CAT_BUNDLE;

  std::string rel = relHome(path, home);
  if (rel.empty()) return CAT_NONE;
  std::string relParent = relHome(parent, home);

  if (rel == "Downloads") return CAT_DOWNLOADS;
  if (relParent == "Library/Caches" || relParent == ".cache" || rel == "Library/Logs" ||
      inSet(rel, {".npm", ".yarn/cache", ".pnpm-store", "Library/pnpm", ".cargo/registry",
                  ".cargo/git", ".gradle/caches", ".m2/repository", "go/pkg/mod",
                  ".cocoapods", ".bun/install/cache", ".rustup/toolchains", ".nvm/.cache",
                  "Library/Application Support/Code/Cache",
                  "Library/Application Support/Code/CachedData",
                  "Library/Application Support/Code/CachedExtensionVSIXs",
                  "Library/Application Support/Cursor/Cache",
                  "Library/Application Support/Cursor/CachedData",
                  "Library/Application Support/Google/Chrome/Default/Service Worker/CacheStorage",
                  "Library/Application Support/Slack/Cache",
                  "Library/Application Support/Slack/Service Worker/CacheStorage",
                  "Library/Application Support/discord/Cache",
                  "Library/Application Support/Spotify/PersistentCache",
                  "Library/Application Support/Steam/steamapps/shadercache",
                  ".ollama/models", ".cache/huggingface"}))
    return CAT_CACHE;
  if (inSet(rel, {"Library/Developer/Xcode/DerivedData", "Library/Developer/Xcode/Archives",
                  "Library/Developer/Xcode/iOS DeviceSupport",
                  "Library/Developer/Xcode/watchOS DeviceSupport",
                  "Library/Developer/Xcode/tvOS DeviceSupport",
                  "Library/Developer/Xcode/UserData/Previews",
                  "Library/Developer/CoreSimulator/Caches", "Library/Developer/XCPGDevices", "Library/Developer/XCTestDevices",
                  "Library/Developer/Xcode/Products"}))
    return CAT_XCODE;
  if (relParent == "Library/Developer/CoreSimulator/Devices") return CAT_XCODE;
  if (inSet(rel, {"Library/Containers/com.docker.docker/Data", ".docker", ".orbstack",
                  ".colima", ".lima", ".rd", "Library/Containers/com.docker.docker"}))
    return CAT_DOCKER;
  return CAT_NONE;
}

namespace {

struct WorkItem {
  int32_t id;
  int32_t parent;
  std::string path;
  std::string name;
};

struct Walker {
  const ScanOptions& opts;
  const std::unordered_map<std::string, double>& md;
  std::string home;
  double now;
  dev_t rootDev = 0;

  std::mutex mu;
  std::condition_variable cv;
  std::vector<WorkItem> queue;
  std::atomic<int32_t> nextId{0};
  std::atomic<int64_t> pending{0};
  std::atomic<uint64_t> files{0};
  std::atomic<uint64_t> errors{0};

  std::mutex resMu;
  std::vector<DirNode> nodes;  // indexed by id, resized under resMu
  std::vector<FileRec> big;

  Walker(const ScanOptions& o, const std::unordered_map<std::string, double>& m, double n)
      : opts(o), md(m), now(n) {
    const char* h = getenv("HOME");
    if (h) home = h;
  }

  void push(WorkItem w) {
    pending.fetch_add(1);
    {
      std::lock_guard<std::mutex> lk(mu);
      queue.push_back(std::move(w));
    }
    cv.notify_one();
  }

  double lastUsedOf(const struct stat& st, const std::string& path, bool* hasMd) {
    double m = st.st_mtimespec.tv_sec + st.st_mtimespec.tv_nsec * 1e-9;
    double lu = m;
    if (opts.useAtime) {
      double a = st.st_atimespec.tv_sec + st.st_atimespec.tv_nsec * 1e-9;
      lu = std::max(lu, a);
    }
    auto it = md.find(path);
    *hasMd = it != md.end();
    if (*hasMd) lu = std::max(lu, it->second);
    if (lu > now) lu = now;
    return lu;
  }

  void processDir(const WorkItem& w) {
    DirNode node;
    node.path = w.path;
    node.parent = w.parent;
    node.category = w.id == 0 ? CAT_NONE : classifyDir(w.path, w.name, home);
    node.unit = node.category != CAT_NONE && node.category != CAT_DOWNLOADS;
    {
      auto it = md.find(w.path);
      if (it != md.end()) node.mdLastUsed = it->second;
    }

    std::vector<WorkItem> subdirs;
    DIR* dp = opendir(w.path.c_str());
    if (!dp) {
      errors.fetch_add(1);
    } else {
      int dfd = dirfd(dp);
      struct stat st;
      double dirMtime = 0;
      if (fstat(dfd, &st) == 0) {
        node.size += static_cast<uint64_t>(st.st_blocks) * 512;
        dirMtime = st.st_mtimespec.tv_sec + st.st_mtimespec.tv_nsec * 1e-9;
      }
      while (struct dirent* de = readdir(dp)) {
        if (de->d_name[0] == '.' && (de->d_name[1] == 0 || (de->d_name[1] == '.' && de->d_name[2] == 0)))
          continue;
        if (fstatat(dfd, de->d_name, &st, AT_SYMLINK_NOFOLLOW) != 0) {
          errors.fetch_add(1);
          continue;
        }
        std::string full = w.path;
        if (full.empty() || full.back() != '/') full += '/';
        full += de->d_name;
        if (S_ISDIR(st.st_mode)) {
          if (opts.sameDevice && st.st_dev != rootDev) continue;
          subdirs.push_back(WorkItem{nextId.fetch_add(1), w.id, std::move(full), de->d_name});
          continue;
        }
        uint64_t sz = static_cast<uint64_t>(st.st_blocks) * 512;
        bool hasMd = false;
        double lu = lastUsedOf(st, full, &hasMd);
        double birth = st.st_birthtimespec.tv_sec + st.st_birthtimespec.tv_nsec * 1e-9;
        double mt = st.st_mtimespec.tv_sec + st.st_mtimespec.tv_nsec * 1e-9;
        bool never = !hasMd && std::fabs(mt - birth) < 60 && (now - birth) > 30 * 86400.0;
        node.size += sz;
        node.files += 1;
        node.bucketSize[bucketFor(lu, now)] += sz;
        if (never) node.neverOpenedSize += sz;
        if (lu > node.lastUsed) node.lastUsed = lu;
        uint64_t f = files.fetch_add(1) + 1;
        if (opts.progressFiles && (f & 1023) == 0) opts.progressFiles->store(f, std::memory_order_relaxed);
        if (sz >= opts.bigFileBytes) {
          std::lock_guard<std::mutex> lk(resMu);
          big.push_back(FileRec{full, sz, lu, never});
        }
      }
      closedir(dp);
      if (node.files == 0 && subdirs.empty()) node.lastUsed = std::min(dirMtime, now);
    }
    if (node.mdLastUsed > node.lastUsed) node.lastUsed = node.mdLastUsed;

    node.children.reserve(subdirs.size());
    for (auto& s : subdirs) node.children.push_back(s.id);
    {
      std::lock_guard<std::mutex> lk(resMu);
      if (nodes.size() <= static_cast<size_t>(w.id)) nodes.resize(w.id + 1024);
      nodes[w.id] = std::move(node);
    }
    for (auto& s : subdirs) push(std::move(s));
  }

  void worker() {
    for (;;) {
      WorkItem w;
      {
        std::unique_lock<std::mutex> lk(mu);
        cv.wait(lk, [&] { return !queue.empty() || pending.load() == 0; });
        if (queue.empty()) return;
        w = std::move(queue.back());
        queue.pop_back();
      }
      if (opts.cancel && opts.cancel->load(std::memory_order_relaxed)) {
        std::lock_guard<std::mutex> lk(mu);
        pending.fetch_sub(static_cast<int64_t>(queue.size()));
        queue.clear();
      } else {
        processDir(w);
      }
      if (pending.fetch_sub(1) == 1) cv.notify_all();
    }
  }
};

}  // namespace

ScanResult scan(const ScanOptions& opts) {
  auto t0 = std::chrono::steady_clock::now();
  ScanResult res;
  res.now = std::chrono::duration<double>(std::chrono::system_clock::now().time_since_epoch()).count();

  std::unordered_map<std::string, double> md;
  if (opts.spotlight) md = spotlightLastUsed(opts.root);
  res.spotlightHits = md.size();
  if (getenv("STALE_DEBUG"))
    fprintf(stderr, "spotlight: %zu hits in %.2fs\n", md.size(),
            std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count());

  Walker walker(opts, md, res.now);
  struct stat st;
  if (::stat(opts.root.c_str(), &st) != 0) {
    res.errors = 1;
    return res;
  }
  walker.rootDev = st.st_dev;

  std::string rootName = opts.root.substr(opts.root.find_last_of('/') + 1);
  walker.push(WorkItem{walker.nextId.fetch_add(1), -1, opts.root, rootName});

  int n = opts.threads > 0 ? opts.threads : static_cast<int>(std::thread::hardware_concurrency());
  if (n < 1) n = 4;
  std::vector<std::thread> threads;
  for (int i = 0; i < n; ++i) threads.emplace_back([&] { walker.worker(); });
  for (auto& t : threads) t.join();

  res.dirs = std::move(walker.nodes);
  res.dirs.resize(walker.nextId.load());
  res.bigFiles = std::move(walker.big);
  res.files = walker.files.load();
  res.errors = walker.errors.load();
  if (opts.progressFiles) opts.progressFiles->store(res.files);
  for (auto& d : res.dirs)
    if (d.path.empty() && &d != &res.dirs[0]) d.parent = -2;  // never processed (cancelled)

  // Roll up children into parents. Children always have larger ids than parents.
  for (int32_t i = static_cast<int32_t>(res.dirs.size()) - 1; i > 0; --i) {
    DirNode& c = res.dirs[i];
    if (c.parent < 0) continue;
    DirNode& p = res.dirs[c.parent];
    p.size += c.size;
    p.files += c.files;
    for (int b = 0; b < NBUCKETS; ++b) p.bucketSize[b] += c.bucketSize[b];
    p.neverOpenedSize += c.neverOpenedSize;
    if (c.unit && categoryReclaimable(c.category)) {
      p.reclaimableSize += c.size;
      for (int b = 0; b < NBUCKETS; ++b) p.reclaimableBucketSize[b] += c.bucketSize[b];
    } else {
      p.reclaimableSize += c.reclaimableSize;
      for (int b = 0; b < NBUCKETS; ++b) p.reclaimableBucketSize[b] += c.reclaimableBucketSize[b];
    }
    if (c.lastUsed > p.lastUsed) p.lastUsed = c.lastUsed;
  }
  // A directory with nothing inside inherits its own mtime as "used".
  for (auto& d : res.dirs)
    if (d.lastUsed == 0) d.lastUsed = d.mdLastUsed;

  std::sort(res.bigFiles.begin(), res.bigFiles.end(),
            [](const FileRec& a, const FileRec& b) { return a.size > b.size; });

  res.seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  res.spotlight = std::move(md);
  return res;
}

void collectUnits(const ScanResult& r, int32_t id, std::vector<int32_t>& out,
                  const std::function<bool(const DirNode&)>& pred) {
  const DirNode& d = r.dirs[id];
  if (id != 0 && d.unit) {
    if (pred(d)) out.push_back(id);
    return;
  }
  for (int32_t c : d.children) collectUnits(r, c, out, pred);
}

void collectForgotten(const ScanResult& r, int32_t id, std::vector<int32_t>& out, uint64_t minBytes) {
  const DirNode& d = r.dirs[id];
  if (d.size < minBytes) return;
  if (id != 0 && d.unit && categoryReclaimable(d.category)) return;
  // Judge only the non-regenerable content; reclaimable units are reported separately.
  uint64_t own = d.size - d.reclaimableSize;
  uint64_t old = d.bucketSize[STALE] + d.bucketSize[FROZEN] - d.reclaimableBucketSize[STALE] -
                 d.reclaimableBucketSize[FROZEN];
  if (id != 0 && own >= minBytes && old * 10 >= own * 9 && bucketFor(d.lastUsed, r.now) >= STALE) {
    out.push_back(id);
    return;
  }
  if (d.unit && id != 0) return;
  for (int32_t c : d.children) collectForgotten(r, c, out, minBytes);
}

}  // namespace stale
