#include "finders.h"

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <CommonCrypto/CommonDigest.h>

#include <dirent.h>
#include <fcntl.h>
#include <fts.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <map>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <unordered_set>

namespace stale {
namespace {

bool cancelled(const FinderOptions& o) { return o.cancel && o.cancel->load(std::memory_order_relaxed); }

NSString* ns(const std::string& s) { return [NSString stringWithUTF8String:s.c_str()] ?: @""; }
std::string str(NSString* s) { return s ? std::string(s.UTF8String) : std::string(); }

bool hasSuffix(const std::string& s, const char* suf) {
  size_t n = strlen(suf);
  return s.size() >= n && s.compare(s.size() - n, n, suf) == 0;
}
bool hasPrefix(const std::string& s, const std::string& pre) { return s.compare(0, pre.size(), pre) == 0; }

std::string lower(std::string s) {
  for (char& c : s) c = (char)std::tolower((unsigned char)c);
  return s;
}

std::string lastComponent(const std::string& p) {
  size_t i = p.find_last_of('/');
  return i == std::string::npos ? p : p.substr(i + 1);
}

// Allocated size and newest modification time of a folder that isn't in the index.
uint64_t walkSize(const std::string& path, const FinderOptions& o, double* newest) {
  char* argv[] = {const_cast<char*>(path.c_str()), nullptr};
  FTS* f = fts_open(argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nullptr);
  if (!f) return 0;
  uint64_t bytes = 0;
  while (FTSENT* e = fts_read(f)) {
    if (cancelled(o)) break;
    if (e->fts_info == FTS_F || e->fts_info == FTS_SL || e->fts_info == FTS_DEFAULT) {
      bytes += (uint64_t)e->fts_statp->st_blocks * 512;
      double m = (double)e->fts_statp->st_mtimespec.tv_sec;
      if (newest && m > *newest) *newest = m;
    }
  }
  fts_close(f);
  return bytes;
}

// Size and last-used of any path, from the index when it has it.
void measure(const std::string& path, const FinderOptions& o, Found& out) {
  struct stat st;
  if (lstat(path.c_str(), &st) != 0) return;
  out.isDir = S_ISDIR(st.st_mode);
  double mtime = (double)st.st_mtimespec.tv_sec;
  if (out.isDir) {
    int32_t id = o.index ? findDir(*o.index, path) : -1;
    if (id >= 0) {
      const DirNode& d = o.index->dirs[(size_t)id];
      out.size = d.size;
      out.lastUsed = std::max(d.lastUsed, d.mdLastUsed);
    } else {
      double newest = mtime;
      out.size = walkSize(path, o, &newest);
      out.lastUsed = newest;
    }
  } else {
    out.size = (uint64_t)st.st_blocks * 512;
    out.lastUsed = mtime;
    if (o.index) {
      auto it = o.index->spotlight.find(path);
      if (it != o.index->spotlight.end()) out.lastUsed = std::max(out.lastUsed, it->second);
    }
  }
}

// denied is set when macOS refused the listing (TCC-protected folder without Full Disk Access).
std::vector<std::string> listDir(const std::string& path, bool hidden = false, bool* denied = nullptr) {
  std::vector<std::string> out;
  DIR* dp = opendir(path.c_str());
  if (!dp) {
    if (denied) *denied = errno == EPERM || errno == EACCES;
    return out;
  }
  while (dirent* e = readdir(dp)) {
    if (e->d_name[0] == '.' && (!hidden || !e->d_name[1] || (e->d_name[1] == '.' && !e->d_name[2]))) continue;
    out.emplace_back(e->d_name);
  }
  closedir(dp);
  std::sort(out.begin(), out.end());
  return out;
}

void finish(FinderResult& r) {
  r.total = r.suggested = 0;
  for (const Found& f : r.items) {
    r.total += f.size;
    if (f.preselect) r.suggested += f.size;
  }
}

// ───────────────────────────── installed applications ─────────────────────────────

struct Installed {
  std::unordered_set<std::string> names;  // lower-case, without ".app"
  std::unordered_set<std::string> ids;
  std::unordered_set<std::string> labels;   // lower-case launchd labels: background helpers without an .app
  std::unordered_set<std::string> vendors;  // lower-case "com.vendor" of every installed app
  std::unordered_map<std::string, bool> lsCache;
  std::mutex mu;

