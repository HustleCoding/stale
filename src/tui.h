// `stale tui`: full-screen terminal browser (the Omarchy / Linux front end).
#pragma once

#include <string>

namespace stale {

struct TuiOptions {
  std::string root, home;
  int threads = 0;
  bool atime = false, spotlight = true;
};

int runTui(const TuiOptions& o);

}  // namespace stale
