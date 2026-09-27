// Linux stand-in for Spotlight's "last opened" dates: the freedesktop recently-used list
// (~/.local/share/recently-used.xbel) that GTK/Qt apps and file managers write when a file
// is opened. Paths that aren't in it fall back to modification times, as on macOS.
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <fstream>
#include <sstream>

#include "scan.h"

namespace stale {
namespace {

std::string xbelPath() {
  const char* xdg = getenv("XDG_DATA_HOME");
  if (xdg && xdg[0] == '/') return std::string(xdg) + "/recently-used.xbel";
  const char* h = getenv("HOME");
  return std::string(h ? h : "") + "/.local/share/recently-used.xbel";
}

// "2024-05-01T10:20:30.123456Z" -> unix seconds, 0 when malformed.
double parseIso(const std::string& s) {
  struct tm tm = {};
  if (sscanf(s.c_str(), "%4d-%2d-%2dT%2d:%2d:%2d", &tm.tm_year, &tm.tm_mon, &tm.tm_mday, &tm.tm_hour, &tm.tm_min,
             &tm.tm_sec) != 6)
    return 0;
  tm.tm_year -= 1900;
  tm.tm_mon -= 1;
  time_t t = timegm(&tm);
  return t < 0 ? 0 : static_cast<double>(t);
}

int hexVal(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

// file:///a%20b -> /a b; "" for anything that isn't a local file URI.
std::string uriToPath(const std::string& uri) {
  static const std::string kScheme = "file://";
  if (uri.compare(0, kScheme.size(), kScheme) != 0) return "";
  std::string out;
  for (size_t i = kScheme.size(); i < uri.size(); ++i) {
    if (uri[i] == '%' && i + 2 < uri.size() && hexVal(uri[i + 1]) >= 0 && hexVal(uri[i + 2]) >= 0) {
      out += static_cast<char>(hexVal(uri[i + 1]) * 16 + hexVal(uri[i + 2]));
      i += 2;
    } else {
      out += uri[i];
    }
  }
  if (out.empty() || out[0] != '/') return "";
  while (out.size() > 1 && out.back() == '/') out.pop_back();
  return out;
}

std::string xmlUnescape(const std::string& s) {
  std::string o;
  for (size_t i = 0; i < s.size(); ++i) {
    if (s[i] != '&') { o += s[i]; continue; }
    size_t semi = s.find(';', i);
    if (semi == std::string::npos) { o += s[i]; continue; }
    std::string ent = s.substr(i + 1, semi - i - 1);
    if (ent == "amp") o += '&';
    else if (ent == "lt") o += '<';
    else if (ent == "gt") o += '>';
    else if (ent == "quot") o += '"';
    else if (ent == "apos") o += '\'';
    else { o += s[i]; continue; }
    i = semi;
  }
  return o;
}

std::string attr(const std::string& tag, const char* name) {
  std::string key = std::string(" ") + name + "=\"";
  size_t p = tag.find(key);
  if (p == std::string::npos) return "";
  p += key.size();
  size_t q = tag.find('"', p);
  return q == std::string::npos ? "" : tag.substr(p, q - p);
}

bool within(const std::string& p, const std::string& dir) {
  if (dir == "/" || p == dir) return true;
  return p.size() > dir.size() && p.compare(0, dir.size(), dir) == 0 && p[dir.size()] == '/';
}

template <class Keep>
std::unordered_map<std::string, double> readRecent(Keep keep) {
  std::unordered_map<std::string, double> out;
  std::ifstream f(xbelPath());
  if (!f) return out;
  std::stringstream ss;
  ss << f.rdbuf();
  const std::string xml = ss.str();
  size_t pos = 0;
  while ((pos = xml.find("<bookmark ", pos)) != std::string::npos) {
    size_t end = xml.find('>', pos);
    if (end == std::string::npos) break;
    std::string tag = xml.substr(pos, end - pos);
    pos = end;
    std::string path = uriToPath(xmlUnescape(attr(tag, "href")));
    if (path.empty() || !keep(path)) continue;
    double t = std::max(parseIso(attr(tag, "visited")), parseIso(attr(tag, "modified")));
    if (t <= 0) continue;
    double& slot = out[path];
    slot = std::max(slot, t);
  }
  return out;
}

}  // namespace

std::unordered_map<std::string, double> spotlightLastUsed(const std::string& root) {
  return readRecent([&](const std::string& p) { return within(p, root); });
}

std::unordered_map<std::string, double> spotlightLastUsedIn(const std::vector<std::string>& dirs) {
  return readRecent([&](const std::string& p) {
    for (const std::string& d : dirs)
      if (within(p, d)) return true;
    return false;
  });
}

}  // namespace stale