  explicit Installed(const std::string& home) {
    const std::string roots[] = {"/Applications", home + "/Applications", "/System/Applications"};
    for (const std::string& root : roots) addApps(root, 1);
    const std::string agents[] = {home + "/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"};
    for (const std::string& dir : agents)
      for (const std::string& n : listDir(dir))
        if (hasSuffix(n, ".plist")) labels.insert(lower(n.substr(0, n.size() - 6)));
    for (const std::string& id : ids) vendors.insert(vendorOf(lower(id)));
  }

  static std::string vendorOf(const std::string& id) {
    size_t a = id.find('.');
    size_t b = a == std::string::npos ? a : id.find('.', a + 1);
    return b == std::string::npos ? id : id.substr(0, b);
  }

  // Another product of the same vendor is installed (com.google.Keystone next to Chrome):
  // the data may be a shared helper's rather than a leftover.
  bool vendorInstalled(const std::string& id) const { return vendors.count(vendorOf(lower(id))) > 0; }

  void addApps(const std::string& dir, int depth) {
    for (const std::string& n : listDir(dir)) {
      std::string p = dir + "/" + n;
      if (hasSuffix(n, ".app")) {
        names.insert(lower(n.substr(0, n.size() - 4)));
        @autoreleasepool {
          NSBundle* b = [NSBundle bundleWithPath:ns(p)];
          if (b.bundleIdentifier) ids.insert(str(b.bundleIdentifier));
        }
      } else if (depth > 0) {
        struct stat st;
        if (lstat(p.c_str(), &st) == 0 && S_ISDIR(st.st_mode)) addApps(p, depth - 1);
      }
    }
  }

  // Is some application with this identifier (or a parent identifier — helpers are named
  // after their app) registered with Launch Services anywhere on the machine?
  bool hasBundleId(const std::string& id) {
    for (const std::string& a : ids)
      if (id == a || hasPrefix(id, a + ".")) return true;
    std::string l = lower(id);
    for (const std::string& a : labels)
      if (l == a || hasPrefix(a, l + ".") || hasPrefix(l, a + ".")) return true;
    std::string probe = id;
    for (;;) {
      if (lookup(probe)) return true;
      size_t dot = probe.find_last_of('.');
      if (dot == std::string::npos || std::count(probe.begin(), probe.end(), '.') <= 1) return false;
      probe.resize(dot);
    }
  }

  bool lookup(const std::string& id) {
    std::lock_guard<std::mutex> g(mu);
    auto it = lsCache.find(id);
    if (it != lsCache.end()) return it->second;
    bool found = false;
    @autoreleasepool {
      found = [NSWorkspace.sharedWorkspace URLsForApplicationsWithBundleIdentifier:ns(id)].count > 0;
    }
    lsCache[id] = found;
    return found;
  }

