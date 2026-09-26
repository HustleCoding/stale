#include "index.h"

#include <sys/stat.h>
#include <unistd.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace stale {

namespace {

const char kMagic[8] = {'S', 'T', 'A', 'L', 'E', 'I', 'D', 'X'};
const uint32_t kVersion = 3;

uint64_t fnv1a(const char* p, size_t n) {
  uint64_t h = 1469598103934665603ull;
  for (size_t i = 0; i < n; ++i) {
    h ^= static_cast<unsigned char>(p[i]);
    h *= 1099511628211ull;
  }
  return h;
}

uint64_t hashPath(const std::string& s) { return fnv1a(s.data(), s.size()); }

struct Writer {
  std::string buf;
  template <class T>
  void raw(const T& v) {
    buf.append(reinterpret_cast<const char*>(&v), sizeof v);
  }
  void u8(uint8_t v) { raw(v); }
  // LEB128: sizes and counts are usually small, so this roughly halves the file.
  void u64(uint64_t v) {
    while (v >= 0x80) {
      buf.push_back(static_cast<char>((v & 0x7f) | 0x80));
      v >>= 7;
    }
    buf.push_back(static_cast<char>(v));
  }
  void u32(uint32_t v) { u64(v); }
  void i32(int32_t v) { u64(static_cast<uint64_t>(static_cast<int64_t>(v) + 1)); }
  void f64(double v) { raw(v); }
  void str(const std::string& s) {
    u32(static_cast<uint32_t>(s.size()));
    buf.append(s);
  }
};

struct Reader {
  const char* p;
  const char* end;
  bool ok = true;

  template <class T>
  T raw() {
    T v{};
    if (end - p < static_cast<ptrdiff_t>(sizeof v)) {
      ok = false;
      p = end;
      return v;
    }
    memcpy(&v, p, sizeof v);
    p += sizeof v;
    return v;
  }
  uint8_t u8() { return raw<uint8_t>(); }
  uint64_t u64() {
    uint64_t v = 0;
    for (int shift = 0; shift < 64; shift += 7) {
      if (p >= end) {
        ok = false;
        return 0;
      }
      uint8_t b = static_cast<uint8_t>(*p++);
      v |= static_cast<uint64_t>(b & 0x7f) << shift;
      if (!(b & 0x80)) return v;
    }
    ok = false;
    return 0;
  }
  uint32_t u32() {
    uint64_t v = u64();
    if (v > UINT32_MAX) ok = false;
    return static_cast<uint32_t>(v);
  }
  int32_t i32() {
    uint64_t v = u64();
    if (v > static_cast<uint64_t>(INT32_MAX) + 1) ok = false;
    return static_cast<int32_t>(static_cast<int64_t>(v) - 1);
  }
  double f64() { return raw<double>(); }
  std::string str() {
    uint32_t n = u32();
    if (!ok || end - p < static_cast<ptrdiff_t>(n)) {
      ok = false;
      p = end;
      return {};
    }
    std::string s(p, n);
    p += n;
    return s;
  }
};

std::string baseName(const std::string& path) {
  size_t slash = path.find_last_of('/');
  return slash == std::string::npos ? path : path.substr(slash + 1);
}

}  // namespace

std::string indexDir() {
  const char* h = getenv("HOME");
  return std::string(h ? h : "") + "/Library/Application Support/Stale";
}

std::string indexPath(const std::string& root) {
  char hex[17];
  snprintf(hex, sizeof hex, "%016llx", static_cast<unsigned long long>(hashPath(root)));
  return indexDir() + "/index-" + hex + ".stale";
}

