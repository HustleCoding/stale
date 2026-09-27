// Linux implementation of the cleanup finders (see finders.h). Same rules as the macOS
// version, with freedesktop locations: desktop entries and Flatpak instead of Launch
// Services, ~/.config instead of ~/Library/Application Support, the XDG Trash.
#include <fcntl.h>
#include <fts.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <cerrno>
#include <cmath>
#include <cstring>
#include <dirent.h>
#include <fstream>
#include <map>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <unordered_set>

#include "finders.h"
#include "trash.h"

extern char** environ;

namespace stale {
namespace {

bool cancelled(const FinderOptions& o) { return o.cancel && o.cancel->load(std::memory_order_relaxed); }

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

bool isDir(const std::string& p) {
  struct stat st;
  return stat(p.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

uint64_t walkSize(const std::string& path, const FinderOptions& o, double* newest) {
  char* argv[] = {const_cast<char*>(path.c_str()), nullptr};
  FTS* f = fts_open(argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nullptr);
  if (!f) return 0;
  uint64_t bytes = 0;
  while (FTSENT* e = fts_read(f)) {
    if (cancelled(o)) break;
    if (e->fts_info == FTS_F || e->fts_info == FTS_SL || e->fts_info == FTS_DEFAULT) {
      bytes += (uint64_t)e->fts_statp->st_blocks * 512;
      double m = statMtime(*e->fts_statp);
      if (newest && m > *newest) *newest = m;
    }
  }
  fts_close(f);
  return bytes;
}

void measure(const std::string& path, const FinderOptions& o, Found& out) {
  struct stat st;
  if (lstat(path.c_str(), &st) != 0) return;
  out.isDir = S_ISDIR(st.st_mode);
  double mtime = statMtime(st);
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

// ───────────────────────────── installed applications ─────────────────────────────

struct Installed {
  std::unordered_set<std::string> names;    // lower-case desktop entry names and file stems
  std::unordered_set<std::string> flatpaks;  // Flatpak application ids

  explicit Installed(const std::string& home) {
    const std::string dataDirs[] = {"/usr/share", "/usr/local/share", home + "/.local/share",
                                    "/var/lib/flatpak/exports/share", home + "/.local/share/flatpak/exports/share"};
    for (const std::string& d : dataDirs) {
      std::string apps = d + "/applications";
      for (const std::string& n : listDir(apps))
        if (hasSuffix(n, ".desktop")) addDesktop(apps + "/" + n, n.substr(0, n.size() - 8));
    }
    for (const std::string& root : {std::string("/var/lib/flatpak/app"), home + "/.local/share/flatpak/app"})
      for (const std::string& id : listDir(root)) flatpaks.insert(id);
  }

  void addDesktop(const std::string& file, const std::string& stem) {
    std::string s = lower(stem);
    names.insert(s);
    size_t dot = s.find_last_of('.');
    if (dot != std::string::npos) names.insert(s.substr(dot + 1));  // org.gnome.Nautilus -> nautilus
    std::ifstream f(file);
    std::string line;
    while (std::getline(f, line))
      if (hasPrefix(line, "Name=")) { names.insert(lower(line.substr(5))); break; }
  }

  bool hasFlatpak(const std::string& id) const { return flatpaks.count(id) > 0; }

  // "Obsidian-1.5.3.AppImage" -> is Obsidian installed?
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
    static const std::unordered_set<std::string> noise = {"linux", "amd64", "x86", "x64", "arm64", "aarch64",
                                                          "installer", "setup", "latest", "appimage", "deb", "rpm"};
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

bool onPath(const char* cmd) {
  const char* path = getenv("PATH");
  std::string p = path ? path : "/usr/local/bin:/usr/bin:/bin";
  size_t start = 0;
  while (start <= p.size()) {
    size_t end = p.find(':', start);
    if (end == std::string::npos) end = p.size();
    std::string dir = p.substr(start, end - start);
    if (!dir.empty() && access((dir + "/" + cmd).c_str(), X_OK) == 0) return true;
    start = end + 1;
  }
  return false;
}

// ───────────────────────────── SHA-256 ─────────────────────────────

struct Sha256 {
  uint32_t h[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
  uint8_t block[64];
  size_t used = 0;
  uint64_t bits = 0;

  static uint32_t rotr(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }

  void compress(const uint8_t* p) {
    static const uint32_t k[64] = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};
    uint32_t w[64];
    for (int i = 0; i < 16; ++i)
      w[i] = (uint32_t)p[i * 4] << 24 | (uint32_t)p[i * 4 + 1] << 16 | (uint32_t)p[i * 4 + 2] << 8 | p[i * 4 + 3];
    for (int i = 16; i < 64; ++i) {
      uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
    for (int i = 0; i < 64; ++i) {
      uint32_t t1 = hh + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + k[i] + w[i];
      uint32_t t2 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
      hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
  }

  void update(const uint8_t* p, size_t n) {
    bits += (uint64_t)n * 8;
    while (n > 0) {
      if (used == 0 && n >= 64) { compress(p); p += 64; n -= 64; continue; }
      size_t take = std::min(n, 64 - used);
      memcpy(block + used, p, take);
      used += take; p += take; n -= take;
      if (used == 64) { compress(block); used = 0; }
    }
  }

  void final(uint8_t out[32]) {
    uint64_t total = bits;
    uint8_t pad = 0x80;
    update(&pad, 1);
    uint8_t zero = 0;
    while (used != 56) update(&zero, 1);
    uint8_t len[8];
    for (int i = 0; i < 8; ++i) len[i] = (uint8_t)(total >> (56 - 8 * i));
    update(len, 8);
    for (int i = 0; i < 8; ++i) {
      out[i * 4] = (uint8_t)(h[i] >> 24); out[i * 4 + 1] = (uint8_t)(h[i] >> 16);
      out[i * 4 + 2] = (uint8_t)(h[i] >> 8); out[i * 4 + 3] = (uint8_t)h[i];
    }
  }
};

using Digest = std::array<uint8_t, 32>;

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
  Sha256 sha;
  static thread_local std::vector<uint8_t> buf(1u << 20);
  uint64_t left = limit, done = 0;
  bool ok = true;
  while (left > 0) {
    if (cancelled(o)) { ok = false; break; }
    size_t want = (size_t)std::min<uint64_t>(left, buf.size());
    ssize_t n = read(fd, buf.data(), want);
    if (n < 0) { ok = false; break; }
    if (n == 0) break;
    sha.update(buf.data(), (size_t)n);
    left -= (uint64_t)n;
    done += (uint64_t)n;
    if (o.progress) o.progress->fetch_add((uint64_t)n, std::memory_order_relaxed);
  }
  // Don't keep a one-off read of the user's files in the page cache.
  if (done > (1u << 20)) posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);
  close(fd);
  sha.final(out.data());
  return ok;
}

// Content nobody should dedupe by hand: the OS, packages, VCS objects, caches, tool folders.
bool duplicateEligible(const std::string& p, const std::string& home) {
  static const char* roots[] = {"/usr/", "/bin/", "/sbin/", "/lib/", "/lib64/", "/opt/", "/etc/", "/var/",
                                "/proc/", "/sys/", "/dev/", "/run/", "/boot/", "/snap/", "/nix/", "/tmp/"};
  for (const char* r : roots) if (hasPrefix(p, r)) return false;
  if (hasPrefix(p, home + "/Library/") || hasPrefix(p, trashFilesDir(home) + "/")) return false;
  static const char* parts[] = {".git/", "/node_modules/", "/.cache/", "/.npm/", "/.pnpm-store/", "/target/",
                                "/.local/share/Steam/", "/.var/app/", "/.local/share/flatpak/"};
  for (const char* q : parts) if (p.find(q) != std::string::npos) return false;
  return p.find("/.") == std::string::npos;
}

}  // namespace

// ───────────────────────────── duplicates ─────────────────────────────

FinderResult findDuplicates(const FinderOptions& o, uint64_t minBytes) {
  FinderResult res;
  if (!o.index) return res;
  const ScanResult& r = *o.index;

  struct Cand {
    const FileRec* rec;
    uint64_t logical = 0;
  };

  std::unordered_map<uint64_t, std::vector<const FileRec*>> bySize;
  for (const FileRec& f : r.bigFiles)
    if (f.size >= minBytes && duplicateEligible(f.path, o.home)) bySize[f.size].push_back(&f);

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
      byLogical[(uint64_t)st.st_size].push_back({f, (uint64_t)st.st_size});
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
          if (c.logical <= (64 << 10)) byFull[pg.first].push_back(c);
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

// Data Flatpak keeps per app in ~/.var/app/<id>, for apps that are no longer installed.
FinderResult findLeftovers(const FinderOptions& o) {
  FinderResult res;
  Installed apps(o.home);
  std::string dir = o.home + "/.var/app";
  for (const std::string& id : listDir(dir)) {
    if (cancelled(o)) return res;
    if (apps.hasFlatpak(id)) continue;
    Found f;
    f.path = dir + "/" + id;
    measure(f.path, o, f);
    if (!f.isDir || f.size == 0) continue;
    if (o.now - f.lastUsed < 7 * 86400) continue;  // something still writes here
    f.preselect = true;
    f.note = "Data of Flatpak app " + id + ", which is no longer installed";
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
  static const std::unordered_set<std::string> installers = {"appimage", "deb", "rpm", "flatpakref", "run",
                                                             "dmg", "pkg", "exe", "msi"};
  static const std::unordered_set<std::string> archives = {"zip", "tar", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar", "iso"};
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
    if (hasSuffix(lower(stem), ".pkg.tar")) stem.resize(stem.size() - 8);
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

// ───────────────────────────── AI agents ─────────────────────────────

namespace {

std::string gitBinary() {
  for (const char* c : {"/usr/bin/git", "/usr/local/bin/git", "/bin/git"})
    if (access(c, X_OK) == 0) return c;
  return "";
}

// Runs git -C dir args...; false when it could not run or exited non-zero.
bool runGit(const std::string& git, const std::string& dir, std::vector<std::string> args, std::string& out) {
  out.clear();
  args.insert(args.begin(), {git, "-C", dir});
  std::vector<char*> argv;
  for (std::string& a : args) argv.push_back(&a[0]);
  argv.push_back(nullptr);
  std::vector<std::string> env = {"GIT_OPTIONAL_LOCKS=0", "PATH=/usr/bin:/bin", "LC_ALL=C"};
  if (const char* h = getenv("HOME")) env.push_back(std::string("HOME=") + h);
  std::vector<char*> envp;
  for (std::string& e : env) envp.push_back(&e[0]);
  envp.push_back(nullptr);

  int fds[2];
  if (pipe2(fds, O_CLOEXEC) != 0) return false;
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_adddup2(&fa, fds[1], 1);
  posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
  posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
  pid_t pid;
  int rc = posix_spawn(&pid, git.c_str(), &fa, nullptr, argv.data(), envp.data());
  posix_spawn_file_actions_destroy(&fa);
  close(fds[1]);
  if (rc != 0) {
    close(fds[0]);
    return false;
  }
  char buf[4096];
  ssize_t n;
  while ((n = read(fds[0], buf, sizeof buf)) > 0 || (n < 0 && errno == EINTR))
    if (n > 0) out.append(buf, (size_t)n);
  close(fds[0]);
  int status = 0;
  while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
  return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

std::string worktreeKeepReason(const std::string& git, const std::string& dir) {
  if (git.empty()) return "Git isn't installed, so Stale can't check it for unsaved work";
  std::string out;
  if (!runGit(git, dir, {"status", "--porcelain"}, out)) return "Git can't read it; check it yourself";
  if (!out.empty()) return "Has uncommitted changes";
  if (!runGit(git, dir, {"for-each-ref", "--contains", "HEAD", "--count=1", "refs/heads", "refs/remotes"}, out))
    return "Git can't read it; check it yourself";
  if (out.empty()) return "Has commits that aren't on any branch";
  return "";
}

}  // namespace

FinderResult findAgentFiles(const FinderOptions& o) {
  FinderResult res;
  Installed apps(o.home);
  const std::string& h = o.home;
  const std::string config = h + "/.config/";
  const double day = 86400;
  const std::string git = gitBinary();
  std::unordered_set<std::string> seen;

  auto add = [&](const std::string& path, const std::string& what, bool preselect, double minAgeDays = 0) {
    if (cancelled(o) || seen.count(path)) return;
    Found f;
    f.path = path;
    measure(path, o, f);
    if (f.size < (1ull << 20)) return;
    if (minAgeDays > 0 && o.now - f.lastUsed < minAgeDays * day) return;
    seen.insert(path);
    f.preselect = preselect;
    f.note = what;
    res.items.push_back(std::move(f));
  };

  auto worktree = [&](const std::string& path, const std::string& tool) {
    if (cancelled(o) || seen.count(path)) return;
    Found f;
    f.path = path;
    measure(path, o, f);
    if (!f.isDir || f.size == 0) return;
    seen.insert(path);
    std::string age = "used " + fmtAgoDays(f.lastUsed, o.now);
    if (o.now - f.lastUsed < 14 * day) {
      f.note = tool + " worktree, " + age;
    } else {
      std::string keep = worktreeKeepReason(git, path);
      f.preselect = keep.empty();
      f.note = tool + " worktree, " + age + (keep.empty() ? ", no unsaved work" : ". " + keep);
    }
    res.items.push_back(std::move(f));
  };

  auto twoLevels = [&](const std::string& root, const std::string& tool) {
    for (const std::string& a : listDir(root))
      for (const std::string& b : listDir(root + "/" + a)) worktree(root + "/" + a + "/" + b, tool);
  };
  twoLevels(h + "/.codex/worktrees", "Codex");
  twoLevels(h + "/.cursor/worktrees", "Cursor");
  twoLevels(h + "/conductor/workspaces", "Conductor");
  if (o.index)
    for (const DirNode& d : o.index->dirs) {
      if (cancelled(o)) return res;
      if (hasSuffix(d.path, "/.claude/worktrees"))
        for (const std::string& n : listDir(d.path)) worktree(d.path + "/" + n, "Claude Code");
    }

  // Editors that are no longer installed: everything but their worktrees.
  struct App { const char* name; const char* bin; std::vector<std::string> paths; };
  const App gone[] = {
      {"Windsurf", "windsurf", {h + "/.codeium", h + "/.windsurf", config + "Windsurf"}},
      {"Cursor", "cursor", {h + "/.cursor/extensions", config + "Cursor"}},
  };
  for (const App& a : gone) {
    if (onPath(a.bin) || apps.hasAppNamed(a.name)) continue;
    for (const std::string& p : a.paths) add(p, std::string("Left by ") + a.name + ", which is no longer installed", true);
  }

  for (const char* n : {"debug", "paste-cache", "shell-snapshots"}) add(h + "/.claude/" + n, "Claude Code cache, rebuilt when needed", true);
  add(h + "/.codex/log", "Codex logs", true);
  for (const char* app : {"Cursor", "Windsurf", "Claude"})
    for (const char* n : {"Cache", "Code Cache", "CachedData", "GPUCache", "logs"})
      add(config + app + "/" + n, std::string(app) + " cache, rebuilt when needed", true);

  for (const char* dir : {"/.claude/projects", "/.claude/file-history"})
    for (const std::string& n : listDir(h + dir))
      add(h + dir + "/" + n, std::string("Claude Code ") + (hasSuffix(dir, "projects") ? "transcripts" : "edit history") +
                                 ", untouched for 30+ days", true, 30);
  for (const std::string& y : listDir(h + "/.codex/sessions"))
    for (const std::string& m : listDir(h + "/.codex/sessions/" + y))
      add(h + "/.codex/sessions/" + y + "/" + m, "Codex transcripts, untouched for 30+ days", true, 30);

  add(h + "/.ollama/models", "Ollama models, downloaded again when needed", false);
  add(h + "/.lmstudio/models", "LM Studio models, downloaded again when needed", false);
  add(h + "/.cache/lm-studio", "LM Studio models, downloaded again when needed", false);
  add(h + "/.cache/huggingface", "Hugging Face models and datasets", false);

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
  std::string dir = trashFilesDir(o.home);
  if (!isDir(dir)) return res;
  for (const std::string& name : listDir(dir, true, &res.unreadable)) {
    if (cancelled(o)) return res;
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