  // "Slack-4.29.149-arm64.dmg" -> is Slack installed?
  bool hasAppNamed(const std::string& fileStem) const {
    std::string s = lower(fileStem);
    for (char& c : s) if (c == '_' || c == '-' || c == '.' || c == '+') c = ' ';
    std::vector<std::string> words;
    size_t i = 0;
    while (i < s.size()) {
      while (i < s.size() && s[i] == ' ') ++i;
      size_t j = i;
      while (j < s.size() && s[j] != ' ') ++j;
      if (j > i) words.push_back(s.substr(i, j - i));
      i = j;
    }
    // Longest run of leading words that names an app; stop at version-like tokens.
    static const std::unordered_set<std::string> noise = {"mac", "macos", "osx", "arm64", "x64", "x86", "universal",
                                                          "intel", "apple", "silicon", "installer", "setup", "latest"};
    std::string joined, spaced;
    for (const std::string& w : words) {
      if (std::isdigit((unsigned char)w[0]) || (w[0] == 'v' && w.size() > 1 && std::isdigit((unsigned char)w[1]))) break;
      if (noise.count(w)) break;
      joined += w;
      spaced += (spaced.empty() ? "" : " ") + w;
      if (names.count(joined) || names.count(spaced)) return true;
    }
    return false;
  }
};

}  // namespace

// ───────────────────────────── duplicates ─────────────────────────────

namespace {

using Digest = std::array<uint8_t, CC_SHA256_DIGEST_LENGTH>;

struct DigestHash {
  size_t operator()(const Digest& d) const {
    size_t h;
    memcpy(&h, d.data(), sizeof h);
    return h;
  }
};

bool hashFile(const std::string& path, uint64_t limit, Digest& out, const FinderOptions& o) {
  int fd = open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) return false;
  if (limit > (1u << 20)) fcntl(fd, F_NOCACHE, 1);  // don't evict the user's files for a one-off read
  CC_SHA256_CTX ctx;
  CC_SHA256_Init(&ctx);
  static thread_local std::vector<uint8_t> buf(1u << 20);
  uint64_t left = limit;
  bool ok = true;
  while (left > 0) {
    if (cancelled(o)) { ok = false; break; }
    size_t want = (size_t)std::min<uint64_t>(left, buf.size());
    ssize_t n = read(fd, buf.data(), want);
    if (n < 0) { ok = false; break; }
    if (n == 0) break;
    CC_SHA256_Update(&ctx, buf.data(), (CC_LONG)n);
    left -= (uint64_t)n;
    if (o.progress) o.progress->fetch_add((uint64_t)n, std::memory_order_relaxed);
  }
  close(fd);
  CC_SHA256_Final(out.data(), &ctx);
  return ok;
}

// Content nobody should dedupe by hand: the OS, apps and their bundles, VCS objects,
// package caches (handled as "generated" instead) and per-app data in ~/Library.
bool duplicateEligible(const std::string& p, const std::string& home) {
  static const char* roots[] = {"/System/", "/Library/", "/private/", "/usr/", "/bin/", "/sbin/", "/opt/",
                                "/Applications/", "/cores/", "/Volumes/", "/dev/", "/Network/"};
  for (const char* r : roots) if (hasPrefix(p, r)) return false;
  if (hasPrefix(p, home + "/Library/") || hasPrefix(p, home + "/.Trash/")) return false;
  static const char* parts[] = {".app/", ".framework/", ".bundle/", ".xcodeproj/", ".photoslibrary/", ".musiclibrary/",
                                ".tvlibrary/", ".aplibrary/", ".git/", "/node_modules/", "/.Trash/", "/DerivedData/",
                                ".sparsebundle/", ".backupbundle/", "/.npm/", "/.cache/", "/.pnpm-store/"};
  for (const char* q : parts) if (p.find(q) != std::string::npos) return false;
  // Hidden folders (~/.rustup, ~/.nvm, .venv …) belong to tools, and tools keep copies on purpose.
  return p.find("/.") == std::string::npos;
}

}  // namespace

