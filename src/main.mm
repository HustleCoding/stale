#import <Foundation/Foundation.h>

#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <set>
#include <string>
#include <vector>

#include "scan.h"

using namespace stale;

namespace {

bool gColor = isatty(1);
std::string gHome;

const char* C(const char* code) { return gColor ? code : ""; }
#define DIM C("\x1b[2m")
#define BOLD C("\x1b[1m")
#define RED C("\x1b[31m")
#define GREEN C("\x1b[32m")
#define YELLOW C("\x1b[33m")
#define BLUE C("\x1b[34m")
#define MAGENTA C("\x1b[35m")
#define CYAN C("\x1b[36m")
#define RESET C("\x1b[0m")

const char* bucketColor(Bucket b) {
  switch (b) {
    case HOT: return GREEN;
    case WARM: return CYAN;
    case COLD: return YELLOW;
    case STALE: return MAGENTA;
    default: return RED;
  }
}

std::string human(uint64_t bytes) {
  const char* units[] = {"B", "K", "M", "G", "T"};
  double v = static_cast<double>(bytes);
  int u = 0;
  while (v >= 1000 && u < 4) { v /= 1024; ++u; }
  char buf[32];
  if (u == 0) snprintf(buf, sizeof buf, "%5.0f%s", v, units[u]);
  else if (v < 10) snprintf(buf, sizeof buf, "%5.1f%s", v, units[u]);
  else snprintf(buf, sizeof buf, "%5.0f%s", v, units[u]);
  return buf;
}

std::string age(double lastUsed, double now) {
  if (lastUsed <= 0) return "never";
  double d = (now - lastUsed) / 86400.0;
  char buf[32];
  if (d < 1) return "today";
  if (d < 45) snprintf(buf, sizeof buf, "%.0fd", d);
  else if (d < 365) snprintf(buf, sizeof buf, "%.0fmo", d / 30.44);
  else snprintf(buf, sizeof buf, "%.1fy", d / 365.25);
  return buf;
}

std::string tilde(const std::string& p) {
  if (!gHome.empty() && p.compare(0, gHome.size(), gHome) == 0 &&
      (p.size() == gHome.size() || p[gHome.size()] == '/'))
    return "~" + p.substr(gHome.size());
  return p;
}

std::string expand(std::string p) {
  if (!p.empty() && p[0] == '~') p = gHome + p.substr(1);
  char buf[PATH_MAX];
  if (realpath(p.c_str(), buf)) p = buf;
  while (p.size() > 1 && p.back() == '/') p.pop_back();
  return p;
}

std::string bar(double frac, int width) {
  int n = static_cast<int>(std::lround(frac * width));
  std::string s;
  for (int i = 0; i < width; ++i) s += i < n ? "█" : "░";
  return s;
}

std::string jsonEscape(const std::string& s) {
  std::string o = "\"";
  for (unsigned char c : s) {
    switch (c) {
      case '"': o += "\\\""; break;
      case '\\': o += "\\\\"; break;
      case '\n': o += "\\n"; break;
      case '\t': o += "\\t"; break;
      default:
        if (c < 0x20) { char b[8]; snprintf(b, sizeof b, "\\u%04x", c); o += b; }
        else o += static_cast<char>(c);
    }
  }
  return o + "\"";
}

// 30d, 6mo, 1y, 180 — exits on anything else.
double parseDays(const std::string& s) {
  char* end = nullptr;
  double v = strtod(s.c_str(), &end);
  std::string unit = end ? end : "";
  if (end == s.c_str() || v < 0 || !(unit.empty() || unit == "d" || unit == "mo" || unit == "y")) {
    fprintf(stderr, "stale: invalid age '%s' (use e.g. 30d, 6mo, 1y)\n", s.c_str());
    exit(2);
  }
  if (unit == "mo") return v * 30.44;
  if (unit == "y") return v * 365.25;
  return v;
}

struct Args {
  std::string cmd = "report";
  std::string path;
  bool json = false, atime = false, spotlight = true, yes = false, dryRun = false, all = false;
  int top = 25;
  int threads = 0;
  double olderDays = 180;
  std::set<std::string> categories;
  std::vector<std::string> extra;
};

void usage() {
  fprintf(stderr,
          "stale — what you use, what you don't, and when you last touched it (macOS)\n\n"
          "usage:\n"
          "  stale [path]                 usage report for a directory (default: ~)\n"
          "  stale ls <path>              children of a directory by size, with last-used age\n"
          "  stale apps                   installed apps by last launch\n"
          "  stale trash [path] [opts]    move reclaimable, unused folders to the Trash\n\n"
          "options:\n"
          "  --top N          rows per section (default 25)\n"
          "  --json           machine-readable output\n"
          "  --atime          also treat file access time as usage\n"
          "  --no-spotlight   skip Spotlight last-opened metadata\n"
          "  --threads N      scanner threads (default: all cores)\n"
          "  --older AGE      trash: only folders unused for AGE (30d, 6mo, 1y; default 180d)\n"
          "  --category LIST  trash: node_modules,build,venv,cache,xcode,docker,trash (default all)\n"
          "  --all            trash: include non-reclaimable frozen folders too (careful)\n"
          "  --dry-run        trash: list only\n"
          "  -y, --yes        trash: no confirmation prompt\n");
}

Args parse(int argc, char** argv) {
  Args a;
  for (int i = 1; i < argc; ++i) {
    std::string s = argv[i];
    auto next = [&]() -> std::string { return i + 1 < argc ? argv[++i] : ""; };
    if (s == "--json") a.json = true;
    else if (s == "--atime") a.atime = true;
    else if (s == "--no-spotlight") a.spotlight = false;
    else if (s == "--dry-run") a.dryRun = true;
    else if (s == "--all") a.all = true;
    else if (s == "-y" || s == "--yes") a.yes = true;
    else if (s == "--top" || s == "-n") a.top = atoi(next().c_str());
    else if (s == "--threads") a.threads = atoi(next().c_str());
    else if (s == "--older") a.olderDays = parseDays(next());
    else if (s == "--category") {
      std::string v = next();
      size_t p = 0;
      while (p <= v.size()) {
        size_t q = v.find(',', p);
        if (q == std::string::npos) q = v.size();
        if (q > p) a.categories.insert(v.substr(p, q - p));
        p = q + 1;
      }
    } else if (s == "-h" || s == "--help") { usage(); exit(0); }
    else if (s == "--no-color") gColor = false;
    else if (!s.empty() && s[0] == '-') { fprintf(stderr, "unknown option %s\n", s.c_str()); usage(); exit(2); }
    else if (a.cmd == "report" && a.path.empty() && (s == "ls" || s == "apps" || s == "trash" || s == "report"))
      a.cmd = s;
    else if (a.path.empty()) a.path = s;
    else a.extra.push_back(s);
  }
  if (a.path.empty()) a.path = gHome;
  a.path = expand(a.path);
  return a;
}

ScanResult doScan(const Args& a, const std::string& root) {
  ScanOptions o;
  o.root = root;
  o.threads = a.threads;
  o.useAtime = a.atime;
  o.spotlight = a.spotlight;
  return scan(o);
}

// Top-most unit directories (not nested inside another unit) accepted by `pred`.
void collectUnits(const ScanResult& r, int32_t id, std::vector<int32_t>& out,
                  const std::function<bool(const DirNode&)>& pred) {
  const DirNode& d = r.dirs[id];
  if (id != 0 && d.unit) {
    if (pred(d)) out.push_back(id);
    return;
  }
  for (int32_t c : d.children) collectUnits(r, c, out, pred);
}

// Highest-level folders (not inside units) whose content is ≥90% stale/frozen.
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

void printRow(const std::string& sz, double lastUsed, double now, const std::string& label,
              const std::string& tag) {
  Bucket b = bucketFor(lastUsed <= 0 ? 0 : lastUsed, now);
  printf("  %s%s%s  %s%-6s%s  %s", BOLD, sz.c_str(), RESET, bucketColor(b), age(lastUsed, now).c_str(),
         RESET, label.c_str());
  if (!tag.empty()) printf("  %s%s%s", DIM, tag.c_str(), RESET);
  printf("\n");
}

int cmdReport(const Args& a) {
  ScanResult r = doScan(a, a.path);
  if (r.dirs.empty()) { fprintf(stderr, "cannot scan %s\n", a.path.c_str()); return 1; }
  const DirNode& root = r.dirs[0];

  std::vector<int32_t> reclaim;
  collectUnits(r, 0, reclaim, [](const DirNode& d) { return categoryReclaimable(d.category); });
  std::sort(reclaim.begin(), reclaim.end(),
            [&](int32_t x, int32_t y) { return r.dirs[x].size > r.dirs[y].size; });
  uint64_t reclaimTotal = 0, reclaimOld = 0;
  for (int32_t i : reclaim) {
    reclaimTotal += r.dirs[i].size;
    if (bucketFor(r.dirs[i].lastUsed, r.now) >= COLD) reclaimOld += r.dirs[i].size;
  }

  std::vector<int32_t> forgotten;
  collectForgotten(r, 0, forgotten, 50ull << 20);
  std::sort(forgotten.begin(), forgotten.end(),
            [&](int32_t x, int32_t y) { return r.dirs[x].size > r.dirs[y].size; });

  std::vector<const FileRec*> bigOld, neverOpened;
  for (const FileRec& f : r.bigFiles) {
    if (bucketFor(f.lastUsed, r.now) >= STALE) bigOld.push_back(&f);
    if (f.neverOpened) neverOpened.push_back(&f);
  }

  if (a.json) {
    printf("{\n  \"root\": %s,\n  \"files\": %llu,\n  \"bytes\": %llu,\n  \"errors\": %llu,\n"
           "  \"spotlight_hits\": %zu,\n  \"seconds\": %.2f,\n  \"buckets\": {",
           jsonEscape(a.path).c_str(), (unsigned long long)r.files, (unsigned long long)root.size,
           (unsigned long long)r.errors, r.spotlightHits, r.seconds);
    for (int b = 0; b < NBUCKETS; ++b)
      printf("%s\"%s\": %llu", b ? ", " : "", kBucketNames[b], (unsigned long long)root.bucketSize[b]);
    printf("},\n  \"never_opened_bytes\": %llu,\n  \"reclaimable_bytes\": %llu,\n  \"reclaimable\": [",
           (unsigned long long)root.neverOpenedSize, (unsigned long long)reclaimTotal);
    for (size_t i = 0; i < reclaim.size(); ++i) {
      const DirNode& d = r.dirs[reclaim[i]];
      printf("%s\n    {\"path\": %s, \"bytes\": %llu, \"last_used\": %.0f, \"category\": \"%s\"}",
             i ? "," : "", jsonEscape(d.path).c_str(), (unsigned long long)d.size, d.lastUsed,
             kCategoryNames[d.category]);
    }
    printf("\n  ],\n  \"forgotten\": [");
    for (size_t i = 0; i < forgotten.size(); ++i) {
      const DirNode& d = r.dirs[forgotten[i]];
      printf("%s\n    {\"path\": %s, \"bytes\": %llu, \"last_used\": %.0f}", i ? "," : "",
             jsonEscape(d.path).c_str(), (unsigned long long)d.size, d.lastUsed);
    }
    printf("\n  ],\n  \"big_unused_files\": [");
    for (size_t i = 0; i < bigOld.size(); ++i)
      printf("%s\n    {\"path\": %s, \"bytes\": %llu, \"last_used\": %.0f, \"never_opened\": %s}",
             i ? "," : "", jsonEscape(bigOld[i]->path).c_str(), (unsigned long long)bigOld[i]->size,
             bigOld[i]->lastUsed, bigOld[i]->neverOpened ? "true" : "false");
    printf("\n  ]\n}\n");
    return 0;
  }

  printf("\n%sstale%s  %s  %s%llu files, %s, %.1fs, %zu Spotlight last-opened records%s%s\n\n",
         BOLD, RESET, tilde(a.path).c_str(), DIM, (unsigned long long)r.files,
         human(root.size).c_str(), r.seconds, r.spotlightHits,
         r.errors ? (", " + std::to_string(r.errors) + " unreadable").c_str() : "", RESET);

  printf("%sWhen did you last use it?%s  %s(by size; last used = max(last opened, modified))%s\n",
         BOLD, RESET, DIM, RESET);
  const char* labels[NBUCKETS] = {"this week", "this month", "< 6 months", "6-12 months", "> 1 year"};
  for (int b = 0; b < NBUCKETS; ++b) {
    double frac = root.size ? static_cast<double>(root.bucketSize[b]) / root.size : 0;
    printf("  %s%-7s%s %-12s %s%s%s %s %3.0f%%\n", bucketColor(static_cast<Bucket>(b)), kBucketNames[b],
           RESET, labels[b], bucketColor(static_cast<Bucket>(b)), bar(frac, 30).c_str(), RESET,
           human(root.bucketSize[b]).c_str(), frac * 100);
  }
  printf("  %s%-7s%s %-12s %s %s(created, never opened or modified since)%s\n\n", DIM, "never", RESET,
         "", human(root.neverOpenedSize).c_str(), DIM, RESET);

  printf("%sReclaimable%s  %s(regenerable: node_modules, build output, caches, Xcode, Docker, Trash)%s\n",
         BOLD, RESET, DIM, RESET);
  printf("  total %s%s%s, of which %s%s%s untouched for 30+ days\n", BOLD, human(reclaimTotal).c_str(), RESET,
         BOLD, human(reclaimOld).c_str(), RESET);
  int shown = 0;
  for (int32_t i : reclaim) {
    if (shown++ >= a.top) break;
    const DirNode& d = r.dirs[i];
    printRow(human(d.size), d.lastUsed, r.now, tilde(d.path), kCategoryNames[d.category]);
  }
  if (reclaim.empty()) printf("  %snothing found%s\n", DIM, RESET);
  printf("  %s→ stale trash%s --older 30d%s\n\n", DIM, a.path == gHome ? "" : (" " + tilde(a.path)).c_str(), RESET);

  printf("%sForgotten folders%s  %s(≥90%% of content untouched for 6+ months, ≥50M)%s\n", BOLD, RESET, DIM, RESET);
  shown = 0;
  for (int32_t i : forgotten) {
    if (shown++ >= a.top) break;
    const DirNode& d = r.dirs[i];
    std::string tag = d.category ? kCategoryNames[d.category] : "";
    if (d.neverOpenedSize * 2 > d.size) tag += tag.empty() ? "mostly never opened" : ", mostly never opened";
    printRow(human(d.size), d.lastUsed, r.now, tilde(d.path), tag);
  }
  if (forgotten.empty()) printf("  %snothing found%s\n", DIM, RESET);
  printf("\n");

  printf("%sBig files you haven't touched in 6+ months%s  %s(≥100M)%s\n", BOLD, RESET, DIM, RESET);
  shown = 0;
  for (const FileRec* f : bigOld) {
    if (shown++ >= a.top) break;
    printRow(human(f->size), f->lastUsed, r.now, tilde(f->path), f->neverOpened ? "never opened" : "");
  }
  if (bigOld.empty()) printf("  %snothing found%s\n", DIM, RESET);
  printf("\n%sdrill down:%s stale ls <folder>     %sapps:%s stale apps\n\n", DIM, RESET, DIM, RESET);
  return 0;
}

struct Row {
  std::string name;
  uint64_t size;
  double lastUsed;
  bool dir;
  bool never;
  std::string tag;
  uint64_t files;
};

int cmdLs(const Args& a) {
  ScanResult r = doScan(a, a.path);
  if (r.dirs.empty()) { fprintf(stderr, "cannot scan %s\n", a.path.c_str()); return 1; }
  const DirNode& root = r.dirs[0];
  std::vector<Row> rows;
  for (int32_t c : root.children) {
    const DirNode& d = r.dirs[c];
    Row row{d.path.substr(d.path.find_last_of('/') + 1), d.size, d.lastUsed, true,
            d.neverOpenedSize * 2 > d.size && d.size > 0, d.category ? kCategoryNames[d.category] : "", d.files};
    rows.push_back(row);
  }
  auto md = a.spotlight ? spotlightLastUsed(a.path) : std::unordered_map<std::string, double>{};
  if (DIR* dp = opendir(a.path.c_str())) {
    struct stat st;
    while (struct dirent* de = readdir(dp)) {
      if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, "..")) continue;
      if (fstatat(dirfd(dp), de->d_name, &st, AT_SYMLINK_NOFOLLOW) != 0 || S_ISDIR(st.st_mode)) continue;
      std::string full = a.path + "/" + de->d_name;
      double mt = st.st_mtimespec.tv_sec, lu = mt;
      if (a.atime) lu = std::max(lu, (double)st.st_atimespec.tv_sec);
      auto it = md.find(full);
      bool hasMd = it != md.end();
      if (hasMd) lu = std::max(lu, it->second);
      double birth = st.st_birthtimespec.tv_sec;
      bool never = !hasMd && std::fabs(mt - birth) < 60 && (r.now - birth) > 30 * 86400.0;
      rows.push_back(Row{de->d_name, (uint64_t)st.st_blocks * 512, std::min(lu, r.now), false, never,
                         S_ISLNK(st.st_mode) ? "symlink" : "", 1});
    }
    closedir(dp);
  }
  std::sort(rows.begin(), rows.end(), [](const Row& x, const Row& y) { return x.size > y.size; });

  if (a.json) {
    printf("[");
    for (size_t i = 0; i < rows.size(); ++i)
      printf("%s\n  {\"name\": %s, \"dir\": %s, \"bytes\": %llu, \"files\": %llu, \"last_used\": %.0f, "
             "\"never_opened\": %s, \"category\": %s}",
             i ? "," : "", jsonEscape(rows[i].name).c_str(), rows[i].dir ? "true" : "false",
             (unsigned long long)rows[i].size, (unsigned long long)rows[i].files, rows[i].lastUsed,
             rows[i].never ? "true" : "false", jsonEscape(rows[i].tag).c_str());
    printf("\n]\n");
    return 0;
  }
  printf("\n%s%s%s  %s%s, %llu files, last used %s%s\n\n", BOLD, tilde(a.path).c_str(), RESET, DIM,
         human(root.size).c_str(), (unsigned long long)root.files, age(root.lastUsed, r.now).c_str(), RESET);
  int shown = 0;
  for (const Row& row : rows) {
    if (shown++ >= a.top) { printf("  %s… %zu more%s\n", DIM, rows.size() - a.top, RESET); break; }
    std::string tag = row.tag;
    if (row.never) tag += tag.empty() ? "never opened" : ", never opened";
    if (row.dir) {
      char b[32];
      snprintf(b, sizeof b, "%llu file%s", (unsigned long long)row.files, row.files == 1 ? "" : "s");
      tag = std::string(b) + (tag.empty() ? "" : ", " + tag);
    }
    printRow(human(row.size), row.lastUsed, r.now, row.dir ? BLUE + row.name + "/" + RESET : row.name, tag);
  }
  printf("\n");
  return 0;
}

