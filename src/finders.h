// Cleanup finders: things that take space and are safe to review for the Trash but that a
// folder-name rule can't spot — identical copies, data left behind by uninstalled apps, old
// device backups, downloads that were installed long ago, and the Trash itself.
#pragma once

#include <atomic>
#include <cstdint>
#include <string>
#include <vector>

#include "scan.h"

namespace stale {

struct Found {
  std::string path;
  uint64_t size = 0;
  double lastUsed = 0;   // 0 = unknown / never
  bool isDir = false;
  bool preselect = false;  // suggested for the Trash
  std::string note;        // one line saying why it is listed
  int group = -1;          // duplicates: copies of the same content share a group
};

struct FinderResult {
  std::vector<Found> items;
  uint64_t suggested = 0;  // bytes of the preselected items
  uint64_t total = 0;      // bytes of everything listed
  bool unreadable = false;  // the folder searched is protected (needs Full Disk Access), so nothing can be said
};

struct FinderOptions {
  const ScanResult* index = nullptr;  // for sizes and last-used dates
  std::string home;
  double now = 0;
  std::atomic<bool>* cancel = nullptr;
  std::atomic<uint64_t>* progress = nullptr;  // duplicates: bytes hashed so far
  std::atomic<uint64_t>* progressTotal = nullptr;
};

// Files >= minBytes with identical content (size, then SHA-256 of the first 64 KB, then of
// the whole file). System, application and bundle contents are skipped, and so are hard
// links to the same data. All copies but the most recently used are preselected.
FinderResult findDuplicates(const FinderOptions& o, uint64_t minBytes = 4ull << 20);

// Per-app folders in ~/Library named after a bundle identifier for which no application is
// installed anymore, plus iOS / iPadOS device backups (preselected when older than a year).
FinderResult findLeftovers(const FinderOptions& o);

// Entries of ~/Downloads not touched for olderThanDays. Installers whose application is
// already in an Applications folder are preselected; everything else is listed for review.
FinderResult findOldDownloads(const FinderOptions& o, double olderThanDays = 30);

// Files that AI coding agents leave behind: worktrees (Codex, Cursor, Claude Code, Conductor),
// their caches, logs and old transcripts, local models, and folders of agent apps that are no
// longer installed. Worktrees are preselected only when untouched for 14 days with no
// uncommitted changes and HEAD on a branch; models are never preselected.
FinderResult findAgentFiles(const FinderOptions& o);

// Contents of the user's Trash.
FinderResult findTrash(const FinderOptions& o);

}  // namespace stale
