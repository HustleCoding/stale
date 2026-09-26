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
  int32_t id;      // assigned by the parent's processDir, so children always outnumber parents
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

std::string dirName(const std::string& p) {
  size_t slash = p.find_last_of('/');
  return slash == std::string::npos ? std::string() : (slash == 0 ? std::string("/") : p.substr(0, slash));
}

bool underDir(const std::string& p, const std::string& dir) {
  if (dir == "/") return p.size() > 1 && p[0] == '/';
  return p.size() > dir.size() && p.compare(0, dir.size(), dir) == 0 && p[dir.size()] == '/';
}

// Is any proper ancestor of `p` in `dirs`? O(depth) instead of O(|dirs|).
bool anyAncestorIn(const std::string& p, const std::unordered_set<std::string>& dirs) {
  if (dirs.empty()) return false;
  if (p.size() > 1 && dirs.count("/")) return true;
  size_t slash = p.find_last_of('/');
  while (slash != std::string::npos && slash > 0) {
    if (dirs.count(p.substr(0, slash))) return true;
    slash = p.find_last_of('/', slash - 1);
  }
  return false;
}

struct Walker {
  const ScanOptions& opts;
  const std::unordered_map<std::string, double>& md;
  const std::unordered_map<std::string, double>* mdExtra = nullptr;  // fresher entries win
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
  int32_t idBase = 0;             // nodes[i] holds id idBase + i
  std::atomic<int64_t> pending{0};
  std::atomic<uint64_t> files{0};
  std::atomic<uint64_t> errors{0};

  std::mutex resMu;
  std::vector<DirNode> nodes;  // indexed by id - idBase, resized under resMu
  std::vector<FileRec> big;

  Walker(const ScanOptions& o, const std::unordered_map<std::string, double>& m, double n, int32_t base = 0)
      : opts(o), md(m), now(n), nextId(base), idBase(base) {
    const char* h = getenv("HOME");
    if (h) home = h;
    indexMdDirs(md);
  }

  void indexMdDirs(const std::unordered_map<std::string, double>& m) {
    mdDirs.reserve(mdDirs.size() + m.size() / 4 + 16);
    for (const auto& kv : m) {
      size_t slash = kv.first.find_last_of('/');
      if (slash != std::string::npos) mdDirs.emplace(kv.first.substr(0, slash == 0 ? 1 : slash));
    }
  }

  const double* mdFind(const std::string& p) const {
    if (mdExtra) {
      auto it = mdExtra->find(p);
      if (it != mdExtra->end()) return &it->second;
    }
    auto it = md.find(p);
    return it == md.end() ? nullptr : &it->second;
  }

  bool devAllowed(dev_t d) const {
    if (!opts.sameDevice) return true;
    return std::find(allowedDevs.begin(), allowedDevs.end(), d) != allowedDevs.end();
  }

  void allowDevicesOf(const std::string& root) {
    struct stat st;
    if (::stat(root.c_str(), &st) != 0) return;
    allowedDevs.push_back(st.st_dev);
    // The system snapshot and the data volume are one disk from the user's point of view.
    struct stat sys, data;
    if (::stat("/", &sys) == 0 && ::stat("/System/Volumes/Data", &data) == 0 &&
        (st.st_dev == sys.st_dev || st.st_dev == data.st_dev)) {
      allowedDevs.push_back(sys.st_dev);
      allowedDevs.push_back(data.st_dev);
    }
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
    size_t slot = static_cast<size_t>(id - idBase);
    std::lock_guard<std::mutex> lk(resMu);
    if (nodes.size() <= slot) nodes.resize(slot + 1024);
    nodes[slot] = std::move(node);
  }

  struct DirCtx {
    const std::string& path;
    DirOwn& own;
    std::vector<WorkItem>& subdirs;
    std::vector<FileRec>* big;  // where files >= bigFileBytes go (nullptr: Walker::big)
    bool dirHasMd;
    std::string full;  // scratch: path + "/" + name
  };

  void joinPath(DirCtx& c, const char* name) {
    c.full.assign(c.path);
    if (c.full.empty() || c.full.back() != '/') c.full += '/';
    c.full += name;
  }