int cmdApps(const Args& a) {
  std::vector<std::string> roots = {"/Applications", gHome + "/Applications"};
  struct App { std::string path; uint64_t size; double launched; double modified; };
  std::vector<App> apps;
  double now = 0;
  for (const std::string& root : roots) {
    struct stat st;
    if (::stat(root.c_str(), &st) != 0) continue;
    ScanResult r = doScan(a, root);
    now = r.now;
    std::vector<int32_t> ids;
    collectUnits(r, 0, ids, [](const DirNode& d) { return d.category == CAT_APP; });
    for (int32_t i : ids) {
      const DirNode& d = r.dirs[i];
      apps.push_back(App{d.path, d.size, d.mdLastUsed, d.lastUsed});
    }
  }
  // Never launched first (biggest first), then least recently launched.
  std::sort(apps.begin(), apps.end(), [](const App& x, const App& y) {
    if ((x.launched <= 0) != (y.launched <= 0)) return x.launched <= 0;
    if (x.launched <= 0) return x.size > y.size;
    return x.launched < y.launched;
  });
  if (a.json) {
    printf("[");
    for (size_t i = 0; i < apps.size(); ++i)
      printf("%s\n  {\"path\": %s, \"bytes\": %llu, \"last_launched\": %.0f, \"last_modified\": %.0f}",
             i ? "," : "", jsonEscape(apps[i].path).c_str(), (unsigned long long)apps[i].size,
             apps[i].launched, apps[i].modified);
    printf("\n]\n");
    return 0;
  }
  uint64_t total = 0, unused = 0;
  for (const App& x : apps) { total += x.size; if (x.launched <= 0 || bucketFor(x.launched, now) >= COLD) unused += x.size; }
  printf("\n%sApps%s  %s%zu apps, %s; %s never launched or not in 6+ months%s  %s(Spotlight last-opened; least used first)%s\n\n",
         BOLD, RESET, DIM, apps.size(), human(total).c_str(), human(unused).c_str(), RESET, DIM, RESET);
  int shown = 0;
  for (const App& x : apps) {
    if (shown++ >= a.top) { printf("  %s… %zu more (--top N)%s\n", DIM, apps.size() - a.top, RESET); break; }
    std::string when = age(x.modified, now);
    printRow(human(x.size), x.launched, now, tilde(x.path), "installed/updated " + (when == "today" ? when : when + " ago"));
  }
  printf("\n");
  return 0;
}

