// Fixture tests for the scanner, the persistent index and the cleanup finders.
// Everything runs inside a throwaway folder under $HOME (duplicates skip /private).
#include "finders.h"
#include "index.h"
#include "scan.h"

#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <fstream>
#include <functional>
#include <string>
#include <vector>

using namespace stale;

static int failures = 0;
static int checks = 0;
#define CHECK(cond)                                                          \
  do {                                                                       \
    ++checks;                                                                \
    if (!(cond)) {                                                           \
      ++failures;                                                            \
      fprintf(stderr, "  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);      \
    }                                                                        \
  } while (0)

static const double kDay = 86400;
static double now = 0;
static std::string root;

static void sh(const std::string& cmd) {
  if (system(cmd.c_str()) != 0) {
    fprintf(stderr, "command failed: %s\n", cmd.c_str());
    exit(2);
  }
}

static std::string q(const std::string& s) { return "'" + s + "'"; }

static void writeFile(const std::string& path, size_t bytes, char seed = 'a') {
  sh("mkdir -p " + q(path.substr(0, path.find_last_of('/'))));
  std::ofstream f(path, std::ios::binary);
  std::string block(64 << 10, seed);
  for (size_t i = 0; i < block.size(); ++i) block[i] = (char)(seed + (i * 131) % 97);
  for (size_t done = 0; done < bytes; done += block.size())
    f.write(block.data(), (std::streamsize)std::min(block.size(), bytes - done));
}

// Set mtime/atime of a path and everything below it.
static void age(const std::string& path, double days) {
  time_t t = (time_t)(now - days * kDay);
  char stamp[32];
  strftime(stamp, sizeof stamp, "%Y%m%d%H%M.%S", localtime(&t));
  sh("find " + q(path) + " -exec touch -h -t " + stamp + " {} +");
}

static const Found* find(const FinderResult& r, const std::string& path) {
  for (const Found& f : r.items)
    if (f.path == path) return &f;
  return nullptr;
}

static bool contains(const std::string& s, const char* part) { return s.find(part) != std::string::npos; }

static ScanResult scanRoot(const std::string& path) {
  ScanOptions so;
  so.root = path;
  so.spotlight = false;
  return scan(so);
}

static FinderOptions opts(const ScanResult& r, const std::string& home) {
  FinderOptions o;
  o.index = &r;
  o.home = home;
  o.now = now;
  return o;
}

// ───────────────────────────── scanner ─────────────────────────────

static void testClassify() {
  std::string p = root + "/classify";
  sh("mkdir -p " + q(p + "/web/build") + " " + q(p + "/plain/build"));
  writeFile(p + "/web/package.json", 10);
  CHECK(classifyDir(p + "/web/node_modules", "node_modules", root) == CAT_NODE_MODULES);
  CHECK(classifyDir(p + "/web/build", "build", root) == CAT_BUILD);
  CHECK(classifyDir(p + "/plain/build", "build", root) != CAT_BUILD);
  CHECK(classifyDir(p + "/x/.git", ".git", root) == CAT_GIT);
  CHECK(classifyDir(p + "/Foo.app", "Foo.app", root) == CAT_APP);
  CHECK(categoryReclaimable(CAT_NODE_MODULES));
  CHECK(!categoryReclaimable(CAT_GIT));
  CHECK(bucketFor(now - kDay, now) == HOT);
  CHECK(bucketFor(now - 1000 * kDay, now) == FROZEN);
}

static void testScan() {
  std::string p = root + "/scan";
  writeFile(p + "/a.txt", 8 << 10);
  writeFile(p + "/docs/b.txt", 8 << 10);
  writeFile(p + "/docs/big.bin", 5 << 20);
  writeFile(p + "/web/package.json", 100);
  writeFile(p + "/web/node_modules/lib/index.js", 16 << 10);
  age(p + "/docs", 400);

  ScanResult r = scanRoot(p);
  CHECK(r.files == 5);
  CHECK(!r.dirs.empty() && r.dirs[0].path == p);
  CHECK(r.dirs[0].size >= (5u << 20) + (32u << 10));

  int32_t docs = findDir(r, p + "/docs");
  CHECK(docs >= 0);
  if (docs >= 0) {
    CHECK(r.dirs[docs].files == 2);
    CHECK(r.dirs[docs].bucketSize[FROZEN] >= (5u << 20));
    CHECK(now - r.dirs[docs].lastUsed > 300 * kDay);
  }
  int32_t nm = findDir(r, p + "/web/node_modules");
  CHECK(nm >= 0 && r.dirs[nm].category == CAT_NODE_MODULES && r.dirs[nm].unit);
  CHECK(r.dirs[0].reclaimableSize >= (16u << 10));

  bool big = false;
  for (const FileRec& f : r.bigFiles) big |= f.path == p + "/docs/big.bin";
  CHECK(big);
}

static void testRefresh() {
  std::string p = root + "/refresh";
  writeFile(p + "/keep/a.txt", 4 << 10);
  ScanResult r = scanRoot(p);
  uint64_t before = r.files;

  auto refresh = [&](const std::string& dir) {
    RefreshPlan plan = planRefresh(r, {RefreshRequest{dir, false}});
    ScanOptions so;
    so.root = p;
    so.spotlight = false;
    RefreshPatch patch = collectRefresh(so, plan, {});
    CHECK(applyRefresh(r, std::move(patch)));
  };

  writeFile(p + "/new/deep/b.txt", 4 << 10);
  writeFile(p + "/new/c.txt", 4 << 10);
  refresh(p);
  CHECK(r.files == before + 2);
  CHECK(findDir(r, p + "/new/deep") >= 0);

  sh("rm -rf " + q(p + "/new"));
  refresh(p);
  CHECK(r.files == before);
  CHECK(findDir(r, p + "/new") < 0);
}

// ───────────────────────────── index ─────────────────────────────

static void testIndex() {
  std::string p = root + "/scan";
  ScanResult r = scanRoot(p);
  IndexMeta meta;
  meta.savedAt = now;
  meta.eventId = 12345;
  meta.volumeUUIDs = {"UUID-1"};
  std::string file = root + "/index.bin";
  CHECK(saveIndex(file, p, r, meta));

  ScanResult back;
  IndexMeta m2;
  CHECK(loadIndex(file, p, back, &m2));
  CHECK(back.files == r.files);
  CHECK(back.dirs.size() == r.dirs.size());
  CHECK(!back.dirs.empty() && back.dirs[0].size == r.dirs[0].size);
  CHECK(back.bigFiles.size() == r.bigFiles.size());
  CHECK(m2.eventId == 12345 && m2.volumeUUIDs == meta.volumeUUIDs);
  int32_t nm = findDir(back, p + "/web/node_modules");
  CHECK(nm >= 0 && back.dirs[nm].category == CAT_NODE_MODULES);

  ScanResult other;
  CHECK(!loadIndex(file, p + "/elsewhere", other, nullptr));

  // A truncated or corrupted file is rejected, never half-loaded.
  std::string bytes = encodeIndex(p, r, meta);
  CHECK(!bytes.empty());
  CHECK(writeIndex(root + "/short.bin", bytes.substr(0, bytes.size() / 2)));
  ScanResult bad;
  CHECK(!loadIndex(root + "/short.bin", p, bad, nullptr));
  std::string flipped = bytes;
  flipped[flipped.size() / 2] ^= 0x5a;
  CHECK(writeIndex(root + "/flipped.bin", flipped));
  CHECK(!loadIndex(root + "/flipped.bin", p, bad, nullptr));
  CHECK(!loadIndex(root + "/missing.bin", p, bad, nullptr));
}

// ───────────────────────────── finders ─────────────────────────────

static void gitRepo(const std::string& dir) {
  std::string g = "git -C " + q(dir) + " -c user.name=t -c user.email=t@t -c commit.gpgsign=false ";
  sh("mkdir -p " + q(dir) + " && git -C " + q(dir) + " init -q -b main");
  writeFile(dir + "/src.txt", 64 << 10);
  sh(g + "add -A && " + g + "commit -q -m init");
}

static void testAgentFiles() {
  std::string h = root + "/agents";
  std::string clean = h + "/.codex/worktrees/a1/clean";
  std::string dirty = h + "/.codex/worktrees/a2/dirty";
  std::string detached = h + "/.codex/worktrees/a3/detached";
  std::string fresh = h + "/.cursor/worktrees/proj/fresh";
  std::string claudeWt = h + "/code/app/.claude/worktrees/feature";
  gitRepo(clean);
  gitRepo(dirty);
  writeFile(dirty + "/src.txt", 32 << 10, 'z');  // modified, not committed
  gitRepo(detached);
  std::string g = "git -C " + q(detached) + " -c user.name=t -c user.email=t@t -c commit.gpgsign=false ";
  sh(g + "checkout -q --detach && echo more > " + q(detached + "/extra.txt") + " && " + g + "add -A && " + g +
     "commit -q -m lost");
  gitRepo(fresh);
  gitRepo(claudeWt);
  writeFile(h + "/.claude/debug/log.txt", 2 << 20);
  writeFile(h + "/.ollama/models/blobs/m.bin", 2 << 20);
  age(h, 30);
  age(fresh, 1);

  ScanResult r = scanRoot(h);
  FinderResult res = findAgentFiles(opts(r, h));

  const Found* f = find(res, clean);
  CHECK(f && f->preselect);
  if (f) CHECK(contains(f->note, "no unsaved work"));
  f = find(res, dirty);
  CHECK(f && !f->preselect);
  if (f) CHECK(contains(f->note, "uncommitted"));
  f = find(res, detached);
  CHECK(f && !f->preselect);
  f = find(res, fresh);
  CHECK(f && !f->preselect);
  f = find(res, claudeWt);
  CHECK(f && f->preselect);
  f = find(res, h + "/.claude/debug");
  CHECK(f && f->preselect);
  f = find(res, h + "/.ollama/models");
  CHECK(f && !f->preselect);

  for (const Found& it : res.items) {
    CHECK(!it.note.empty());
    CHECK(it.path.compare(0, h.size(), h) == 0);  // nothing outside the given home
  }
  uint64_t suggested = 0;
  for (const Found& it : res.items) suggested += it.preselect ? it.size : 0;
  CHECK(res.suggested == suggested);
}

static void testDuplicates() {
  std::string h = root + "/dups";
  writeFile(h + "/Documents/report.pdf", 5 << 20, 'd');
  writeFile(h + "/Desktop/report copy.pdf", 5 << 20, 'd');
  writeFile(h + "/Desktop/other.pdf", 5 << 20, 'e');  // same size, different content
  writeFile(h + "/Library/Caches/x/report.pdf", 5 << 20, 'd');  // ~/Library is never deduped
  age(h + "/Desktop/report copy.pdf", 60);

  ScanResult r = scanRoot(h);
  FinderResult res = findDuplicates(opts(r, h));
  CHECK(res.items.size() == 2);
  const Found* keep = find(res, h + "/Documents/report.pdf");
  const Found* copy = find(res, h + "/Desktop/report copy.pdf");
  CHECK(keep && !keep->preselect);
  CHECK(copy && copy->preselect);
  CHECK(keep && copy && keep->group == copy->group);
  CHECK(!find(res, h + "/Desktop/other.pdf"));
}

static void testOldDownloads() {
  std::string h = root + "/downloads";
  std::string d = h + "/Downloads";
  writeFile(d + "/ZzNoSuchApp-1.0.dmg", 1 << 20);
  writeFile(d + "/old-notes.txt", 64 << 10);
  writeFile(d + "/half.crdownload", 64 << 10);
  age(d, 90);
  writeFile(d + "/new.zip", 64 << 10);

  ScanResult r = scanRoot(h);
  FinderResult res = findOldDownloads(opts(r, h));
  CHECK(find(res, d + "/ZzNoSuchApp-1.0.dmg") != nullptr);
  CHECK(!find(res, d + "/new.zip"));
  for (const Found& f : res.items) CHECK(!f.note.empty());
}

static void testTrash() {
  std::string h = root + "/trash";
  writeFile(h + "/.Trash/old.bin", 1 << 20);
  ScanResult r = scanRoot(h);
  FinderResult res = findTrash(opts(r, h));
  CHECK(find(res, h + "/.Trash/old.bin") != nullptr);
  CHECK(!res.unreadable);
}

int main() {
  now = (double)time(nullptr);
  const char* home = getenv("HOME");
  char buf[PATH_MAX];
  std::string tmpl = std::string(realpath(home ? home : "/tmp", buf)) + "/stale-test-XXXXXX";
  std::vector<char> t(tmpl.begin(), tmpl.end());
  t.push_back(0);
  if (!mkdtemp(t.data())) return 2;
  root = t.data();

  struct Test {
    const char* name;
    void (*fn)();
  } tests[] = {{"classify", testClassify},     {"scan", testScan},         {"refresh", testRefresh},
               {"index", testIndex},           {"agent files", testAgentFiles}, {"duplicates", testDuplicates},
               {"old downloads", testOldDownloads}, {"trash", testTrash}};
  for (const Test& test : tests) {
    int before = failures;
    test.fn();
    printf("%s %s\n", failures == before ? "ok  " : "FAIL", test.name);
  }
  sh("rm -rf " + q(root));
  printf("%d checks, %d failed\n", checks, failures);
  return failures ? 1 : 0;
}
