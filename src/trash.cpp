#include "trash.h"

#include <fcntl.h>
#include <ftw.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cctype>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>

namespace stale {
namespace {

bool removeTree(const std::string& path, std::string* error) {
  struct stat st;
  if (lstat(path.c_str(), &st) != 0) {
    if (errno == ENOENT) return true;
    if (error) *error = strerror(errno);
    return false;
  }
  int rc = S_ISDIR(st.st_mode)
               ? nftw(path.c_str(),
                      [](const char* p, const struct stat*, int, struct FTW*) { return ::remove(p) == 0 ? 0 : -1; }, 64,
                      FTW_DEPTH | FTW_PHYS)
               : ::unlink(path.c_str());
  if (rc != 0 && error) *error = strerror(errno);
  return rc == 0;
}

#ifndef __APPLE__
std::string homeTrash() {
  const char* xdg = getenv("XDG_DATA_HOME");
  if (xdg && xdg[0] == '/') return std::string(xdg) + "/Trash";
  const char* h = getenv("HOME");
  return std::string(h ? h : "") + "/.local/share/Trash";
}

bool mkdirs(const std::string& dir, mode_t mode) {
  struct stat st;
  if (stat(dir.c_str(), &st) == 0) return S_ISDIR(st.st_mode);
  size_t slash = dir.find_last_of('/');
  if (slash != std::string::npos && slash > 0 && !mkdirs(dir.substr(0, slash), 0700)) return false;
  return mkdir(dir.c_str(), mode) == 0 || errno == EEXIST;
}

std::string urlEncodePath(const std::string& p) {
  static const char* hex = "0123456789ABCDEF";
  std::string o;
  for (unsigned char c : p) {
    if (isalnum(c) || strchr("/-_.~", c)) o += static_cast<char>(c);
    else { o += '%'; o += hex[c >> 4]; o += hex[c & 15]; }
  }
  return o;
}

std::string parentOf(const std::string& p) {
  size_t s = p.find_last_of('/');
  return s == std::string::npos || s == 0 ? "/" : p.substr(0, s);
}

// Top directory of the mount holding path (the spec's $topdir).
std::string mountTop(const std::string& path, dev_t dev) {
  std::string cur = path;
  while (cur != "/") {
    std::string up = parentOf(cur);
    struct stat st;
    if (lstat(up.c_str(), &st) != 0 || st.st_dev != dev) return cur;
    cur = up;
  }
  return "/";
}
#endif

}  // namespace

std::string trashFilesDir(const std::string& home) {
#ifdef __APPLE__
  return home + "/.Trash";
#else
  const char* xdg = getenv("XDG_DATA_HOME");
  if (xdg && xdg[0] == '/') return std::string(xdg) + "/Trash/files";
  return home + "/.local/share/Trash/files";
#endif
}

#ifndef __APPLE__
// freedesktop.org Trash specification 1.0: the home trash for files on the same file system
// as it, $topdir/.Trash-$uid for everything else.
bool moveToTrash(const std::string& path, std::string* error) {
  auto fail = [&](const std::string& why) {
    if (error) *error = why;
    return false;
  };
  struct stat st;
  if (lstat(path.c_str(), &st) != 0) return fail(strerror(errno));

  std::string trash = homeTrash(), infoPath;
  if (!mkdirs(trash + "/files", 0700) || !mkdirs(trash + "/info", 0700))
    return fail("cannot create " + trash);
  struct stat tst;
  bool relative = false;
  std::string top;
  if (stat(trash.c_str(), &tst) != 0 || tst.st_dev != st.st_dev) {
    top = mountTop(path, st.st_dev);
    trash = (top == "/" ? "" : top) + "/.Trash-" + std::to_string(getuid());
    if (!mkdirs(trash + "/files", 0700) || !mkdirs(trash + "/info", 0700))
      return fail("no Trash on this drive (cannot create " + trash + ")");
    relative = true;
  }

  std::string base = path.substr(path.find_last_of('/') + 1), name = base;
  int fd = -1;
  for (int i = 2; i < 10000; ++i) {
    infoPath = trash + "/info/" + name + ".trashinfo";
    fd = open(infoPath.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd >= 0) {
      struct stat existing;
      if (lstat((trash + "/files/" + name).c_str(), &existing) != 0) break;
      close(fd);
      unlink(infoPath.c_str());
      fd = -1;
    } else if (errno != EEXIST) {
      return fail(strerror(errno));
    }
    name = base + "." + std::to_string(i);
  }
  if (fd < 0) return fail("too many items with this name in the Trash");

  char when[32];
  time_t now = time(nullptr);
  struct tm tm;
  strftime(when, sizeof when, "%Y-%m-%dT%H:%M:%S", localtime_r(&now, &tm));
  std::string original = !relative ? path : top == "/" ? path.substr(1) : path.substr(top.size() + 1);
  std::string info = "[Trash Info]\nPath=" + urlEncodePath(original) + "\nDeletionDate=" + when + "\n";
  bool wrote = write(fd, info.data(), info.size()) == static_cast<ssize_t>(info.size());
  close(fd);
  if (!wrote || rename(path.c_str(), (trash + "/files/" + name).c_str()) != 0) {
    std::string why = wrote ? strerror(errno) : "cannot write Trash info";
    unlink(infoPath.c_str());
    return fail(why);
  }
  return true;
}
#endif

bool deleteFromTrash(const std::string& path, std::string* error) {
  if (!removeTree(path, error)) return false;
#ifndef __APPLE__
  // .../Trash/files/<name> -> .../Trash/info/<name>.trashinfo
  size_t slash = path.find_last_of('/');
  std::string dir = path.substr(0, slash);
  if (dir.size() > 6 && dir.compare(dir.size() - 6, 6, "/files") == 0)
    ::unlink((dir.substr(0, dir.size() - 6) + "/info/" + path.substr(slash + 1) + ".trashinfo").c_str());
#endif
  return true;
}

}  // namespace stale
