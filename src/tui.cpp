#include "tui.h"

#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/ioctl.h>
#include <sys/statvfs.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <thread>
#include <unordered_map>

#include "finders.h"
#include "index.h"
#include "scan.h"
#include "status.h"
#include "trash.h"

extern char** environ;

namespace stale {
namespace {

// ───────────────────────────── terminal ─────────────────────────────

struct termios gSaved;
bool gRaw = false;
volatile sig_atomic_t gResized = 1;

void writeAll(const std::string& s) {
  size_t off = 0;
  while (off < s.size()) {
    ssize_t n = write(1, s.data() + off, s.size() - off);
    if (n <= 0) {
      if (n < 0 && errno == EINTR) continue;
      return;
    }
    off += (size_t)n;
  }
}

void restoreTerminal() {
  if (!gRaw) return;
  gRaw = false;
  const char seq[] = "\x1b[0m\x1b[?25h\x1b[?1049l";
  (void)!write(1, seq, sizeof seq - 1);
  tcsetattr(0, TCSAFLUSH, &gSaved);
}

void onFatalSignal(int sig) {
  restoreTerminal();
  signal(sig, SIG_DFL);
  raise(sig);
}

bool enterRaw() {
  if (tcgetattr(0, &gSaved) != 0) return false;
  struct termios t = gSaved;
  t.c_iflag &= ~(tcflag_t)(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
  t.c_lflag &= ~(tcflag_t)(ECHO | ICANON | IEXTEN | ISIG);
  t.c_cflag |= CS8;
  t.c_cc[VMIN] = 0;
  t.c_cc[VTIME] = 0;
  if (tcsetattr(0, TCSAFLUSH, &t) != 0) return false;
  gRaw = true;
  atexit(restoreTerminal);
  for (int s : {SIGTERM, SIGHUP, SIGINT, SIGQUIT}) signal(s, onFatalSignal);
  signal(SIGWINCH, [](int) { gResized = 1; });
  writeAll("\x1b[?1049h\x1b[?25l\x1b[H\x1b[2J");
  return true;
}

void termSize(int& w, int& h) {
  struct winsize ws;
  if (ioctl(1, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0) {
    w = ws.ws_col;
    h = ws.ws_row;
  } else {
    w = 80;
    h = 24;
  }
}

enum Key {
  K_NONE = 0, K_UP = 1000, K_DOWN, K_LEFT, K_RIGHT, K_PGUP, K_PGDN, K_HOME, K_END, K_ENTER, K_ESC, K_TAB,
  K_BTAB, K_BACKSPACE
};

// Waits up to timeoutMs for one key.
int readKey(int timeoutMs) {
  struct pollfd p = {0, POLLIN, 0};
  if (poll(&p, 1, timeoutMs) <= 0) return K_NONE;
  unsigned char c;
  if (read(0, &c, 1) != 1) return K_NONE;
  if (c == '\r' || c == '\n') return K_ENTER;
  if (c == '\t') return K_TAB;
  if (c == 127 || c == 8) return K_BACKSPACE;
  if (c == 3) return 'q';
  if (c != 27) return c;
  unsigned char seq[4] = {0};
  if (poll(&p, 1, 30) <= 0 || read(0, &seq[0], 1) != 1) return K_ESC;
  if (seq[0] != '[' && seq[0] != 'O') return K_ESC;
  if (read(0, &seq[1], 1) != 1) return K_ESC;
  if (seq[1] >= '0' && seq[1] <= '9') {
    if (read(0, &seq[2], 1) != 1) return K_ESC;
    if (seq[2] != '~') return K_NONE;
    switch (seq[1]) {
      case '1': case '7': return K_HOME;
      case '4': case '8': return K_END;
      case '5': return K_PGUP;
      case '6': return K_PGDN;
    }
    return K_NONE;
  }
  switch (seq[1]) {
    case 'A': return K_UP;
    case 'B': return K_DOWN;
    case 'C': return K_RIGHT;
    case 'D': return K_LEFT;
    case 'H': return K_HOME;
    case 'F': return K_END;
    case 'Z': return K_BTAB;
  }
  return K_NONE;
}

// ───────────────────────────── drawing ─────────────────────────────

const char* const FG_DIM = "\x1b[2m";
const char* const FG_BOLD = "\x1b[1m";
const char* const FG_ACCENT = "\x1b[34m";
const char* const FG_GREEN = "\x1b[32m";
const char* const FG_YELLOW = "\x1b[33m";
const char* const FG_RED = "\x1b[31m";
const char* const FG_MAGENTA = "\x1b[35m";
const char* const FG_CYAN = "\x1b[36m";

const char* bucketColor(Bucket b) {
  switch (b) {
    case HOT: return FG_GREEN;
    case WARM: return FG_CYAN;
    case COLD: return FG_YELLOW;
    case STALE: return FG_MAGENTA;
    default: return FG_RED;
  }
}

// One screen line built from styled segments, clipped to the terminal width.
struct Line {
  std::string out;
  int width = 0, max;
  bool reverse;
  Line(int w, bool rev = false) : max(w), reverse(rev) {
    if (reverse) out = "\x1b[7m";
  }
  void add(const std::string& text, const char* style = "") {
    if (width >= max) return;
    out += style;
    size_t i = 0;
    while (i < text.size() && width < max) {
      unsigned char c = (unsigned char)text[i];
      size_t n = c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4;
      unsigned char safe = c < 0x20 || c == 0x7f ? '?' : c;
      if (n == 1) out += (char)safe;
      else out.append(text, i, n);
      i += n;
      ++width;
    }
    if (*style) out += "\x1b[22;39m";
  }
  void pad(int to) {
    while (width < to && width < max) { out += ' '; ++width; }
  }
  std::string done() {
    pad(max);
    return out + "\x1b[0m";
  }
};

int textWidth(const std::string& s) {
  int w = 0;
  for (unsigned char c : s) if ((c & 0xC0) != 0x80) ++w;
  return w;
}

std::string padLeft(const std::string& s, int w) {
  int n = textWidth(s);
  return n >= w ? s : std::string((size_t)(w - n), ' ') + s;
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

std::string meter(double frac, int width) {
  frac = std::max(0.0, std::min(1.0, frac));
  int n = (int)std::lround(frac * width);
  std::string s;
  for (int i = 0; i < width; ++i) s += i < n ? "█" : "░";
  return s;
}

std::string baseName(const std::string& p) {
  size_t i = p.find_last_of('/');
  return i == std::string::npos || i + 1 == p.size() ? p : p.substr(i + 1);
}

std::string parentOf(const std::string& p) {
  size_t i = p.find_last_of('/');
  return i == std::string::npos || i == 0 ? "/" : p.substr(0, i);
}

std::vector<pid_t> gSpawned;

void reapSpawned() {
  gSpawned.erase(std::remove_if(gSpawned.begin(), gSpawned.end(),
                                [](pid_t p) { return waitpid(p, nullptr, WNOHANG) != 0; }),
                 gSpawned.end());
}

// Starts a program without waiting for it and without letting it write over the screen.
void spawnDetached(const std::vector<std::string>& args) {
  std::vector<char*> argv;
  std::vector<std::string> copy = args;
  for (std::string& a : copy) argv.push_back(&a[0]);
  argv.push_back(nullptr);
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  for (int fd = 0; fd < 3; ++fd) posix_spawn_file_actions_addopen(&fa, fd, "/dev/null", fd ? O_WRONLY : O_RDONLY, 0);
  posix_spawnattr_t at;
  posix_spawnattr_init(&at);
  posix_spawnattr_setflags(&at, POSIX_SPAWN_SETSID);
  pid_t pid;
  if (posix_spawnp(&pid, argv[0], &fa, &at, argv.data(), environ) == 0) gSpawned.push_back(pid);
  posix_spawnattr_destroy(&at);
  posix_spawn_file_actions_destroy(&fa);
}

// ───────────────────────────── model ─────────────────────────────

enum View { V_OVERVIEW = 0, V_BROWSE, V_RECLAIM, V_FORGOTTEN, V_BIG, V_CLEANUP, NVIEWS };
const char* const kViewNames[NVIEWS] = {"Overview", "Browse", "Reclaimable", "Forgotten", "Big files", "Cleanup"};

struct Row {
  std::string path, label, note;
  uint64_t size = 0;
  double lastUsed = 0;
  bool isDir = false, marked = false, keep = false;
  int32_t dir = -1;
  int group = -1;
};

struct ListState {
  std::vector<Row> rows;
  int cursor = 0, scroll = 0;
};

enum FinderKind { F_DUPLICATES = 0, F_AGENTS, F_DOWNLOADS, F_LEFTOVERS, F_TRASH, NFINDERS };
struct FinderInfo { const char* name; const char* what; };
const FinderInfo kFinders[NFINDERS] = {
    {"Duplicates", "Identical files (SHA-256); keeps the most recently used copy"},
    {"AI agents", "Old Claude Code / Codex / Cursor worktrees, logs, caches, local models"},
    {"Old downloads", "Downloads untouched for 30+ days, installers whose app is installed"},
    {"Leftovers", "Data of Flatpak apps that are no longer installed"},
    {"Trash", "What is already in the Trash (deleted permanently)"},
};

struct Tui {
  TuiOptions opt;
  int W = 80, H = 24;
  View view = V_OVERVIEW;
  std::shared_ptr<ScanResult> idx;
  std::string cachedNote;

  // background scan
  std::thread scanThread;
  std::atomic<bool> scanning{false}, scanCancel{false};
  std::atomic<uint64_t> scanFiles{0};
  std::mutex mu;
  std::shared_ptr<ScanResult> scanned;
  std::chrono::steady_clock::time_point scanStart;

  // background finder
  std::thread finderThread;
  std::atomic<bool> finding{false}, finderCancel{false};
  std::atomic<uint64_t> finderDone{0}, finderTotal{0};
  std::unique_ptr<FinderResult> found;
  int finder = -1, finderCursor = 0;  // finder shown (-1 = menu)
  bool finderReady = false;

  ListState lists[NVIEWS];
  int32_t browseDir = 0;
  bool sortByAge = false;

  // modal
  enum { M_NONE, M_CONFIRM, M_HELP, M_MESSAGE } modal = M_NONE;
  std::string modalText;
  std::vector<std::string> pendingPaths;
  bool pendingPermanent = false;
  std::string flash;

  ~Tui() {
    scanCancel = true;
    finderCancel = true;
    if (scanThread.joinable()) scanThread.join();
    if (finderThread.joinable()) finderThread.join();
  }

  std::string tilde(const std::string& p) const {
    const std::string& h = opt.home;
    if (!h.empty() && p.compare(0, h.size(), h) == 0 && (p.size() == h.size() || p[h.size()] == '/'))
      return "~" + p.substr(h.size());
    return p;
  }

  // ── scanning ──
  void startScan() {
    if (scanning) return;
    if (scanThread.joinable()) scanThread.join();
    scanning = true;
    scanCancel = false;
    scanFiles = 0;
    scanStart = std::chrono::steady_clock::now();
    scanThread = std::thread([this] {
      ScanOptions so;
      so.root = opt.root;
      so.threads = opt.threads;
      so.useAtime = opt.atime;
      so.spotlight = opt.spotlight;
      so.progressFiles = &scanFiles;
      so.cancel = &scanCancel;
      auto r = std::make_shared<ScanResult>(scan(so));
      if (!scanCancel && !r->dirs.empty()) {
        if (opt.root == opt.home) writeSummary(summarize(*r));
#ifndef __APPLE__
        saveIndex(indexPath(opt.root), opt.root, *r, IndexMeta{r->now, 0, {}});
#endif
        std::lock_guard<std::mutex> g(mu);
        scanned = r;
      }
      scanning = false;
    });
  }

  bool adoptScan() {
    std::shared_ptr<ScanResult> r;
    {
      std::lock_guard<std::mutex> g(mu);
      r.swap(scanned);
    }
    if (!r) return false;
    std::string here = idx && browseDir >= 0 && (size_t)browseDir < idx->dirs.size() ? idx->dirs[browseDir].path : "";
    idx = r;
    cachedNote.clear();
    browseDir = here.empty() ? 0 : std::max(0, findDir(*idx, here));
    rebuild();
    return true;
  }

  // Copy-on-write: a finder thread may still be reading the current index.
  ScanResult& mutableIndex() {
    if (idx.use_count() > 1) idx = std::make_shared<ScanResult>(*idx);
    return *idx;
  }

  // ── lists ──
  void sortRows(std::vector<Row>& rows) {
    if (sortByAge)
      std::stable_sort(rows.begin(), rows.end(), [](const Row& a, const Row& b) { return a.lastUsed < b.lastUsed; });
    else
      std::stable_sort(rows.begin(), rows.end(), [](const Row& a, const Row& b) { return a.size > b.size; });
  }

  Row dirRow(int32_t id, const std::string& label) const {
    const DirNode& d = idx->dirs[(size_t)id];
    Row r;
    r.path = d.path;
    r.label = label;
    r.size = d.size;
    r.lastUsed = std::max(d.lastUsed, d.mdLastUsed);
    r.isDir = true;
    r.dir = id;
    if (d.category != CAT_NONE) r.note = kCategoryNames[d.category];
    return r;
  }

  void setRows(View v, std::vector<Row> rows) {
    ListState& l = lists[v];
    std::string at = l.cursor < (int)l.rows.size() ? l.rows[(size_t)l.cursor].path : "";
    l.rows = std::move(rows);
    l.cursor = 0;
    for (size_t i = 0; i < l.rows.size() && !at.empty(); ++i)
      if (l.rows[i].path == at) l.cursor = (int)i;
    l.scroll = std::min(l.scroll, l.cursor);
  }

  void buildBrowse(const std::string& focus = "") {
    if (!idx || idx->dirs.empty()) return;
    if (browseDir < 0 || (size_t)browseDir >= idx->dirs.size() || (browseDir != 0 && idx->dirs[browseDir].path.empty()))
      browseDir = 0;
    const DirNode& d = idx->dirs[(size_t)browseDir];
    std::vector<Row> rows;
    uint64_t listed = 0;
    for (int32_t c : d.children) {
      const DirNode& cd = idx->dirs[(size_t)c];
      if (cd.path.empty()) continue;
      rows.push_back(dirRow(c, baseName(cd.path) + "/"));
      listed += cd.size;
    }
    for (const FileRec& f : idx->bigFiles) {
      if (parentOf(f.path) != d.path) continue;
      Row r;
      r.path = f.path;
      r.label = baseName(f.path);
      r.size = f.size;
      r.lastUsed = f.lastUsed;
      if (f.neverOpened) r.note = "never opened";
      rows.push_back(r);
      listed += f.size;
    }
    uint64_t rest = d.size > listed ? d.size - listed : 0;
    sortRows(rows);
    if (rest > 0) {
      Row r;
      r.label = "(other files)";
      r.size = rest;
      r.lastUsed = d.own.lastUsed;
      rows.push_back(r);
    }
    setRows(V_BROWSE, std::move(rows));
    if (!focus.empty()) {
      ListState& l = lists[V_BROWSE];
      for (size_t i = 0; i < l.rows.size(); ++i)
        if (l.rows[i].path == focus) l.cursor = (int)i;
    }
  }

  void rebuild() {
    if (!idx || idx->dirs.empty()) return;
    const ScanResult& r = *idx;
    buildBrowse();

    std::vector<int32_t> ids;
    collectUnits(r, 0, ids, [](const DirNode& d) { return categoryReclaimable(d.category); });
    std::vector<Row> rows;
    for (int32_t id : ids) {
      Row row = dirRow(id, tilde(r.dirs[(size_t)id].path));
      row.marked = bucketFor(row.lastUsed, r.now) >= COLD;
      rows.push_back(row);
    }
    sortRows(rows);
    keepMarks(V_RECLAIM, rows);
    setRows(V_RECLAIM, std::move(rows));

    ids.clear();
    collectForgotten(r, 0, ids, 50ull << 20);
    rows.clear();
    for (int32_t id : ids) rows.push_back(dirRow(id, tilde(r.dirs[(size_t)id].path)));
    sortRows(rows);
    keepMarks(V_FORGOTTEN, rows);
    setRows(V_FORGOTTEN, std::move(rows));

    rows.clear();
    for (const FileRec& f : r.bigFiles) {
      if (f.size < kBigFileReport) continue;
      Row row;
      row.path = f.path;
      row.label = tilde(f.path);
      row.size = f.size;
      row.lastUsed = f.lastUsed;
      if (f.neverOpened) row.note = "never opened";
      rows.push_back(row);
    }
    sortRows(rows);
    keepMarks(V_BIG, rows);
    setRows(V_BIG, std::move(rows));
  }

  void keepMarks(View v, std::vector<Row>& rows) {
    if (lists[v].rows.empty()) return;
    std::unordered_map<std::string, bool> prev;
    for (const Row& r : lists[v].rows) prev[r.path] = r.marked;
    for (Row& r : rows) {
      auto it = prev.find(r.path);
      if (it != prev.end()) r.marked = it->second;
    }
  }

  // ── finders ──
  void startFinder(int kind) {
    if (!idx || finding) return;
    if (finderThread.joinable()) finderThread.join();
    finder = kind;
    finderReady = false;
    finding = true;
    finderCancel = false;
    finderDone = finderTotal = 0;
    std::shared_ptr<ScanResult> index = idx;
    finderThread = std::thread([this, kind, index] {
      FinderOptions fo;
      fo.index = index.get();
      fo.home = opt.home;
      fo.now = (double)time(nullptr);
      fo.cancel = &finderCancel;
      fo.progress = &finderDone;
      fo.progressTotal = &finderTotal;
      FinderResult res;
      switch (kind) {
        case F_DUPLICATES: res = findDuplicates(fo); break;
        case F_AGENTS: res = findAgentFiles(fo); break;
        case F_DOWNLOADS: res = findOldDownloads(fo); break;
        case F_LEFTOVERS: res = findLeftovers(fo); break;
        default: res = findTrash(fo); break;
      }
      std::lock_guard<std::mutex> g(mu);
      found = std::make_unique<FinderResult>(std::move(res));
      finding = false;
    });
  }

  void adoptFinder() {
    std::unique_ptr<FinderResult> res;
    {
      std::lock_guard<std::mutex> g(mu);
      res.swap(found);
    }
    if (!res) return;
    std::vector<Row> rows;
    for (const Found& f : res->items) {
      Row r;
      r.path = f.path;
      r.label = tilde(f.path);
      r.size = f.size;
      r.lastUsed = f.lastUsed;
      r.isDir = f.isDir;
      r.marked = f.preselect;
      r.keep = f.group >= 0 && !f.preselect;
      r.note = f.note;
      r.group = f.group;
      rows.push_back(r);
    }
    lists[V_CLEANUP] = ListState();
    lists[V_CLEANUP].rows = std::move(rows);
    finderReady = true;
    if (res->unreadable)
      flash = "Some folders couldn't be read; grant this terminal access or run as their owner";
  }

  // ── actions ──
  ListState* activeList() {
    if (view == V_OVERVIEW) return nullptr;
    if (view == V_CLEANUP && (finder < 0 || !finderReady)) return nullptr;
    return &lists[view];
  }

  void askRemove() {
    ListState* l = activeList();
    if (!l || l->rows.empty()) return;
    pendingPaths.clear();
    uint64_t bytes = 0;
    for (const Row& r : l->rows)
      if (r.marked && !r.path.empty()) { pendingPaths.push_back(r.path); bytes += r.size; }
    if (pendingPaths.empty()) {
      const Row& r = l->rows[(size_t)l->cursor];
      if (r.path.empty()) return;
      pendingPaths.push_back(r.path);
      bytes = r.size;
    }
    pendingPermanent = view == V_CLEANUP && finder == F_TRASH;
    char buf[160];
    snprintf(buf, sizeof buf, "%s %zu item%s (%s)?", pendingPermanent ? "Permanently delete" : "Move to Trash",
             pendingPaths.size(), pendingPaths.size() == 1 ? "" : "s", humanBytes(bytes).c_str());
    modalText = buf;
    modal = M_CONFIRM;
  }

  void doRemove() {
    size_t ok = 0;
    uint64_t bytes = 0;
    std::string firstErr;
    std::vector<RefreshRequest> refresh;
    std::unordered_map<std::string, uint64_t> sizes;
    for (const ListState& l : lists)
      for (const Row& r : l.rows) sizes[r.path] = r.size;
    for (const std::string& p : pendingPaths) {
      std::string err;
      bool done = pendingPermanent ? deleteFromTrash(p, &err) : moveToTrash(p, &err);
      if (!done) {
        if (firstErr.empty()) firstErr = tilde(p) + ": " + err;
        continue;
      }
      ++ok;
      bytes += sizes[p];
      refresh.push_back({parentOf(p), false});
    }
    for (ListState& l : lists)
      l.rows.erase(std::remove_if(l.rows.begin(), l.rows.end(),
                                  [&](const Row& r) {
                                    return std::find(pendingPaths.begin(), pendingPaths.end(), r.path) != pendingPaths.end();
                                  }),
                   l.rows.end());
    for (ListState& l : lists) l.cursor = std::max(0, std::min(l.cursor, (int)l.rows.size() - 1));
    if (idx && !refresh.empty()) {
      ScanResult& r = mutableIndex();
      ScanOptions so;
      so.root = opt.root;
      so.useAtime = opt.atime;
      so.spotlight = opt.spotlight;
      RefreshPlan plan = planRefresh(r, refresh);
      if (!plan.tooMuch) {
        RefreshPatch patch = collectRefresh(so, plan, r.spotlight);
        applyRefresh(r, std::move(patch));
      }
      rebuild();
    }
    char buf[256];
    snprintf(buf, sizeof buf, "%s %zu item%s, %s freed%s%s", pendingPermanent ? "Deleted" : "Trashed", ok,
             ok == 1 ? "" : "s", humanBytes(bytes).c_str(), firstErr.empty() ? "" : ". Failed: ", firstErr.c_str());
    flash = buf;
    pendingPaths.clear();
  }

  void openCurrent() {
    ListState* l = activeList();
    std::string path;
    if (l && !l->rows.empty()) path = l->rows[(size_t)l->cursor].path;
    if (path.empty() && view == V_BROWSE && idx) path = idx->dirs[(size_t)browseDir].path;
    if (path.empty()) return;
    const Row& r = l->rows[(size_t)l->cursor];
    std::string target = r.isDir || r.path.empty() ? path : parentOf(path);
#ifdef __APPLE__
    spawnDetached({"open", target});
#else
    spawnDetached({"xdg-open", target});
#endif
    flash = "Opened " + tilde(target);
  }

  void enter() {
    if (view == V_CLEANUP && finder < 0) { startFinder(finderCursor); return; }
    ListState* l = activeList();
    if (!l || l->rows.empty()) return;
    const Row& r = l->rows[(size_t)l->cursor];
    if (r.dir < 0) return;
    browseDir = r.dir;
    view = V_BROWSE;
    lists[V_BROWSE].cursor = lists[V_BROWSE].scroll = 0;
    buildBrowse();
  }

  bool back() {
    if (view == V_BROWSE && idx && browseDir > 0) {
      std::string from = idx->dirs[(size_t)browseDir].path;
      int32_t p = idx->dirs[(size_t)browseDir].parent;
      browseDir = p < 0 ? 0 : p;
      lists[V_BROWSE].scroll = 0;
      buildBrowse(from);
      return true;
    }
    if (view == V_CLEANUP && finder >= 0) {
      finderCancel = true;
      finder = -1;
      return true;
    }
    return false;
  }

  void move(int delta) {
    if (view == V_CLEANUP && finder < 0) {
      finderCursor = std::max(0, std::min(NFINDERS - 1, finderCursor + delta));
      return;
    }
    ListState* l = activeList();
    if (!l || l->rows.empty()) return;
    l->cursor = std::max(0, std::min((int)l->rows.size() - 1, l->cursor + delta));
  }

  // Returns false to quit.
  bool handle(int k) {
    if (modal == M_CONFIRM) {
      if (k == 'y' || k == 'Y') doRemove();
      modal = M_NONE;
      return true;
    }
    if (modal != M_NONE) {
      modal = M_NONE;
      return true;
    }
    flash.clear();
    ListState* l = activeList();
    int page = std::max(1, H - 6);
    switch (k) {
      case 'q': return false;
      case K_ESC: case K_BACKSPACE: case K_LEFT: case 'h':
        if (!back() && k == K_ESC) return false;
        break;
      case K_UP: case 'k': move(-1); break;
      case K_DOWN: case 'j': move(1); break;
      case K_PGUP: move(-page); break;
      case K_PGDN: move(page); break;
      case K_HOME: case 'g': move(-1000000); break;
      case K_END: case 'G': move(1000000); break;
      case K_ENTER: case K_RIGHT: case 'l': enter(); break;
      case K_TAB: view = (View)((view + 1) % NVIEWS); break;
      case K_BTAB: view = (View)((view + NVIEWS - 1) % NVIEWS); break;
      case '1': case '2': case '3': case '4': case '5': case '6': view = (View)(k - '1'); break;
      case ' ':
        if (l && !l->rows.empty() && !l->rows[(size_t)l->cursor].path.empty()) {
          l->rows[(size_t)l->cursor].marked ^= true;
          move(1);
        }
        break;
      case 'a':
        if (l) {
          bool any = std::any_of(l->rows.begin(), l->rows.end(), [](const Row& r) { return r.marked; });
          for (Row& r : l->rows) if (!r.path.empty()) r.marked = !any;
        }
        break;
      case 'd': askRemove(); break;
      case 'o': openCurrent(); break;
      case 's':
        sortByAge = !sortByAge;
        if (idx) rebuild();
        if (view == V_CLEANUP && finderReady && finder != F_DUPLICATES) sortRows(lists[V_CLEANUP].rows);
        flash = sortByAge ? "Sorted by last used (oldest first)" : "Sorted by size";
        break;
      case 'r':
        startScan();
        flash = "Rescanning " + tilde(opt.root);
        break;
      case '?': modal = M_HELP; break;
    }
    return true;
  }

  // ── rendering ──
  std::string tabs() {
    Line ln(W);
    ln.add(" stale ", "\x1b[1;7m");
    ln.add(" ");
    for (int v = 0; v < NVIEWS; ++v) {
      std::string t = " " + std::to_string(v + 1) + " " + kViewNames[v] + " ";
      ln.add(t, v == view ? "\x1b[1;34m" : FG_DIM);
    }
    return ln.done();
  }

  std::string rowLine(const Row& r, bool selected, uint64_t parentSize, bool showBar) {
    Line ln(W, selected);
    double now = idx ? idx->now : (double)time(nullptr);
    ln.add(r.path.empty() ? "  " : r.marked ? "● " : r.keep ? "◆ " : "○ ", r.marked ? FG_ACCENT : FG_DIM);
    ln.add(padLeft(humanBytes(r.size), 6), FG_BOLD);
    ln.add("  ");
    Bucket b = bucketFor(r.lastUsed, now);
    std::string a = age(r.lastUsed, now);
    ln.add(a + std::string((size_t)std::max(0, 6 - textWidth(a)), ' '), bucketColor(b));
    ln.add(" ");
    if (showBar) {
      ln.add(meter(parentSize ? (double)r.size / (double)parentSize : 0, 10), FG_ACCENT);
      ln.add("  ");
    }
    ln.add(r.label, r.isDir ? FG_BOLD : "");
    if (!r.note.empty()) {
      ln.add("  ");
      ln.add(r.note, FG_DIM);
    }
    return ln.done();
  }

  void drawList(std::vector<std::string>& out, ListState& l, int top, int rows, uint64_t parentSize, bool showBar,
                const char* empty) {
    if (l.rows.empty()) {
      Line ln(W);
      ln.add("  ");
      ln.add(empty, FG_DIM);
      out.push_back(ln.done());
      return;
    }
    if (l.cursor < l.scroll) l.scroll = l.cursor;
    if (l.cursor >= l.scroll + rows) l.scroll = l.cursor - rows + 1;
    (void)top;
    for (int i = l.scroll; i < (int)l.rows.size() && i < l.scroll + rows; ++i)
      out.push_back(rowLine(l.rows[(size_t)i], i == l.cursor, parentSize, showBar));
  }

  std::string heading(const std::string& title, const std::string& right = "") {
    Line ln(W);
    ln.add(" " + title, "\x1b[1m");
    if (!right.empty()) {
      ln.add("  ");
      ln.add(right, FG_DIM);
    }
    return ln.done();
  }

  void drawOverview(std::vector<std::string>& out) {
    const ScanResult& r = *idx;
    const DirNode& root = r.dirs[0];
    struct statvfs vs;
    if (statvfs(opt.root.c_str(), &vs) == 0) {
      uint64_t total = (uint64_t)vs.f_blocks * vs.f_frsize, avail = (uint64_t)vs.f_bavail * vs.f_frsize;
      uint64_t used = total - (uint64_t)vs.f_bfree * vs.f_frsize;
      double frac = used + avail ? (double)used / (double)(used + avail) : 0;
      out.push_back(heading("Disk"));
      Line ln(W);
      ln.add("  ");
      ln.add(meter(frac, std::min(40, W / 2)), frac > .9 ? FG_RED : frac > .75 ? FG_YELLOW : FG_ACCENT);
      char buf[96];
      snprintf(buf, sizeof buf, "  %.0f%% used · %s free of %s", frac * 100, humanBytes(avail).c_str(),
               humanBytes(total).c_str());
      ln.add(buf);
      out.push_back(ln.done());
      out.push_back("");
    }
    char buf[160];
    snprintf(buf, sizeof buf, "%s in %llu files", humanBytes(root.size).c_str(), (unsigned long long)r.files);
    out.push_back(heading("By last use, " + tilde(root.path), buf));
    for (int b = 0; b < NBUCKETS; ++b) {
      double frac = root.size ? (double)root.bucketSize[b] / (double)root.size : 0;
      Line ln(W);
      ln.add("  ");
      std::string name = kBucketNames[b];
      ln.add(name + std::string((size_t)std::max(0, 7 - textWidth(name)), ' '), bucketColor((Bucket)b));
      const char* span[] = {"< 7 days", "< 30 days", "< 6 months", "< 1 year", "1 year +"};
      ln.add(std::string(span[b]) + std::string((size_t)std::max(0, 11 - textWidth(span[b])), ' '), FG_DIM);
      ln.add(meter(frac, std::min(30, W / 3)), bucketColor((Bucket)b));
      ln.add("  " + padLeft(humanBytes(root.bucketSize[b]), 6), FG_BOLD);
      out.push_back(ln.done());
    }
    out.push_back("");
    uint64_t reclaim = 0, forgotten = 0, big = 0;
    for (const Row& x : lists[V_RECLAIM].rows) reclaim += x.size;
    for (const Row& x : lists[V_FORGOTTEN].rows) forgotten += x.size;
    for (const Row& x : lists[V_BIG].rows) big += x.size;
    out.push_back(heading("Where to look"));
    struct { int key; const char* name; uint64_t bytes; size_t n; const char* what; } tips[] = {
        {3, "Reclaimable", reclaim, lists[V_RECLAIM].rows.size(), "node_modules, build output, caches, venvs"},
        {4, "Forgotten", forgotten, lists[V_FORGOTTEN].rows.size(), "folders untouched for 6+ months"},
        {5, "Big files", big, lists[V_BIG].rows.size(), "100 MB+ files"},
    };
    for (auto& t : tips) {
      Line ln(W);
      ln.add("  " + std::to_string(t.key) + "  ", FG_ACCENT);
      ln.add(padLeft(humanBytes(t.bytes), 6), FG_BOLD);
      ln.add("  " + std::string(t.name) + " (" + std::to_string(t.n) + ")  ");
      ln.add(t.what, FG_DIM);
      out.push_back(ln.done());
    }
    Line ln(W);
    ln.add("  6  ", FG_ACCENT);
    ln.add("       Cleanup  ");
    ln.add("duplicates, AI agent files, old downloads, leftovers, Trash", FG_DIM);
    out.push_back(ln.done());
    if (root.neverOpenedSize) {
      out.push_back("");
      Line n(W);
      n.add("  " + humanBytes(root.neverOpenedSize), FG_BOLD);
      n.add(" in files that look never opened since they were downloaded or copied here", FG_DIM);
      out.push_back(n.done());
    }
  }

  void drawCleanupMenu(std::vector<std::string>& out) {
    out.push_back(heading("Cleanup", "Enter to run a finder; nothing is removed until you confirm"));
    out.push_back("");
    for (int i = 0; i < NFINDERS; ++i) {
      Line ln(W, i == finderCursor);
      ln.add("  ");
      ln.add(std::string(kFinders[i].name) + std::string((size_t)std::max(0, 16 - textWidth(kFinders[i].name)), ' '), FG_BOLD);
      ln.add(kFinders[i].what, FG_DIM);
      out.push_back(ln.done());
    }
  }

  std::string spinner() {
    static const char* f[] = {"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"};
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
    return f[(ms / 100) % 10];
  }

  std::string footer() {
    Line ln(W);
    if (modal == M_CONFIRM) {
      ln.add(" " + modalText + " ", "\x1b[1;7m");
      ln.add("  y ", FG_BOLD);
      ln.add("confirm   ");
      ln.add("any other key ", FG_BOLD);
      ln.add("cancel");
      return ln.done();
    }
    if (!flash.empty()) {
      ln.add(" " + flash, FG_YELLOW);
      return ln.done();
    }
    if (scanning) {
      double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - scanStart).count();
      char buf[96];
      snprintf(buf, sizeof buf, " %s scanning… %llu files, %.0fs", spinner().c_str(), (unsigned long long)scanFiles.load(), s);
      ln.add(buf, FG_ACCENT);
      ln.add("   ");
    }
    const char* keys = view == V_OVERVIEW ? "1-6 views  tab next  r rescan  ? help  q quit"
                       : view == V_BROWSE ? "↑↓ move  →/enter open  ← up  space mark  d trash  o open  s sort  ? help"
                       : view == V_CLEANUP && finder < 0 ? "↑↓ choose  enter run  ? help  q quit"
                                                         : "↑↓ move  space mark  a all  d trash  o open  s sort  ← back  ? help";
    ln.add(" " + std::string(keys), FG_DIM);
    return ln.done();
  }

  void drawHelp(std::vector<std::string>& out) {
    const char* lines[] = {
        "Views      1 Overview  2 Browse  3 Reclaimable  4 Forgotten  5 Big files  6 Cleanup (tab / shift-tab)",
        "Move       ↑↓ or j k, PgUp PgDn, g G / Home End",
        "Browse     → / Enter / l opens a folder, ← / Backspace / h goes up",
        "Select     space marks the row, a marks or clears all",
        "Remove     d moves marked rows (or the current one) to the Trash, after confirming",
        "           In Cleanup › Trash it deletes them permanently",
        "Other      o opens in the file manager, s sorts by size / last use, r rescans, q quits",
        "",
        "Ages: hot < 7 days, warm < 30 days, cold < 6 months, stale < 1 year, frozen older.",
        "Last use is the newest of modification time and recently-used.xbel (the list apps",
        "update when you open a file). Pass --atime to count reads too, if your mounts record them.",
    };
    out.push_back(heading("Keys"));
    for (const char* s : lines) {
      Line ln(W);
      ln.add("  " + std::string(s));
      out.push_back(ln.done());
    }
    out.push_back("");
    Line ln(W);
    ln.add("  any key to close", FG_DIM);
    out.push_back(ln.done());
  }

  void draw() {
    std::vector<std::string> out;
    out.push_back(tabs());
    int bodyRows = H - 3;
    if (modal == M_HELP) {
      out.push_back("");
      drawHelp(out);
    } else if (!idx || idx->dirs.empty()) {
      out.push_back("");
      out.push_back(heading(scanning ? "Scanning " + tilde(opt.root) : "Nothing scanned yet",
                            scanning ? std::to_string(scanFiles.load()) + " files so far" : "press r to scan"));
    } else if (view == V_OVERVIEW) {
      if (!cachedNote.empty()) out.push_back(heading("", cachedNote));
      else out.push_back("");
      drawOverview(out);
    } else if (view == V_BROWSE) {
      const DirNode& d = idx->dirs[(size_t)browseDir];
      out.push_back(heading(tilde(d.path), humanBytes(d.size) + " · last used " + age(d.lastUsed, idx->now)));
      drawList(out, lists[V_BROWSE], 2, bodyRows - 1, d.size, true, "Empty folder");
    } else if (view == V_CLEANUP) {
      if (finder < 0) {
        drawCleanupMenu(out);
      } else if (!finderReady) {
        std::string prog;
        if (finderTotal > 0) {
          char b[32];
          snprintf(b, sizeof b, "%.0f%%", 100.0 * (double)finderDone / (double)finderTotal);
          prog = b;
        }
        out.push_back(heading(spinner() + " " + kFinders[finder].name, "looking… " + prog));
      } else {
        uint64_t marked = 0, total = 0;
        for (const Row& r : lists[V_CLEANUP].rows) {
          total += r.size;
          if (r.marked) marked += r.size;
        }
        out.push_back(heading(kFinders[finder].name, humanBytes(total) + " found · " + humanBytes(marked) + " marked"));
        drawList(out, lists[V_CLEANUP], 2, bodyRows - 1, 0, false, "Nothing found");
      }
    } else {
      uint64_t total = 0, marked = 0;
      for (const Row& r : lists[view].rows) {
        total += r.size;
        if (r.marked) marked += r.size;
      }
      const char* sub = view == V_RECLAIM ? "safe to regenerate; cold ones marked"
                      : view == V_FORGOTTEN ? "≥90% untouched for 6+ months"
                                            : "100 MB+ files";
      out.push_back(heading(std::string(kViewNames[view]) + "  " + humanBytes(total),
                            std::string(sub) + (marked ? " · " + humanBytes(marked) + " marked" : "")));
      drawList(out, lists[view], 2, bodyRows - 1, 0, false, "Nothing here");
    }
    std::string frame = "\x1b[H";
    for (int i = 0; i < H - 1; ++i) {
      if (i < (int)out.size()) frame += out[(size_t)i];
      frame += "\x1b[K\r\n";
    }
    frame += footer() + "\x1b[K";
    writeAll(frame);
  }
};

}  // namespace

int runTui(const TuiOptions& o) {
  if (!isatty(0) || !isatty(1)) {
    fprintf(stderr, "stale tui: needs a terminal (try `stale %s` for a report)\n", o.root.c_str());
    return 2;
  }
  auto t = std::make_unique<Tui>();
  t->opt = o;
  auto cached = std::make_shared<ScanResult>();
  IndexMeta meta;
  if (loadIndex(indexPath(o.root), o.root, *cached, &meta) && !cached->dirs.empty()) {
    t->idx = cached;
    t->cachedNote = "cached scan (" + age(meta.savedAt, (double)time(nullptr)) + " old), rescanning in the background";
    t->rebuild();
  }
  if (!enterRaw()) {
    fprintf(stderr, "stale tui: cannot configure the terminal\n");
    return 1;
  }
  t->startScan();
  for (;;) {
    if (gResized) {
      gResized = 0;
      termSize(t->W, t->H);
      writeAll("\x1b[2J");
    }
    reapSpawned();
    t->adoptScan();
    if (!t->finding) t->adoptFinder();
    t->draw();
    int k = readKey(t->scanning || t->finding ? 120 : 1000);
    if (k == K_NONE) continue;
    if (!t->handle(k)) break;
  }
  t.reset();
  restoreTerminal();
  return 0;
}

}  // namespace stale
