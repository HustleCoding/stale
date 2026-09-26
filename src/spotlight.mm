#import <CoreServices/CoreServices.h>
#import <Foundation/Foundation.h>

#include "scan.h"

namespace stale {

namespace {

std::unordered_map<std::string, double> runQuery(NSArray<NSString*>* scope) {
  std::unordered_map<std::string, double> out;
  NSString* q = @"kMDItemLastUsedDate > $time.iso(1970-01-02T00:00:00Z)";
  MDQueryRef query = MDQueryCreate(kCFAllocatorDefault, (__bridge CFStringRef)q, NULL, NULL);
  if (!query) return out;
  MDQuerySetSearchScope(query, (__bridge CFArrayRef)scope, 0);
  if (!MDQueryExecute(query, kMDQuerySynchronous)) {
    CFRelease(query);
    return out;
  }
  CFIndex n = MDQueryGetResultCount(query);
  out.reserve(static_cast<size_t>(n));
  NSString* pathKey = @"kMDItemPath";
  NSString* usedKey = @"kMDItemLastUsedDate";
  NSArray* attrs = @[ pathKey, usedKey ];
  for (CFIndex i = 0; i < n; ++i) {
    MDItemRef item = (MDItemRef)MDQueryGetResultAtIndex(query, i);
    if (!item) continue;
    NSDictionary* d = CFBridgingRelease(MDItemCopyAttributes(item, (__bridge CFArrayRef)attrs));
    NSString* path = d[pathKey];
    NSDate* used = d[usedKey];
    if (!path || !used) continue;
    std::string p = path.UTF8String;
    // Spotlight reports firmlink targets (/System/Volumes/Data/Users/...) for paths on the data volume.
    static const std::string kDataVol = "/System/Volumes/Data/";
    if (p.compare(0, kDataVol.size(), kDataVol) == 0) p.erase(0, kDataVol.size() - 1);
    out[p] = used.timeIntervalSince1970;
  }
  CFRelease(query);
  return out;
}

NSString* fsString(const std::string& p) {
  return [NSFileManager.defaultManager stringWithFileSystemRepresentation:p.c_str() length:p.size()];
}

}  // namespace

std::unordered_map<std::string, double> spotlightLastUsed(const std::string& root) {
  @autoreleasepool {
    NSString* rootStr = fsString(root);
    if (!rootStr) return {};
    return runQuery(@[ rootStr ]);
  }
}

std::unordered_map<std::string, double> spotlightLastUsedIn(const std::vector<std::string>& dirs) {
  std::unordered_map<std::string, double> out;
  // Scopes are OR-ed; keep each query to a modest list so mdworker doesn't choke on huge ones.
  const size_t kChunk = 64;
  for (size_t i = 0; i < dirs.size(); i += kChunk) {
    @autoreleasepool {
      NSMutableArray<NSString*>* scope = [NSMutableArray new];
      for (size_t j = i; j < dirs.size() && j < i + kChunk; ++j)
        if (NSString* s = fsString(dirs[j])) [scope addObject:s];
      if (!scope.count) continue;
      auto part = runQuery(scope);
      if (out.empty()) out = std::move(part);
      else for (auto& kv : part) out[kv.first] = kv.second;
    }
  }
  return out;
}

}  // namespace stale