int cmdTrash(const Args& a) {
  ScanResult r = doScan(a, a.path);
  if (r.dirs.empty()) { fprintf(stderr, "cannot scan %s\n", a.path.c_str()); return 1; }
  std::vector<int32_t> picks;
  std::function<void(int32_t)> walk = [&](int32_t id) {
    const DirNode& d = r.dirs[id];
    bool old = d.lastUsed <= 0 || (r.now - d.lastUsed) / 86400.0 >= a.olderDays;
    bool match = false;
    if (id != 0 && d.unit && categoryReclaimable(d.category) && d.category != CAT_TRASH)
      match = a.categories.empty() || a.categories.count(kCategoryNames[d.category]);
    if (a.all && id != 0 && !d.unit && d.size >= (50ull << 20) &&
        (d.bucketSize[STALE] + d.bucketSize[FROZEN]) * 10 >= d.size * 9)
      match = true;
    if (match && old && d.size > 0) { picks.push_back(id); return; }
    if (d.unit && id != 0) return;
    for (int32_t c : d.children) walk(c);
  };
  walk(0);
  std::sort(picks.begin(), picks.end(), [&](int32_t x, int32_t y) { return r.dirs[x].size > r.dirs[y].size; });
  uint64_t total = 0;
  for (int32_t i : picks) total += r.dirs[i].size;

  if (picks.empty()) { printf("nothing to trash under %s (unused ≥ %.0f days)\n", tilde(a.path).c_str(), a.olderDays); return 0; }
  printf("\n%s%zu folders, %s%s  %sunused for %.0f+ days under %s%s\n\n", BOLD, picks.size(), human(total).c_str(),
         RESET, DIM, a.olderDays, tilde(a.path).c_str(), RESET);
  for (int32_t i : picks) {
    const DirNode& d = r.dirs[i];
    printRow(human(d.size), d.lastUsed, r.now, tilde(d.path), kCategoryNames[d.category]);
  }
  if (a.dryRun) { printf("\n%sdry run — nothing moved%s\n\n", DIM, RESET); return 0; }
  if (!a.yes) {
    printf("\nMove these %zu folders to the Trash? [y/N] ", picks.size());
    fflush(stdout);
    char buf[16] = {0};
    if (!fgets(buf, sizeof buf, stdin) || (buf[0] != 'y' && buf[0] != 'Y')) { printf("aborted\n"); return 1; }
  }
  uint64_t moved = 0;
  int failed = 0;
  @autoreleasepool {
    NSFileManager* fm = [NSFileManager defaultManager];
    for (int32_t i : picks) {
      const DirNode& d = r.dirs[i];
      NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:d.path.c_str()]];
      NSError* err = nil;
      if ([fm trashItemAtURL:url resultingItemURL:nil error:&err]) {
        moved += d.size;
        printf("  %strashed%s %s\n", GREEN, RESET, tilde(d.path).c_str());
      } else {
        ++failed;
        printf("  %sfailed%s  %s: %s\n", RED, RESET, tilde(d.path).c_str(), err.localizedDescription.UTF8String);
      }
    }
  }
  printf("\n%s moved to Trash%s — empty the Trash to free the space%s\n\n", human(moved).c_str(),
         failed ? (", " + std::to_string(failed) + " failed").c_str() : "", RESET);
  return failed ? 1 : 0;
}

}  // namespace

int main(int argc, char** argv) {
  const char* h = getenv("HOME");
  gHome = h ? h : "";
  if (getenv("NO_COLOR")) gColor = false;
  Args a = parse(argc, argv);
  struct stat st;
  if (a.cmd != "apps" && (stat(a.path.c_str(), &st) != 0 || !S_ISDIR(st.st_mode))) {
    fprintf(stderr, "stale: %s is not a directory\n", a.path.c_str());
    return 1;
  }
  if (a.cmd == "ls") return cmdLs(a);
  if (a.cmd == "apps") return cmdApps(a);
  if (a.cmd == "trash") return cmdTrash(a);
  return cmdReport(a);
}
