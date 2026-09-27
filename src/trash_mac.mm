#include "trash.h"

#import <Foundation/Foundation.h>

namespace stale {

bool moveToTrash(const std::string& path, std::string* error) {
  @autoreleasepool {
    NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
    NSError* err = nil;
    if ([[NSFileManager defaultManager] trashItemAtURL:url resultingItemURL:nil error:&err]) return true;
    if (error) *error = err.localizedDescription.UTF8String ?: "unknown error";
    return false;
  }
}

}  // namespace stale
