#pragma once
#include <dispatch/dispatch.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "scan.h"

namespace stale {

struct FsBatch {
  std::vector<RefreshRequest> changes;
  uint64_t lastEventId = 0;  // id of the newest event in this batch
  bool historyDone = false;  // the replay of events since `sinceId` is complete
  bool needFullScan = false;  // ids wrapped, root replaced, or events lost: the index can't be patched
};

// FSEvents UUIDs of the volumes that make up `root` (root's own device first). Empty strings for
// volumes without persistent event ids; changes when fseventsd's database is rebuilt.
std::vector<std::string> volumeUUIDs(const std::string& root);
uint64_t currentEventId();

// Delivers folders changed below `root` to `cb` on `queue`, first everything since `sinceId`
// (0 = nothing, live only) then live with `latency` seconds of coalescing.
class FsWatcher {
 public:
  FsWatcher(const std::string& root, uint64_t sinceId, double latency, dispatch_queue_t queue,
            std::function<void(FsBatch)> cb);
  ~FsWatcher();
  FsWatcher(const FsWatcher&) = delete;
  FsWatcher& operator=(const FsWatcher&) = delete;
  bool running() const;

  struct State;

 private:
  std::shared_ptr<State> st_;
};

}  // namespace stale