std::string encodeIndex(const std::string& root, const ScanResult& r, const IndexMeta& meta) {
  if (r.dirs.empty()) return {};
  // Gone / never-scanned nodes are dropped; ids are renumbered, order (parents first) is kept.
  std::vector<int32_t> remap(r.dirs.size(), -1);
  int32_t live = 0;
  for (size_t i = 0; i < r.dirs.size(); ++i) {
    const DirNode& d = r.dirs[i];
    bool keep = i == 0 || (!d.path.empty() && d.parent >= 0 && d.parent < static_cast<int32_t>(i) &&
                           remap[static_cast<size_t>(d.parent)] >= 0);
    if (keep) remap[i] = live++;
  }

  Writer w;
  w.buf.reserve(static_cast<size_t>(live) * 48 + r.bigFiles.size() * 96 + r.spotlight.size() * 96 + 256);
  w.buf.append(kMagic, sizeof kMagic);
  w.u32(kVersion);
  w.u32(0);
  w.f64(meta.savedAt);
  w.str(root);
  w.raw(meta.eventId);
  w.u32(static_cast<uint32_t>(meta.volumeUUIDs.size()));
  for (const auto& u : meta.volumeUUIDs) w.str(u);
  w.u64(r.bigFileBytes);
  w.u64(r.errors);
  w.f64(r.now);
  w.f64(r.seconds);
  w.u64(r.spotlightHits);

  w.u32(static_cast<uint32_t>(live));
  for (size_t i = 0; i < r.dirs.size(); ++i) {
    if (remap[i] < 0) continue;
    const DirNode& d = r.dirs[i];
    // Children are stored by name and rebuilt from their parent's path on load; totals are
    // rebuilt from the own stats.
    w.str(i == 0 ? d.path : baseName(d.path));
    w.i32(i == 0 ? -1 : remap[static_cast<size_t>(d.parent)]);
    w.u8(static_cast<uint8_t>(d.category));
    w.u8(d.unit ? 1 : 0);
    w.u64(d.own.size);
    w.u64(d.own.files);
    for (int b = 0; b < NBUCKETS; ++b) w.u64(d.own.bucketSize[b]);
    w.u64(d.own.neverOpenedSize);
    w.f64(d.own.lastUsed);
    w.f64(d.mdLastUsed);
    uint32_t nch = 0;
    for (int32_t c : d.children)
      if (c > static_cast<int32_t>(i) && c < static_cast<int32_t>(r.dirs.size()) && remap[static_cast<size_t>(c)] >= 0) ++nch;
    w.u32(nch);
    for (int32_t c : d.children)
      if (c > static_cast<int32_t>(i) && c < static_cast<int32_t>(r.dirs.size()) && remap[static_cast<size_t>(c)] >= 0)
        w.i32(remap[static_cast<size_t>(c)]);
  }

  w.u32(static_cast<uint32_t>(r.bigFiles.size()));
  for (const FileRec& f : r.bigFiles) {
    w.str(f.path);
    w.u64(f.size);
    w.f64(f.lastUsed);
    w.u8(f.neverOpened ? 1 : 0);
  }

  w.u32(static_cast<uint32_t>(r.spotlight.size()));
  for (const auto& kv : r.spotlight) {
    w.str(kv.first);
    w.f64(kv.second);
  }
  w.raw(fnv1a(w.buf.data(), w.buf.size()));
  return std::move(w.buf);
}

bool writeIndex(const std::string& file, const std::string& bytes) {
  if (bytes.empty()) return false;
  std::string dir = file.substr(0, file.find_last_of('/'));
  mkdir(dir.c_str(), 0700);
  std::string tmp = file + ".tmp";
  FILE* fp = fopen(tmp.c_str(), "wb");
  if (!fp) return false;
  bool ok = fwrite(bytes.data(), 1, bytes.size(), fp) == bytes.size();
  ok = fflush(fp) == 0 && ok;
  ok = fsync(fileno(fp)) == 0 && ok;
  ok = fclose(fp) == 0 && ok;
  if (!ok || rename(tmp.c_str(), file.c_str()) != 0) {
    unlink(tmp.c_str());
    return false;
  }
  return true;
}

bool saveIndex(const std::string& file, const std::string& root, const ScanResult& r, const IndexMeta& meta) {
  return writeIndex(file, encodeIndex(root, r, meta));
}

