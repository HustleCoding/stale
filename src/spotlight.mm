#import <CoreServices/CoreServices.h>
#import <Foundation/Foundation.h>

#include "scan.h"

namespace stale {

std::unordered_map<std::string, double> spotlightLastUsed(const std::string& root) {
  std::unordered_map<std::string, double> out;
  @autoreleasepool {
    NSString* rootStr = [NSFileManager.defaultManager stringWithFileSystemRepresentation:root.c_str()
                                                                                 length:root.size()];
    if (!rootStr) return out;
    NSString* q = @"kMDItemLastUsedDate > $time.iso(1970-01-02T00:00:00Z)";
    MDQueryRef query = MDQueryCreate(kCFAllocatorDefault, (__bridge CFStringRef)q, NULL, NULL);
    if (!query) return out;
    NSArray* scope = @[ rootStr ];
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
  }
  return out;
}

}  // namespace stale
