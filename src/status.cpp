#include "status.h"

#include <sys/statvfs.h>

#include <cmath>
#include <cstdio>
#include <ctime>

#include "index.h"

namespace stale {
namespace {

std::string summaryPath() { return indexDir() + "/summary"; }

std::string jsonEscape(const std::string& s) {
  std::string o;
  for (char c : s) {
    if (c == '"' || c == '\\') { o += '\\'; o += c; }
    else if (c == '\n') o += "\\n";
    else if ((unsigned char)c < 0x20) { char b[8]; snprintf(b, sizeof b, "\\u%04x", c); o += b; }
    else o += c;
  }
  return o;
}

std::string ago(double t, double now) {
  double d = now - t;
  char b[32];
  if (d < 90) return "just now";
  if (d < 5400) snprintf(b, sizeof b, "%d min ago", (int)(d / 60));
  else if (d < 172800) snprintf(b, sizeof b, "%d h ago", (int)(d / 3600));
  else snprintf(b, sizeof b, "%d days ago", (int)(d / 86400));
  return b;
}

}  // namespace

std::string humanBytes(uint64_t b) {
  const char* u[] = {"B", "K", "M", "G", "T", "P"};
  double v = (double)b;
  int i = 0;
  while (v >= 1024 && i < 5) { v /= 1024; ++i; }
  char buf[32];
  if (i == 0) snprintf(buf, sizeof buf, "%lluB", (unsigned long long)b);
  else snprintf(buf, sizeof buf, v < 10 ? "%.1f%s" : "%.0f%s", v, u[i]);
  return buf;
}

Summary summarize(const ScanResult& r) {
  Summary s;
  s.scannedAt = r.now;
  s.files = r.files;
  if (r.dirs.empty()) return s;
  s.scanned = r.dirs[0].size;
  std::vector<int32_t> units;
  collectUnits(r, 0, units, [](const DirNode& d) { return categoryReclaimable(d.category); });
  for (int32_t id : units) s.reclaimable += r.dirs[(size_t)id].size;
  for (int b = STALE; b < NBUCKETS; ++b) s.unused += r.dirs[0].bucketSize[b];
  return s;
}

bool writeSummary(const Summary& s) {
  char buf[256];
  int n = snprintf(buf, sizeof buf, "scannedAt=%.0f\nscanned=%llu\nreclaimable=%llu\nunused=%llu\nfiles=%llu\n",
                   s.scannedAt, (unsigned long long)s.scanned, (unsigned long long)s.reclaimable,
                   (unsigned long long)s.unused, (unsigned long long)s.files);
  return n > 0 && writeIndex(summaryPath(), std::string(buf, (size_t)n));
}

bool readSummary(Summary& s) {
  FILE* f = fopen(summaryPath().c_str(), "r");
  if (!f) return false;
  char key[32];
  double v;
  int got = 0;
  while (fscanf(f, "%31[^=]=%lf\n", key, &v) == 2) {
    std::string k = key;
    if (k == "scannedAt") s.scannedAt = v, ++got;
    else if (k == "scanned") s.scanned = (uint64_t)v;
    else if (k == "reclaimable") s.reclaimable = (uint64_t)v;
    else if (k == "unused") s.unused = (uint64_t)v;
    else if (k == "files") s.files = (uint64_t)v;
  }
  fclose(f);
  return got > 0;
}

int printStatus(const std::string& home, bool json) {
  struct statvfs vs;
  if (statvfs(home.c_str(), &vs) != 0) {
    perror("stale: statvfs");
    return 1;
  }
  uint64_t total = (uint64_t)vs.f_blocks * vs.f_frsize, avail = (uint64_t)vs.f_bavail * vs.f_frsize;
  uint64_t used = total - (uint64_t)vs.f_bfree * vs.f_frsize;
  int pct = total ? (int)std::lround(100.0 * (double)used / (double)(used + avail)) : 0;
  Summary s;
  bool have = readSummary(s);
  double now = (double)time(nullptr);

  std::string tip = "Disk: " + humanBytes(used) + " used, " + humanBytes(avail) + " free (" + std::to_string(pct) + "%)";
  if (have) {
    tip += "\nReclaimable: " + humanBytes(s.reclaimable) + "\nUnused 6+ months: " + humanBytes(s.unused) +
           "\nScanned " + ago(s.scannedAt, now);
  } else {
    tip += "\nNot scanned yet, click to open Stale";
  }
  const char* cls = pct >= 90 ? "critical" : pct >= 75 ? "warning" : "normal";
  if (json) {
    printf("{\"text\":\"%d%%\",\"alt\":\"%s\",\"class\":\"%s\",\"percentage\":%d,\"tooltip\":\"%s\","
           "\"used\":%llu,\"free\":%llu,\"total\":%llu,\"reclaimable\":%llu,\"unused\":%llu,\"scannedAt\":%.0f}\n",
           pct, cls, cls, pct, jsonEscape(tip).c_str(), (unsigned long long)used, (unsigned long long)avail,
           (unsigned long long)total, (unsigned long long)(have ? s.reclaimable : 0),
           (unsigned long long)(have ? s.unused : 0), have ? s.scannedAt : 0.0);
  } else {
    printf("%d%% used · %s free", pct, humanBytes(avail).c_str());
    if (have) printf(" · %s reclaimable", humanBytes(s.reclaimable).c_str());
    printf("\n");
  }
  return 0;
}

int refreshStatus(const std::string& home, int threads, bool json) {
  ScanOptions so;
  so.root = home;
  so.threads = threads;
  ScanResult r = scan(so);
  if (r.dirs.empty()) {
    fprintf(stderr, "stale: cannot scan %s\n", home.c_str());
    return 1;
  }
  writeSummary(summarize(r));
#ifndef __APPLE__
  saveIndex(indexPath(home), home, r, IndexMeta{r.now, 0, {}});
#endif
  return printStatus(home, json);
}

}  // namespace stale
