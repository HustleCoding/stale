#import <CoreServices/CoreServices.h>
#import <Foundation/Foundation.h>

#include <sys/stat.h>

#include <atomic>
#include <mutex>

#include "fsevents.h"

namespace stale {

namespace {

std::string uuidForDevice(dev_t dev) {
  CFUUIDRef u = FSEventsCopyUUIDForDevice(dev);
  if (!u) return {};
  CFStringRef s = CFUUIDCreateString(kCFAllocatorDefault, u);
  CFRelease(u);
  if (!s) return {};
  std::string out = ((__bridge NSString*)s).UTF8String ?: "";
  CFRelease(s);
  return out;
}

}  // namespace

std::vector<std::string> volumeUUIDs(const std::string& root) {
  std::vector<std::string> out;
  struct stat st;
  if (::stat(root.c_str(), &st) != 0) return out;
  out.push_back(uuidForDevice(st.st_dev));
  // The system snapshot and the data volume are one disk from the user's point of view.
  struct stat sys, data;
  if (::stat("/", &sys) == 0 && ::stat("/System/Volumes/Data", &data) == 0 &&
      (st.st_dev == sys.st_dev || st.st_dev == data.st_dev) && data.st_dev != st.st_dev)
    out.push_back(uuidForDevice(data.st_dev));
  return out;
}

uint64_t currentEventId() { return FSEventsGetCurrentEventId(); }

struct FsWatcher::State {
  FSEventStreamRef stream = nullptr;
  std::function<void(FsBatch)> cb;
  std::string root;
  std::atomic<bool> alive{true};
  bool historyDone = false;
};

namespace {

void streamCallback(ConstFSEventStreamRef, void* info, size_t n, void* paths, const FSEventStreamEventFlags flags[],
                    const FSEventStreamEventId ids[]) {
  auto* holder = static_cast<std::shared_ptr<FsWatcher::State>*>(info);
  std::shared_ptr<FsWatcher::State> st = *holder;
  if (!st || !st->alive.load()) return;
  const char** cpaths = static_cast<const char**>(paths);
  FsBatch b;
  b.changes.reserve(n);
  for (size_t i = 0; i < n; ++i) {
    FSEventStreamEventFlags f = flags[i];
    if (f & kFSEventStreamEventFlagHistoryDone) {
      b.historyDone = true;
      st->historyDone = true;
      continue;
    }
    if (f & (kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged)) b.needFullScan = true;
    // Dropped events come with MustScanSubDirs on the affected path; the planner turns a
    // whole-root re-read into a full scan.
    bool subtree = (f & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped |
                         kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagMount |
                         kFSEventStreamEventFlagUnmount)) != 0;
    std::string p = cpaths[i] ? cpaths[i] : "";
    if (p.empty()) continue;
    if (f & kFSEventStreamEventFlagItemIsFile) {
      // Only with FileEvents, which we don't request; be safe and use the folder.
      size_t slash = p.find_last_of('/');
      p = slash == 0 ? "/" : p.substr(0, slash);
    }
    b.changes.push_back(RefreshRequest{std::move(p), subtree});
    if (ids[i] > b.lastEventId) b.lastEventId = ids[i];
  }
  if (b.changes.empty() && !b.historyDone && !b.needFullScan) return;
  st->cb(std::move(b));
}

const void* retainHolder(const void* info) { return info; }
void releaseHolder(const void* info) { delete static_cast<const std::shared_ptr<FsWatcher::State>*>(info); }

}  // namespace

FsWatcher::FsWatcher(const std::string& root, uint64_t sinceId, double latency, dispatch_queue_t queue,
                     std::function<void(FsBatch)> cb)
    : st_(std::make_shared<State>()) {
  st_->cb = std::move(cb);
  st_->root = root;
  @autoreleasepool {
    NSString* r = [NSFileManager.defaultManager stringWithFileSystemRepresentation:root.c_str() length:root.size()];
    if (!r) return;
    FSEventStreamContext ctx;
    memset(&ctx, 0, sizeof ctx);
    ctx.info = new std::shared_ptr<State>(st_);
    ctx.retain = retainHolder;
    ctx.release = releaseHolder;
    NSArray* paths = @[ r ];
    FSEventStreamCreateFlags flags = kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer;
    FSEventStreamEventId since = sinceId ? sinceId : kFSEventStreamEventIdSinceNow;
    st_->stream = FSEventStreamCreate(kCFAllocatorDefault, streamCallback, &ctx, (__bridge CFArrayRef)paths, since,
                                      latency, flags);
    if (!st_->stream) {
      releaseHolder(ctx.info);
      return;
    }
    FSEventStreamSetDispatchQueue(st_->stream, queue);
    if (!FSEventStreamStart(st_->stream)) {
      FSEventStreamInvalidate(st_->stream);
      FSEventStreamRelease(st_->stream);
      st_->stream = nullptr;
    }
  }
}

FsWatcher::~FsWatcher() {
  st_->alive.store(false);
  if (st_->stream) {
    FSEventStreamStop(st_->stream);
    FSEventStreamInvalidate(st_->stream);
    FSEventStreamRelease(st_->stream);
    st_->stream = nullptr;
  }
}

bool FsWatcher::running() const { return st_->stream != nullptr; }

}  // namespace stale