bool loadIndex(const std::string& file, const std::string& root, ScanResult& out, IndexMeta* meta) {
  FILE* fp = fopen(file.c_str(), "rb");
  if (!fp) return false;
  struct stat st;
  if (fstat(fileno(fp), &st) != 0 || st.st_size < static_cast<off_t>(sizeof kMagic + 16 + 8)) {
    fclose(fp);
    return false;
  }
  std::string buf(static_cast<size_t>(st.st_size), '\0');
  bool ok = fread(&buf[0], 1, buf.size(), fp) == buf.size();
  fclose(fp);
  if (!ok) return false;

  size_t body = buf.size() - 8;
  uint64_t stored;
  memcpy(&stored, buf.data() + body, 8);
  if (memcmp(buf.data(), kMagic, sizeof kMagic) != 0 || fnv1a(buf.data(), body) != stored) return false;

  Reader rd{buf.data() + sizeof kMagic, buf.data() + body};
  if (rd.u32() != kVersion) return false;
  rd.u32();
  IndexMeta m;
  m.savedAt = rd.f64();
  if (rd.str() != root) return false;
  m.eventId = rd.raw<uint64_t>();
  uint32_t nuuid = rd.u32();
  if (!rd.ok || nuuid > 64) return false;
  for (uint32_t i = 0; i < nuuid && rd.ok; ++i) m.volumeUUIDs.push_back(rd.str());

  ScanResult r;
  r.bigFileBytes = rd.u64();
  r.errors = rd.u64();
  r.now = rd.f64();
  r.seconds = rd.f64();
  r.spotlightHits = rd.u64();

  uint32_t ndirs = rd.u32();
  if (!rd.ok || ndirs == 0 || ndirs > 50'000'000) return false;
  r.dirs.resize(ndirs);
  for (uint32_t i = 0; i < ndirs && rd.ok; ++i) {
    DirNode& d = r.dirs[i];
    std::string name = rd.str();
    d.parent = rd.i32();
    uint8_t cat = rd.u8();
    d.unit = rd.u8() != 0;
    d.own.size = rd.u64();
    d.own.files = rd.u64();
    for (int b = 0; b < NBUCKETS; ++b) d.own.bucketSize[b] = rd.u64();
    d.own.neverOpenedSize = rd.u64();
    d.own.lastUsed = rd.f64();
    d.mdLastUsed = rd.f64();
    uint32_t nch = rd.u32();
    if (!rd.ok || cat >= NCATEGORIES || nch > ndirs) return false;
    d.category = static_cast<Category>(cat);
    d.children.resize(nch);
    for (uint32_t c = 0; c < nch; ++c) {
      int32_t id = rd.i32();
      if (id <= static_cast<int32_t>(i) || id >= static_cast<int32_t>(ndirs)) return false;
      d.children[c] = id;
    }
    if (i == 0) {
      d.path = std::move(name);
    } else {
      if (d.parent < 0 || d.parent >= static_cast<int32_t>(i) || name.empty()) return false;
      const std::string& pp = r.dirs[d.parent].path;
      d.path.reserve(pp.size() + 1 + name.size());
      d.path = pp;
      if (d.path.empty() || d.path.back() != '/') d.path += '/';
      d.path += name;
    }
  }

  uint32_t nbig = rd.u32();
  if (!rd.ok || nbig > 50'000'000) return false;
  r.bigFiles.resize(nbig);
  for (uint32_t i = 0; i < nbig && rd.ok; ++i) {
    FileRec& f = r.bigFiles[i];
    f.path = rd.str();
    f.size = rd.u64();
    f.lastUsed = rd.f64();
    f.neverOpened = rd.u8() != 0;
  }

  uint32_t nspot = rd.u32();
  if (!rd.ok || nspot > 100'000'000) return false;
  r.spotlight.reserve(nspot);
  for (uint32_t i = 0; i < nspot && rd.ok; ++i) {
    std::string p = rd.str();
    double t = rd.f64();
    r.spotlight.emplace(std::move(p), t);
  }
  if (!rd.ok || rd.p != rd.end) return false;

  rollup(r);
  out = std::move(r);
  if (meta) *meta = std::move(m);
  return true;
}

}  // namespace stale