FinderResult findDuplicates(const FinderOptions& o, uint64_t minBytes) {
  FinderResult res;
  if (!o.index) return res;
  const ScanResult& r = *o.index;

  struct Cand {
    const FileRec* rec;
    uint64_t logical = 0;
    dev_t dev = 0;
    ino_t ino = 0;
  };

  // 1. same allocated size (free, from the index)
  std::unordered_map<uint64_t, std::vector<const FileRec*>> bySize;
  for (const FileRec& f : r.bigFiles)
    if (f.size >= minBytes && duplicateEligible(f.path, o.home)) bySize[f.size].push_back(&f);

  // 2. same logical size, distinct inodes (one stat per candidate)
  std::vector<std::vector<Cand>> groups;
  for (auto& kv : bySize) {
    if (kv.second.size() < 2) continue;
    if (cancelled(o)) return res;
    std::map<uint64_t, std::vector<Cand>> byLogical;
    std::unordered_set<uint64_t> seenInode;
    for (const FileRec* f : kv.second) {
      struct stat st;
      if (lstat(f->path.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) continue;
      uint64_t key = ((uint64_t)st.st_dev << 40) ^ (uint64_t)st.st_ino;
      if (!seenInode.insert(key).second) continue;  // hard link: same data, no space to win
      byLogical[(uint64_t)st.st_size].push_back({f, (uint64_t)st.st_size, st.st_dev, st.st_ino});
    }
    for (auto& g : byLogical)
      if (g.second.size() >= 2) groups.push_back(std::move(g.second));
  }
  if (groups.empty()) return res;

  if (o.progressTotal) {
    uint64_t total = 0;
    for (auto& g : groups) for (auto& c : g) total += std::min<uint64_t>(c.logical, 64 << 10) + c.logical;
    o.progressTotal->store(total);
  }

  // 3. hash: 64 KB prefix, then the whole file for what still matches
  std::mutex mu;
  std::vector<std::vector<Cand>> confirmed;
  std::atomic<size_t> next{0};
  auto worker = [&] {
    for (;;) {
      size_t gi = next.fetch_add(1);
      if (gi >= groups.size() || cancelled(o)) return;
      std::unordered_map<Digest, std::vector<Cand>, DigestHash> byPrefix;
      for (Cand& c : groups[gi]) {
        Digest d;
        if (hashFile(c.rec->path, 64 << 10, d, o)) byPrefix[d].push_back(c);
      }
      for (auto& pg : byPrefix) {
        if (pg.second.size() < 2) continue;
        std::unordered_map<Digest, std::vector<Cand>, DigestHash> byFull;
        for (Cand& c : pg.second) {
          Digest d;
          if (c.logical <= (64 << 10)) byFull[pg.first].push_back(c);  // prefix was the whole file
          else if (hashFile(c.rec->path, c.logical, d, o)) byFull[d].push_back(c);
        }
        for (auto& fg : byFull)
          if (fg.second.size() >= 2) {
            std::lock_guard<std::mutex> g(mu);
            confirmed.push_back(std::move(fg.second));
          }
      }
    }
  };
  unsigned n = std::min(4u, std::max(1u, std::thread::hardware_concurrency()));
  std::vector<std::thread> pool;
  for (unsigned i = 0; i < n; ++i) pool.emplace_back(worker);
  for (auto& t : pool) t.join();
  if (cancelled(o)) return res;

  // 4. biggest win first; inside a group keep the most recently used copy
  std::sort(confirmed.begin(), confirmed.end(), [](const std::vector<Cand>& a, const std::vector<Cand>& b) {
    uint64_t wa = a[0].logical * (a.size() - 1), wb = b[0].logical * (b.size() - 1);
    return wa != wb ? wa > wb : a[0].rec->path < b[0].rec->path;
  });
  int group = 0;
  for (auto& g : confirmed) {
    std::sort(g.begin(), g.end(), [](const Cand& a, const Cand& b) {
      if (a.rec->lastUsed != b.rec->lastUsed) return a.rec->lastUsed > b.rec->lastUsed;
      if (a.rec->path.size() != b.rec->path.size()) return a.rec->path.size() < b.rec->path.size();
      return a.rec->path < b.rec->path;
    });
    for (size_t i = 0; i < g.size(); ++i) {
      Found f;
      f.path = g[i].rec->path;
      f.size = g[i].rec->size;
      f.lastUsed = g[i].rec->lastUsed;
      f.group = group;
      f.preselect = i > 0;
      f.note = i == 0 ? (g.size() == 2 ? "Most recently used copy, kept" : "Most recently used of " + std::to_string(g.size()) + " copies, kept")
                      : "Same content as " + lastComponent(g[0].rec->path) + " in " + lastComponent(g[0].rec->path.substr(0, g[0].rec->path.find_last_of('/')));
      res.items.push_back(std::move(f));
    }
    ++group;
  }
  finish(res);
  return res;
}

// ───────────────────────────── leftovers ─────────────────────────────

namespace {

bool looksLikeBundleId(const std::string& id) {
  if (std::count(id.begin(), id.end(), '.') < 2 || id.size() < 7) return false;
  for (char c : id)
    if (!(std::isalnum((unsigned char)c) || c == '.' || c == '-' || c == '_')) return false;
  if (id.front() == '.' || id.back() == '.') return false;
  std::string l = lower(id);
  // Apple's own, including Shortcuts' Workflow-era identifiers.
  if (hasPrefix(l, "com.apple") || l.find(".apple.") != std::string::npos || l.find("is.workflow.") != std::string::npos)
    return false;
  return true;
}

bool uuidLike(const std::string& s) {
  if (s.size() != 36) return false;
  for (size_t i = 0; i < s.size(); ++i) {
    bool dash = i == 8 || i == 13 || i == 18 || i == 23;
    if (dash ? s[i] != '-' : !std::isxdigit((unsigned char)s[i])) return false;
  }
  return true;
}

// Folder / file name in a ~/Library location -> bundle identifier it belongs to, or "".
std::string bundleIdOf(const std::string& location, std::string name) {
  if (location == "Preferences") {
    if (!hasSuffix(name, ".plist")) return "";
    name.resize(name.size() - 6);
    size_t dot = name.find_last_of('.');
    if (dot != std::string::npos && uuidLike(name.substr(dot + 1))) name.resize(dot);  // ByHost
  } else if (location == "Saved Application State") {
    if (!hasSuffix(name, ".savedState")) return "";
    name.resize(name.size() - 11);
  } else if (location == "Group Containers" || location == "Application Scripts") {
    if (hasPrefix(name, "group.")) name = name.substr(6);
    else if (name.size() > 11 && name[10] == '.') {
      bool team = true;
      for (int i = 0; i < 10; ++i) team = team && std::isalnum((unsigned char)name[(size_t)i]) && !std::islower((unsigned char)name[(size_t)i]);
      if (team) name = name.substr(11);
    }
  }
  return looksLikeBundleId(name) ? name : "";
}

std::string fmtAgoDays(double t, double now) {
  if (t <= 0) return "never";
  double d = (now - t) / 86400.0;
  if (d < 1) return "today";
  if (d < 60) return std::to_string((int)d) + " days ago";
  if (d < 365) return std::to_string((int)std::lround(d / 30.44)) + " months ago";
  char buf[32];
  snprintf(buf, sizeof buf, "%.1f years ago", d / 365.25);
  return buf;
}

}  // namespace

FinderResult findLeftovers(const FinderOptions& o) {
  FinderResult res;
  Installed apps(o.home);
  const std::string lib = o.home + "/Library/";
  static const char* locations[] = {"Application Support", "Caches", "Containers", "Group Containers", "Preferences",
                                    "Saved Application State", "WebKit", "HTTPStorages", "Logs", "Application Scripts",
                                    "Cookies"};
  for (const char* loc : locations) {
    if (cancelled(o)) return res;
    std::string dir = lib + loc;
    for (const std::string& name : listDir(dir)) {
      std::string id = bundleIdOf(loc, name);
      if (id.empty() || apps.hasBundleId(id)) continue;
      Found f;
      f.path = dir + "/" + name;
      measure(f.path, o, f);
      if (f.size == 0 && !f.isDir) continue;
      if (o.now - f.lastUsed < 7 * 86400) continue;  // something still writes here: not a leftover
      f.preselect = !apps.vendorInstalled(id);
      f.note = "No app with identifier " + id + " is installed" +
               (f.preselect ? "" : "; other " + Installed::vendorOf(id) + " software is, check first");
      res.items.push_back(std::move(f));
    }
  }

  // Device backups
  std::string backups = lib + "Application Support/MobileSync/Backup";
  for (const std::string& udid : listDir(backups)) {
    if (cancelled(o)) return res;
    Found f;
    f.path = backups + "/" + udid;
    measure(f.path, o, f);
    if (!f.isDir || f.size == 0) continue;
    std::string device = "iOS device", when;
    double last = 0;
    @autoreleasepool {
      NSDictionary* info = [NSDictionary dictionaryWithContentsOfFile:ns(f.path + "/Info.plist")];
      NSString* dn = info[@"Device Name"], *pn = info[@"Product Name"];
      if (pn) device = str(pn);
      if (dn) device = str(dn) + (pn ? " (" + str(pn) + ")" : "");
      if (NSDate* d = info[@"Last Backup Date"]) last = d.timeIntervalSince1970;
    }
    if (last > 0) f.lastUsed = last;
    f.preselect = o.now - f.lastUsed > 365 * 86400;
    f.note = "Backup of " + device + ", last backed up " + fmtAgoDays(f.lastUsed, o.now);
    res.items.push_back(std::move(f));
  }

  std::sort(res.items.begin(), res.items.end(), [](const Found& a, const Found& b) { return a.size > b.size; });
  finish(res);
  return res;
}

// ───────────────────────────── old downloads ─────────────────────────────

FinderResult findOldDownloads(const FinderOptions& o, double olderThanDays) {
  FinderResult res;
  Installed apps(o.home);
  std::string dir = o.home + "/Downloads";
  static const std::unordered_set<std::string> installers = {"dmg", "pkg", "mpkg", "xip"};
  static const std::unordered_set<std::string> archives = {"zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "iso"};
  static const std::unordered_set<std::string> partial = {"download", "crdownload", "part", "tmp", "aria2"};
  for (const std::string& name : listDir(dir, false, &res.unreadable)) {
    if (cancelled(o)) return res;
    size_t dot = name.find_last_of('.');
    std::string ext = dot == std::string::npos ? "" : lower(name.substr(dot + 1));
    if (partial.count(ext)) continue;
    Found f;
    f.path = dir + "/" + name;
    measure(f.path, o, f);
    if (f.size == 0 || o.now - f.lastUsed < olderThanDays * 86400) continue;
    std::string stem = dot == std::string::npos ? name : name.substr(0, dot);
    if (hasSuffix(lower(stem), ".tar")) stem.resize(stem.size() - 4);
    std::string age = "last opened " + fmtAgoDays(f.lastUsed, o.now);
    if (installers.count(ext) || (archives.count(ext) && apps.hasAppNamed(stem))) {
      bool installed = apps.hasAppNamed(stem);
      f.preselect = installed;
      f.note = std::string(installers.count(ext) ? "Installer" : "Archive") + (installed ? ", its app is already installed" : ", " + age);
    } else if (archives.count(ext)) {
      f.note = "Archive, " + age;
    } else if (f.isDir) {
      f.note = "Folder, " + age;
    } else {
      f.note = "Download, " + age;
    }
    res.items.push_back(std::move(f));
  }
  std::sort(res.items.begin(), res.items.end(), [](const Found& a, const Found& b) {
    if (a.preselect != b.preselect) return a.preselect;
    return a.size > b.size;
  });
  finish(res);
  return res;
}

// ───────────────────────────── trash ─────────────────────────────

FinderResult findTrash(const FinderOptions& o) {
  FinderResult res;
  std::string dir = o.home + "/.Trash";
  for (const std::string& name : listDir(dir, true, &res.unreadable)) {
    if (cancelled(o)) return res;
    if (name == ".DS_Store") continue;
    Found f;
    f.path = dir + "/" + name;
    measure(f.path, o, f);
    f.note = f.isDir ? "Folder waiting in the Trash" : "File waiting in the Trash";
    res.items.push_back(std::move(f));
  }
  std::sort(res.items.begin(), res.items.end(), [](const Found& a, const Found& b) { return a.size > b.size; });
  finish(res);
  return res;
}

}  // namespace stale
