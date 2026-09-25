#include "scan.h"

#include <dirent.h>
#include <fcntl.h>
#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/vnode.h>
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
#include <unordered_set>

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

// One directory entry, from getattrlistbulk or the readdir fallback.
struct Entry {
  const char* name;
  bool isDir;
  uint64_t alloc;
  double mtime, atime, birth;
};

double ts(const struct timespec& t) { return t.tv_sec + t.tv_nsec * 1e-9; }

struct Walker {
  const ScanOptions& opts;
  const std::unordered_map<std::string, double>& md;
  std::unordered_set<std::string> mdDirs;  // directories containing at least one Spotlight hit
  std::string home;
  double now;
  std::vector<dev_t> allowedDevs;
  // The data volume is reached through firmlinks (/Users, /Applications, …); walking its
  // mount point as well would count everything twice.
  std::vector<std::string> skipDirs{"/System/Volumes/Data"};

  std::mutex mu;
  std::condition_variable cv;
  std::vector<WorkItem> queue;
  std::atomic<size_t> queued{0};  // queue.size(), readable without the lock
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
    mdDirs.reserve(md.size() / 4 + 16);
    for (const auto& kv : md) {
      size_t slash = kv.first.find_last_of('/');
      if (slash != std::string::npos) mdDirs.emplace(kv.first.substr(0, slash == 0 ? 1 : slash));
    }
  }

  bool devAllowed(dev_t d) const {
    if (!opts.sameDevice) return true;
    return std::find(allowedDevs.begin(), allowedDevs.end(), d) != allowedDevs.end();
  }

  void push(WorkItem w) {
    pending.fetch_add(1);
    {
      std::lock_guard<std::mutex> lk(mu);
      queue.push_back(std::move(w));
      queued.store(queue.size(), std::memory_order_relaxed);
    }
    cv.notify_one();
  }

  void storeNode(int32_t id, DirNode&& node) {
    std::lock_guard<std::mutex> lk(resMu);
    if (nodes.size() <= static_cast<size_t>(id)) nodes.resize(id + 1024);
    nodes[id] = std::move(node);
  }

  struct DirCtx {
    const WorkItem& w;
    DirNode& node;
    std::vector<WorkItem>& subdirs;
    bool dirHasMd;
    std::string full;  // scratch: w.path + "/" + name
    uint64_t nfiles = 0;
  };

  void joinPath(DirCtx& c, const char* name) {
    c.full.assign(c.w.path);
    if (c.full.empty() || c.full.back() != '/') c.full += '/';
    c.full += name;
  }

  void onEntry(DirCtx& c, const Entry& e) {
    if (e.isDir) {
      joinPath(c, e.name);
      c.subdirs.push_back(WorkItem{nextId.fetch_add(1, std::memory_order_relaxed), c.w.id, c.full, e.name});
      return;
    }
    double lu = e.mtime;
    if (opts.useAtime) lu = std::max(lu, e.atime);
    bool bigFile = e.alloc >= opts.bigFileBytes;
    bool hasMd = false;
    if (c.dirHasMd || bigFile) joinPath(c, e.name);
    if (c.dirHasMd) {
      auto it = md.find(c.full);
      hasMd = it != md.end();
      if (hasMd) lu = std::max(lu, it->second);
    }
    if (lu > now) lu = now;
    bool never = !hasMd && std::fabs(e.mtime - e.birth) < 60 && (now - e.birth) > 30 * 86400.0;
    DirNode& node = c.node;
    node.size += e.alloc;
    node.bucketSize[bucketFor(lu, now)] += e.alloc;
    if (never) node.neverOpenedSize += e.alloc;
    if (lu > node.lastUsed) node.lastUsed = lu;
    ++c.nfiles;
    if (bigFile) {
      std::lock_guard<std::mutex> lk(resMu);
      big.push_back(FileRec{c.full, e.alloc, lu, never});
    }
  }

  // getattrlistbulk returns hundreds of entries with their metadata per syscall, instead of
  // one fstatat per entry. Returns false if the file system doesn't support it.
  bool bulkList(int dfd, DirCtx& c, std::vector<char>& buf) {
    struct attrlist al;
    memset(&al, 0, sizeof al);
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_CRTIME |
                    ATTR_CMN_MODTIME | (opts.useAtime ? ATTR_CMN_ACCTIME : 0);
    al.fileattr = ATTR_FILE_ALLOCSIZE;
    bool first = true;
    for (;;) {
      int n = getattrlistbulk(dfd, &al, buf.data(), buf.size(), 0);
      if (n < 0) {
        if (first && (errno == ENOTSUP || errno == EINVAL)) return false;
        errors.fetch_add(1);
        return true;
      }
      if (n == 0) return true;
      first = false;
      const char* p = buf.data();
      for (int i = 0; i < n; ++i) {
        uint32_t len;
        memcpy(&len, p, sizeof len);
        const char* f = p + sizeof len;
        attribute_set_t ret;
        memcpy(&ret, f, sizeof ret);
        f += sizeof ret;
        Entry e{nullptr, false, 0, 0, 0, 0};
        if (ret.commonattr & ATTR_CMN_NAME) {
          attrreference_t r;
          memcpy(&r, f, sizeof r);
          e.name = f + r.attr_dataoffset;
          f += sizeof r;
        }
        if (ret.commonattr & ATTR_CMN_OBJTYPE) {
          fsobj_type_t t;
          memcpy(&t, f, sizeof t);
          e.isDir = t == VDIR;
          f += sizeof t;
        }
        struct timespec t;
        if (ret.commonattr & ATTR_CMN_CRTIME) { memcpy(&t, f, sizeof t); e.birth = ts(t); f += sizeof t; }
        if (ret.commonattr & ATTR_CMN_MODTIME) { memcpy(&t, f, sizeof t); e.mtime = ts(t); f += sizeof t; }
        if (ret.commonattr & ATTR_CMN_ACCTIME) { memcpy(&t, f, sizeof t); e.atime = ts(t); f += sizeof t; }
        if (ret.fileattr & ATTR_FILE_ALLOCSIZE) {
          off_t a;
          memcpy(&a, f, sizeof a);
          e.alloc = a > 0 ? static_cast<uint64_t>(a) : 0;
          f += sizeof a;
        }
        p += len;
        if (e.name) onEntry(c, e);
      }
    }
  }

  void readdirList(int dfd, DirCtx& c) {
    DIR* dp = fdopendir(dup(dfd));
    if (!dp) {
      errors.fetch_add(1);
      return;
    }
    struct stat st;
    while (struct dirent* de = readdir(dp)) {
      if (de->d_name[0] == '.' && (de->d_name[1] == 0 || (de->d_name[1] == '.' && de->d_name[2] == 0)))
        continue;
      if (fstatat(dirfd(dp), de->d_name, &st, AT_SYMLINK_NOFOLLOW) != 0) {
        errors.fetch_add(1);
        continue;
      }
      Entry e{de->d_name, S_ISDIR(st.st_mode), static_cast<uint64_t>(st.st_blocks) * 512,
              ts(st.st_mtimespec), ts(st.st_atimespec), ts(st.st_birthtimespec)};
      onEntry(c, e);
    }
    closedir(dp);
  }

  // Directories are walked depth-first inside a worker (opening children relative to the
  // parent fd avoids a full path lookup per directory); work is only handed to the shared
  // queue when it runs low, so other threads stay busy.
  void processDir(const WorkItem& w, int parentFd, int depth, std::vector<char>& buf) {
    DirNode node;
    node.path = w.path;
    node.parent = w.parent;
    std::vector<WorkItem> subdirs;

    const int oflags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC;
    int dfd = parentFd >= 0 ? openat(parentFd, w.name.c_str(), oflags) : open(w.path.c_str(), oflags);
    struct stat st;
    bool haveSt = dfd >= 0 && fstat(dfd, &st) == 0;
    bool skip = w.id != 0 && (std::find(skipDirs.begin(), skipDirs.end(), w.path) != skipDirs.end() ||
                              (haveSt && !devAllowed(st.st_dev)));
    if (skip) {
      // Another volume's mount point: leave a hole that the roll-up and the UI ignore.
      if (dfd >= 0) close(dfd);
      node.path.clear();
      node.parent = -2;
      storeNode(w.id, std::move(node));
      return;
    }

    node.category = w.id == 0 ? CAT_NONE : classifyDir(w.path, w.name, home);
    node.unit = node.category != CAT_NONE && node.category != CAT_DOWNLOADS;
    {
      auto it = md.find(w.path);
      if (it != md.end()) node.mdLastUsed = it->second;
    }

    DirCtx c{w, node, subdirs, !md.empty() && mdDirs.count(w.path) > 0, {}, 0};
    c.full.reserve(w.path.size() + 64);
    if (dfd < 0) {
      errors.fetch_add(1);
    } else {
      double dirMtime = 0;
      if (haveSt) {
        node.size += static_cast<uint64_t>(st.st_blocks) * 512;
        dirMtime = ts(st.st_mtimespec);
      }
      if (!bulkList(dfd, c, buf)) readdirList(dfd, c);
      node.files = c.nfiles;
      if (node.files == 0 && subdirs.empty()) node.lastUsed = std::min(dirMtime, now);
      if (c.nfiles) {
        uint64_t f = files.fetch_add(c.nfiles, std::memory_order_relaxed) + c.nfiles;
        if (opts.progressFiles && (f >> 12) != ((f - c.nfiles) >> 12))
          opts.progressFiles->store(f, std::memory_order_relaxed);
      }
    }
    if (node.mdLastUsed > node.lastUsed) node.lastUsed = node.mdLastUsed;

    node.children.reserve(subdirs.size());
    for (auto& s : subdirs) node.children.push_back(s.id);
    storeNode(w.id, std::move(node));
    if (subdirs.empty()) {
      if (dfd >= 0) close(dfd);
      return;
    }

    size_t local = subdirs.size();
    bool cancelled = opts.cancel && opts.cancel->load(std::memory_order_relaxed);
    if (dfd < 0 || depth >= kMaxLocalDepth || cancelled) local = 0;
    size_t shared = 0;
    if (local == 0 || (subdirs.size() > 1 && queued.load(std::memory_order_relaxed) < lowWater)) {
      std::lock_guard<std::mutex> lk(mu);
      if (local == 0) shared = subdirs.size();
      else if (queue.size() < lowWater) shared = std::min(subdirs.size() - 1, lowWater - queue.size());
      if (shared) {
        pending.fetch_add(static_cast<int64_t>(shared));
        for (size_t i = subdirs.size() - shared; i < subdirs.size(); ++i) queue.push_back(std::move(subdirs[i]));
        queued.store(queue.size(), std::memory_order_relaxed);
      }
    }
    if (shared == 1) cv.notify_one();
    else if (shared > 1) cv.notify_all();

    for (size_t i = 0; i + shared < subdirs.size(); ++i) {
      if (opts.cancel && opts.cancel->load(std::memory_order_relaxed)) break;
      processDir(subdirs[i], dfd, depth + 1, buf);
    }
    if (dfd >= 0) close(dfd);
  }

  static constexpr int kMaxLocalDepth = 48;  // bounds open fds held down one recursion chain
  size_t lowWater = 16;

  void worker() {
    std::vector<char> buf(256 * 1024);
    for (;;) {
      WorkItem w;
      {
        std::unique_lock<std::mutex> lk(mu);
        cv.wait(lk, [&] { return !queue.empty() || pending.load() == 0; });
        if (queue.empty()) return;
        w = std::move(queue.back());
        queue.pop_back();
        queued.store(queue.size(), std::memory_order_relaxed);
      }
      if (opts.cancel && opts.cancel->load(std::memory_order_relaxed)) {
        std::lock_guard<std::mutex> lk(mu);
        pending.fetch_sub(static_cast<int64_t>(queue.size()));
        queue.clear();
        queued.store(0, std::memory_order_relaxed);
      } else {
        processDir(w, -1, 0, buf);
      }
      if (pending.fetch_sub(1) == 1) {
        // Taking the lock orders this after any waiter's predicate check, so the
        // final wake-up can't slip between a check and the wait.
        { std::lock_guard<std::mutex> lk(mu); }
        cv.notify_all();
      }
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
  walker.allowedDevs.push_back(st.st_dev);
  // The system snapshot and the data volume are one disk from the user's point of view.
  struct stat sys, data;
  if (::stat("/", &sys) == 0 && ::stat("/System/Volumes/Data", &data) == 0 &&
      (st.st_dev == sys.st_dev || st.st_dev == data.st_dev)) {
    walker.allowedDevs.push_back(sys.st_dev);
    walker.allowedDevs.push_back(data.st_dev);
  }

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
    if (d.path.empty() && &d != &res.dirs[0]) d.parent = -2;  // never processed (cancelled) or skipped

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