  void onEntry(DirCtx& c, const Entry& e) {
    if (e.isDir) {
      joinPath(c, e.name);
      c.subdirs.push_back(WorkItem{-1, -1, c.full, e.name});
      return;
    }
    double lu = e.mtime;
    if (opts.useAtime) lu = std::max(lu, e.atime);
    bool bigFile = e.alloc >= opts.bigFileBytes;
    bool hasMd = false;
    if (c.dirHasMd || bigFile) joinPath(c, e.name);
    if (c.dirHasMd) {
      const double* t = mdFind(c.full);
      hasMd = t != nullptr;
      if (hasMd) lu = std::max(lu, *t);
    }
    if (lu > now) lu = now;
    bool never = !hasMd && std::fabs(e.mtime - e.birth) < 60 && (now - e.birth) > 30 * 86400.0;
    DirOwn& own = c.own;
    own.size += e.alloc;
    own.bucketSize[bucketFor(lu, now)] += e.alloc;
    if (never) own.neverOpenedSize += e.alloc;
    if (lu > own.lastUsed) own.lastUsed = lu;
    ++own.files;
    if (bigFile) {
      if (c.big) {
        c.big->push_back(FileRec{c.full, e.alloc, lu, never});
      } else {
        std::lock_guard<std::mutex> lk(resMu);
        big.push_back(FileRec{c.full, e.alloc, lu, never});
      }
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

  static constexpr int kOpenFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC;

  enum class ListStatus { Ok, Missing, Unreadable, Skipped };

  // Reads one directory into `own` and `subdirs` (ids unassigned). `isRoot` disables the
  // other-volume check for the scan root itself.
  ListStatus listDir(int dfd, const std::string& path, bool isRoot, DirOwn& own, std::vector<WorkItem>& subdirs,
                     std::vector<FileRec>* bigOut, std::vector<char>& buf) {
    if (dfd < 0) return errno == ENOENT || errno == ENOTDIR ? ListStatus::Missing : ListStatus::Unreadable;
    struct stat st;
    bool haveSt = fstat(dfd, &st) == 0;
    if (!isRoot && (std::find(skipDirs.begin(), skipDirs.end(), path) != skipDirs.end() ||
                    (haveSt && !devAllowed(st.st_dev))))
      return ListStatus::Skipped;
    DirCtx c{path, own, subdirs, bigOut, !mdDirs.empty() && mdDirs.count(path) > 0, {}};
    c.full.reserve(path.size() + 64);
    double dirMtime = 0;
    if (haveSt) {
      own.size += static_cast<uint64_t>(st.st_blocks) * 512;
      dirMtime = ts(st.st_mtimespec);
    }
    if (!bulkList(dfd, c, buf)) readdirList(dfd, c);
    if (own.files == 0 && subdirs.empty()) own.lastUsed = std::min(dirMtime, now);
    return ListStatus::Ok;
  }

  // Directories are walked depth-first inside a worker (opening children relative to the
  // parent fd avoids a full path lookup per directory); work is only handed to the shared
  // queue when it runs low, so other threads stay busy.
  void processDir(const WorkItem& w, int parentFd, int depth, std::vector<char>& buf) {
    DirNode node;
    node.path = w.path;
    node.parent = w.parent;
    std::vector<WorkItem> subdirs;
    bool isRoot = w.parent < 0;

    int dfd = parentFd >= 0 ? openat(parentFd, w.name.c_str(), kOpenFlags) : open(w.path.c_str(), kOpenFlags);
    ListStatus ls = listDir(dfd, w.path, isRoot, node.own, subdirs, nullptr, buf);
    if (ls == ListStatus::Skipped) {
      // Another volume's mount point: leave a hole that the roll-up and the UI ignore.
      if (dfd >= 0) close(dfd);
      node.path.clear();
      node.parent = -2;
      storeNode(w.id, std::move(node));
      return;
    }
    if (ls != ListStatus::Ok) errors.fetch_add(1);

    node.category = isRoot ? CAT_NONE : classifyDir(w.path, w.name, home);
    node.unit = node.category != CAT_NONE && node.category != CAT_DOWNLOADS;
    if (const double* t = mdFind(w.path)) node.mdLastUsed = *t;
    if (node.own.files) {
      uint64_t f = files.fetch_add(node.own.files, std::memory_order_relaxed) + node.own.files;
      if (opts.progressFiles && (f >> 12) != ((f - node.own.files) >> 12))
        opts.progressFiles->store(f, std::memory_order_relaxed);
    }

    node.children.reserve(subdirs.size());
    for (auto& s : subdirs) {
      s.id = nextId.fetch_add(1, std::memory_order_relaxed);
      s.parent = w.id;
      node.children.push_back(s.id);
    }
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

  void run(int threads) {
    int n = threads > 0 ? threads : static_cast<int>(std::thread::hardware_concurrency());
    if (n < 1) n = 4;
    std::vector<std::thread> ts;
    for (int i = 0; i < n; ++i) ts.emplace_back([&] { worker(); });
    for (auto& t : ts) t.join();
    nodes.resize(static_cast<size_t>(nextId.load() - idBase));
    for (auto& d : nodes)
      if (d.path.empty() && d.parent != -2) d.parent = -2;  // never processed (cancelled) or skipped
  }
};

double wallNow() {
  return std::chrono::duration<double>(std::chrono::system_clock::now().time_since_epoch()).count();
}

}  // namespace

void rollup(ScanResult& r) {
  for (auto& d : r.dirs) {
    d.size = d.own.size;
    d.files = d.own.files;
    for (int b = 0; b < NBUCKETS; ++b) {
      d.bucketSize[b] = d.own.bucketSize[b];
      d.reclaimableBucketSize[b] = 0;
    }
    d.neverOpenedSize = d.own.neverOpenedSize;
    d.reclaimableSize = 0;
    d.lastUsed = std::max(d.own.lastUsed, d.mdLastUsed);
  }
  // Children always have larger ids than parents, so one reverse pass sees every subtree first.
  for (int32_t i = static_cast<int32_t>(r.dirs.size()) - 1; i > 0; --i) {
    DirNode& c = r.dirs[i];
    if (c.parent < 0 || c.path.empty()) continue;
    DirNode& p = r.dirs[c.parent];
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
  if (!r.dirs.empty()) r.files = r.dirs[0].files;
}

ScanResult scan(const ScanOptions& opts) {
  auto t0 = std::chrono::steady_clock::now();
  ScanResult res;
  res.now = wallNow();
  res.bigFileBytes = opts.bigFileBytes;

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
  walker.allowDevicesOf(opts.root);

  std::string rootName = opts.root.substr(opts.root.find_last_of('/') + 1);
  walker.push(WorkItem{walker.nextId.fetch_add(1), -1, opts.root, rootName});
  walker.run(opts.threads);

  res.dirs = std::move(walker.nodes);
  res.bigFiles = std::move(walker.big);
  res.errors = walker.errors.load();
  rollup(res);
  if (opts.progressFiles) opts.progressFiles->store(res.files);

  std::sort(res.bigFiles.begin(), res.bigFiles.end(),
            [](const FileRec& a, const FileRec& b) { return a.size > b.size; });

  res.seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  res.spotlight = std::move(md);
  return res;
}

int32_t findDir(const ScanResult& r, const std::string& path) {
  if (r.dirs.empty()) return -1;
  const std::string& root = r.dirs[0].path;
  if (path == root) return 0;
  std::string prefix = root.back() == '/' ? root : root + "/";
  if (path.compare(0, prefix.size(), prefix) != 0) return -1;
  int32_t cur = 0;
  size_t pos = prefix.size();
  for (;;) {
    size_t next = path.find('/', pos);
    if (next == std::string::npos) next = path.size();
    int32_t found = -1;
    for (int32_t c : r.dirs[cur].children) {
      const std::string& cp = r.dirs[c].path;
      if (cp.size() == next && path.compare(0, next, cp) == 0) { found = c; break; }
    }
    if (found < 0) return -1;
    cur = found;
    if (next == path.size()) return cur;
    pos = next + 1;
  }
}

void markGone(ScanResult& r, int32_t id) {
  if (id <= 0 || id >= static_cast<int32_t>(r.dirs.size())) return;
  DirNode& d = r.dirs[id];
  if (d.parent >= 0) {
    auto& sib = r.dirs[d.parent].children;
    sib.erase(std::remove(sib.begin(), sib.end(), id), sib.end());
  }
  std::vector<int32_t> stack{id};
  while (!stack.empty()) {
    DirNode& n = r.dirs[stack.back()];
    stack.pop_back();
    for (int32_t c : n.children) stack.push_back(c);
    n.children.clear();
    n.path.clear();
    n.parent = -1;
    n.own = DirOwn();
    n.size = n.files = n.neverOpenedSize = n.reclaimableSize = 0;
  }
}

// ───── incremental refresh ─────

std::string normalizeEventPath(std::string p) {
  // FSEvents may name the data volume's mount point rather than the firmlink.
  static const std::string kDataVol = "/System/Volumes/Data";
  if (p.compare(0, kDataVol.size(), kDataVol) == 0 && (p.size() == kDataVol.size() || p[kDataVol.size()] == '/'))
    p = p.size() == kDataVol.size() ? "/" : p.substr(kDataVol.size());
  while (p.size() > 1 && p.back() == '/') p.pop_back();
  return p;
}

RefreshPlan planRefresh(const ScanResult& r, std::vector<RefreshRequest> changes) {
  RefreshPlan plan;
  plan.idBase = static_cast<int32_t>(r.dirs.size());
  if (r.dirs.empty()) {
    plan.tooMuch = true;
    return plan;
  }
  const std::string& root = r.dirs[0].path;
  for (auto& c : changes) c.path = normalizeEventPath(std::move(c.path));
  std::sort(changes.begin(), changes.end(), [](const RefreshRequest& a, const RefreshRequest& b) {
    return a.path.size() != b.path.size() ? a.path.size() < b.path.size() : a.path < b.path;
  });
  // Shortest first: anything inside a subtree request is covered by it; duplicates merge.
  std::vector<RefreshRequest> subtrees;
  std::unordered_map<std::string, size_t> seen;
  std::vector<RefreshRequest> uniq;
  for (auto& c : changes) {
    bool covered = false;
    for (const auto& s : subtrees)
      if (c.path == s.path || underDir(c.path, s.path)) { covered = true; break; }
    if (covered) continue;
    auto it = seen.find(c.path);
    if (it != seen.end()) {
      uniq[it->second].subtree |= c.subtree;
      if (c.subtree) subtrees.push_back(c);
      continue;
    }
    seen.emplace(c.path, uniq.size());
    uniq.push_back(c);
    if (c.subtree) subtrees.push_back(c);
  }

  std::unordered_map<std::string, size_t> jobAt;
  auto addJob = [&](const std::string& path, int32_t id, bool subtree) {
    auto it = jobAt.find(path);
    if (it != jobAt.end()) {
      plan.jobs[it->second].subtree |= subtree;
      return;
    }
    RefreshJob j;
    j.id = id;
    j.path = path;
    j.subtree = subtree;
    const DirNode& d = r.dirs[id];
    j.children.reserve(d.children.size());
    for (int32_t c : d.children) {
      const DirNode& cd = r.dirs[c];
      if (cd.path.empty()) continue;
      j.children.emplace_back(cd.path.substr(cd.path.find_last_of('/') + 1), c);
    }
    jobAt.emplace(path, plan.jobs.size());
    plan.jobs.push_back(std::move(j));
  };

  for (const auto& c : uniq) {
    if (c.path != root && !underDir(c.path, root)) continue;
    if (c.path == root && c.subtree) {
      plan.tooMuch = true;
      return plan;
    }
    int32_t id = findDir(r, c.path);
    if (id >= 0) {
      addJob(c.path, id, c.subtree);
      continue;
    }
    // Not indexed yet (created since, or inside something we couldn't read): re-list the nearest
    // indexed ancestor, which picks the new folder up as a new subtree.
    std::string p = c.path;
    while (p != root && p != "/") {
      p = dirName(p);
      if (p.empty()) break;
      int32_t a = findDir(r, p);
      if (a >= 0) {
        addJob(p, a, false);
        break;
      }
    }
  }
  size_t live = 0;
  for (const auto& d : r.dirs) live += !d.path.empty();
  if (plan.jobs.size() * 5 > live + 5000) plan.tooMuch = true;
  return plan;
}

RefreshPatch collectRefresh(const ScanOptions& opts, const RefreshPlan& plan,
                            const std::unordered_map<std::string, double>& md) {
  RefreshPatch patch;
  patch.idBase = plan.idBase;
  if (plan.tooMuch || plan.jobs.empty()) return patch;
  double now = wallNow();

  if (opts.spotlight) {
    std::vector<std::string> scopes;
    scopes.reserve(plan.jobs.size());
    for (const auto& j : plan.jobs) scopes.push_back(j.path);
    patch.spotlight = spotlightLastUsedIn(scopes);
    patch.dropSpotlightBelow = scopes;
  }

  Walker walker(opts, md, now, plan.idBase);
  walker.mdExtra = &patch.spotlight;
  walker.indexMdDirs(patch.spotlight);
  walker.allowDevicesOf(opts.root);
  std::vector<char> buf(256 * 1024);

  std::vector<WorkItem> roots;  // new subtrees, scanned together below
  for (const auto& j : plan.jobs) {
    RefreshPatch::Relist rl;
    rl.id = j.id;
    std::vector<WorkItem> subdirs;
    int dfd = open(j.path.c_str(), Walker::kOpenFlags);
    Walker::ListStatus ls = walker.listDir(dfd, j.path, j.id == 0, rl.own, subdirs, &patch.newBig, buf);
    if (dfd >= 0) close(dfd);
    if (ls == Walker::ListStatus::Missing) {
      rl.gone = j.id != 0;
      patch.dropBigBelow.push_back(j.path);
      patch.relists.push_back(std::move(rl));
      continue;
    }
    if (ls != Walker::ListStatus::Ok) {
      rl.unreadable = true;
      patch.errors++;
      patch.relists.push_back(std::move(rl));
      continue;
    }
    patch.dropBigUnder.push_back(j.path);
    std::unordered_map<std::string, int32_t> known(j.children.begin(), j.children.end());
    for (auto& s : subdirs) {
      auto it = known.find(s.name);
      if (it != known.end() && !j.subtree) {
        known.erase(it);
        continue;  // still there; its own events cover changes inside
      }
      if (it != known.end()) {
        rl.goneChildren.push_back(it->second);
        known.erase(it);
        patch.dropBigBelow.push_back(s.path);
      }
      s.id = walker.nextId.fetch_add(1);
      s.parent = j.id;
      rl.newChildren.push_back(s.id);
      roots.push_back(std::move(s));
    }
    for (const auto& kv : known) {
      rl.goneChildren.push_back(kv.second);
      patch.dropBigBelow.push_back(j.path == "/" ? "/" + kv.first : j.path + "/" + kv.first);
    }
    patch.relists.push_back(std::move(rl));
  }

  if (!roots.empty()) {
    for (auto& w : roots) walker.push(std::move(w));
    walker.run(std::min(opts.threads > 0 ? opts.threads : 8, 8));
    patch.newNodes = std::move(walker.nodes);
    patch.newBig.insert(patch.newBig.end(), walker.big.begin(), walker.big.end());
  }
  patch.errors += walker.errors.load();
  return patch;
}

bool applyRefresh(ScanResult& r, RefreshPatch&& patch) {
  if (patch.idBase != static_cast<int32_t>(r.dirs.size())) return false;
  if (patch.relists.empty()) return true;

  for (auto& rl : patch.relists) {
    if (rl.id < 0 || rl.id >= patch.idBase) continue;
    if (rl.gone) {
      markGone(r, rl.id);
      continue;
    }
    if (rl.unreadable) continue;
    for (int32_t g : rl.goneChildren) markGone(r, g);
    r.dirs[rl.id].own = rl.own;
  }
  if (!patch.newNodes.empty()) {
    r.dirs.reserve(r.dirs.size() + patch.newNodes.size());
    for (auto& n : patch.newNodes) r.dirs.push_back(std::move(n));
    for (auto& rl : patch.relists)
      if (!rl.gone && !rl.unreadable)
        for (int32_t c : rl.newChildren)
          if (c < static_cast<int32_t>(r.dirs.size()) && !r.dirs[c].path.empty()) r.dirs[rl.id].children.push_back(c);
  }

  if (!patch.dropBigUnder.empty() || !patch.dropBigBelow.empty()) {
    std::unordered_set<std::string> under(patch.dropBigUnder.begin(), patch.dropBigUnder.end());
    std::unordered_set<std::string> below(patch.dropBigBelow.begin(), patch.dropBigBelow.end());
    r.bigFiles.erase(std::remove_if(r.bigFiles.begin(), r.bigFiles.end(),
                                    [&](const FileRec& f) {
                                      return under.count(dirName(f.path)) || anyAncestorIn(f.path, below);
                                    }),
                     r.bigFiles.end());
  }
  if (!patch.newBig.empty()) {
    r.bigFiles.insert(r.bigFiles.end(), patch.newBig.begin(), patch.newBig.end());
    std::sort(r.bigFiles.begin(), r.bigFiles.end(),
              [](const FileRec& a, const FileRec& b) { return a.size > b.size; });
  }
  if (!patch.dropSpotlightBelow.empty()) {
    std::unordered_set<std::string> below(patch.dropSpotlightBelow.begin(), patch.dropSpotlightBelow.end());
    for (auto it = r.spotlight.begin(); it != r.spotlight.end();)
      it = anyAncestorIn(it->first, below) ? r.spotlight.erase(it) : std::next(it);
  }
  for (auto& kv : patch.spotlight) r.spotlight[kv.first] = kv.second;
  r.errors += patch.errors;
  rollup(r);
  return true;
}

void collectUnits(const ScanResult& r, int32_t id, std::vector<int32_t>& out,
                  const std::function<bool(const DirNode&)>& pred) {
  const DirNode& d = r.dirs[id];
  if (id != 0 && d.path.empty()) return;
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
