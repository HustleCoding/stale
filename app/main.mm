// Stale.app — a native window over the stale scanner.
// Sidebar of views (Overview, All folders, Safe to delete, Forgotten, Big unused files, Apps),
// a folder tree with size / last-used / what-is-it columns, and a "Move to Trash" action.
// The whole disk is indexed once and kept in ~/Library/Application Support/Stale; the app
// opens from that index, catches up on what changed meanwhile through FSEvents and keeps
// following the disk while open. Everything goes to the Trash, nothing is deleted outright.
#import <Cocoa/Cocoa.h>
#import <Quartz/Quartz.h>

#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <memory>
#include <string>
#include <unordered_set>
#include <vector>

#include "../src/finders.h"
#include "../src/fsevents.h"
#include "../src/index.h"
#include "../src/scan.h"

using namespace stale;

// ───────────────────────────── formatting ─────────────────────────────

static NSString* fmtBytes(uint64_t b) {
  static NSByteCountFormatter* f = [] {
    NSByteCountFormatter* x = [NSByteCountFormatter new];
    x.countStyle = NSByteCountFormatterCountStyleFile;
    x.allowsNonnumericFormatting = NO;
    return x;
  }();
  return [f stringFromByteCount:(long long)b];
}

static NSString* fmtCount(uint64_t n, NSString* noun) {
  static NSNumberFormatter* f = [] {
    NSNumberFormatter* x = [NSNumberFormatter new];
    x.numberStyle = NSNumberFormatterDecimalStyle;
    return x;
  }();
  return [NSString stringWithFormat:@"%@ %@%@", [f stringFromNumber:@(n)], noun, n == 1 ? @"" : @"s"];
}

// "Today", "3 days ago", "2 months ago", "1.5 years ago"
static NSString* fmtAgo(double t, double now) {
  if (t <= 0) return @"Never";
  double d = (now - t) / 86400.0;
  if (d < 1) return @"Today";
  if (d < 2) return @"Yesterday";
  if (d < 7) return [NSString stringWithFormat:@"%.0f days ago", d];
  if (d < 30) { int w = (int)lround(d / 7); return w == 1 ? @"1 week ago" : [NSString stringWithFormat:@"%d weeks ago", w]; }
  if (d < 365) { int m = std::max(1, (int)lround(d / 30.44)); return m == 1 ? @"1 month ago" : [NSString stringWithFormat:@"%d months ago", m]; }
  double y = d / 365.25;
  if (y < 1.05) return @"1 year ago";
  if (y < 10) return [NSString stringWithFormat:@"%.1f years ago", y];
  return [NSString stringWithFormat:@"%.0f years ago", y];
}

// "just now", "12 min ago", "3 h ago", "yesterday", "5 days ago", "12 Sep 2026"
static NSString* fmtIndexedAgo(double t, double now) {
  double s = now - t;
  if (s < 90) return @"just now";
  if (s < 3600) return [NSString stringWithFormat:@"%.0f min ago", s / 60];
  if (s < 86400) return [NSString stringWithFormat:@"%.0f h ago", s / 3600];
  if (s < 2 * 86400) return @"yesterday";
  if (s < 14 * 86400) return [NSString stringWithFormat:@"%.0f days ago", s / 86400];
  return [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:t]
                                        dateStyle:NSDateFormatterMediumStyle
                                        timeStyle:NSDateFormatterNoStyle];
}

static NSString* fmtDateTime(double t) {
  return [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:t]
                                        dateStyle:NSDateFormatterMediumStyle
                                        timeStyle:NSDateFormatterShortStyle];
}

static double unixNow() { return [NSDate date].timeIntervalSince1970; }

// ───────────────────────────── design tokens ─────────────────────────────

static NSColor* hex(uint32_t rgb) {
  return [NSColor colorWithSRGBRed:((rgb >> 16) & 255) / 255.0
                             green:((rgb >> 8) & 255) / 255.0
                              blue:(rgb & 255) / 255.0
                             alpha:1];
}

// One colour that flips with the window appearance.
static NSColor* dyn(NSString* name, uint32_t light, uint32_t dark) {
  NSColor* l = hex(light);
  NSColor* d = hex(dark);
  return [NSColor colorWithName:name dynamicProvider:^NSColor*(NSAppearance* a) {
    NSAppearanceName best = [a bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
    return [best isEqual:NSAppearanceNameDarkAqua] ? d : l;
  }];
}

static NSColor* kBucketColors[NBUCKETS + 1];  // + never opened
static NSString* kBucketLabels[NBUCKETS + 1] = {@"This week", @"This month", @"Last 6 months", @"6–12 months",
                                                @"Over a year", @"Never opened"};
static const int kRingPalette = 12;
static NSColor* kRingColors[kRingPalette];
static NSColor* kRingOther;

static void initColors() {
  kBucketColors[HOT] = dyn(@"hot", 0x22C55E, 0x4ADE80);
  kBucketColors[WARM] = dyn(@"warm", 0x14B8A6, 0x2DD4BF);
  kBucketColors[COLD] = dyn(@"cold", 0x3B82F6, 0x60A5FA);
  kBucketColors[STALE] = dyn(@"stale", 0xF59E0B, 0xFBBF24);
  kBucketColors[FROZEN] = dyn(@"frozen", 0xF43F5E, 0xFB7185);
  kBucketColors[NBUCKETS] = dyn(@"never", 0x94A3B8, 0x64748B);
  const uint32_t light[kRingPalette] = {0x6366F1, 0x0EA5E9, 0x14B8A6, 0x10B981, 0x84CC16, 0xF59E0B,
                                        0xF97316, 0xF43F5E, 0xEC4899, 0xA855F7, 0x3B82F6, 0x06B6D4};
  const uint32_t dark[kRingPalette] = {0x818CF8, 0x38BDF8, 0x2DD4BF, 0x34D399, 0xA3E635, 0xFBBF24,
                                       0xFB923C, 0xFB7185, 0xF472B6, 0xC084FC, 0x60A5FA, 0x22D3EE};
  for (int i = 0; i < kRingPalette; ++i)
    kRingColors[i] = dyn([NSString stringWithFormat:@"ring%d", i], light[i], dark[i]);
  kRingOther = dyn(@"ringOther", 0xCBD5E1, 0x475569);
}

static NSColor* bucketColor(double lastUsed, double now) {
  if (lastUsed <= 0) return kBucketColors[NBUCKETS];
  return kBucketColors[bucketFor(lastUsed, now)];
}

static NSColor* surfaceFill() { return dyn(@"surface", 0xFFFFFF, 0x2A2A2E); }
static NSColor* surfaceStroke() { return dyn(@"surfaceStroke", 0xE6E6EA, 0x3A3A40); }

static NSFont* roundedFont(CGFloat size, NSFontWeight w) {
  NSFont* base = [NSFont systemFontOfSize:size weight:w];
  NSFontDescriptor* d = [base.fontDescriptor fontDescriptorWithDesign:NSFontDescriptorSystemDesignRounded];
  NSFont* f = d ? [NSFont fontWithDescriptor:d size:size] : base;
  // Tabular digits so sizes don't jiggle as they change.
  NSFontDescriptor* tab = [f.fontDescriptor fontDescriptorByAddingAttributes:@{
    NSFontFeatureSettingsAttribute : @[ @{
      NSFontFeatureTypeIdentifierKey : @(kNumberSpacingType),
      NSFontFeatureSelectorIdentifierKey : @(kMonospacedNumbersSelector)
    } ]
  }];
  return [NSFont fontWithDescriptor:tab size:size] ?: f;
}
static NSFont* monoDigits(CGFloat size, NSFontWeight w) { return [NSFont monospacedDigitSystemFontOfSize:size weight:w]; }

static NSString* categoryTitle(stale::Category c) {
  switch (c) {
    case CAT_NODE_MODULES: return @"npm packages";
    case CAT_BUILD: return @"Build output";
    case CAT_VENV: return @"Python environment";
    case CAT_CACHE: return @"Cache";
    case CAT_XCODE: return @"Xcode data";
    case CAT_DOCKER: return @"Docker data";
    case CAT_DOWNLOADS: return @"Downloads";
    case CAT_TRASH: return @"Trash";
    case CAT_GIT: return @"Git history";
    case CAT_APP: return @"Application";
    case CAT_BUNDLE: return @"Package";
    default: return @"";
  }
}

static NSString* categoryHint(stale::Category c) {
  switch (c) {
    case CAT_NODE_MODULES: return @"npm install brings it back";
    case CAT_BUILD: return @"rebuilt next time you build";
    case CAT_VENV: return @"recreate with python -m venv";
    case CAT_CACHE: return @"apps recreate it automatically";
    case CAT_XCODE: return @"Xcode regenerates it";
    case CAT_DOCKER: return @"safe if you don't need the images";
    case CAT_TRASH: return @"empty the Trash in Finder";
    case CAT_GIT: return @"history of this repo";
    default: return @"";
  }
}

static std::string std_str(NSString* s) { return s ? std::string(s.UTF8String) : std::string(); }
static NSString* ns_str(const std::string& s) {
  return [NSFileManager.defaultManager stringWithFileSystemRepresentation:s.c_str() length:s.size()] ?: @"";
}
static NSString* displayName(NSString* path) {
  NSString* n = [NSFileManager.defaultManager displayNameAtPath:path];
  return n.length ? n : path.lastPathComponent;
}
static NSImage* symbol(NSString* name, CGFloat pt, NSFontWeight w = NSFontWeightRegular) {
  NSImage* i = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
  return [i imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:pt weight:w]];
}
static NSTextField* label(NSString* s, CGFloat size, NSFontWeight w, NSColor* color) {
  NSTextField* l = [NSTextField labelWithString:s];
  l.font = [NSFont systemFontOfSize:size weight:w];
  l.textColor = color;
  l.maximumNumberOfLines = 1;
  l.lineBreakMode = NSLineBreakByTruncatingTail;
  return l;
}
// Adds `v` to `to` filling it with the given insets.
static void pin(NSView* v, NSView* to, NSEdgeInsets in) {
  v.translatesAutoresizingMaskIntoConstraints = NO;
  if (v.superview != to) [to addSubview:v];
  [NSLayoutConstraint activateConstraints:@[
    [v.leadingAnchor constraintEqualToAnchor:to.leadingAnchor constant:in.left],
    [v.trailingAnchor constraintEqualToAnchor:to.trailingAnchor constant:-in.right],
    [v.topAnchor constraintEqualToAnchor:to.topAnchor constant:in.top],
    [v.bottomAnchor constraintEqualToAnchor:to.bottomAnchor constant:-in.bottom],
  ]];
}
static void fixSize(NSView* v, CGFloat w, CGFloat h) {
  if (w > 0) [v.widthAnchor constraintEqualToConstant:w].active = YES;
  if (h > 0) [v.heightAnchor constraintEqualToConstant:h].active = YES;
}

// ───────────────────────────── model ─────────────────────────────

@interface Item : NSObject <QLPreviewItem>
@property(nonatomic, copy) NSString* name;
@property(nonatomic, copy) NSString* path;
@property(nonatomic) uint64_t size;
@property(nonatomic) uint64_t files;
@property(nonatomic) double lastUsed;   // 0 = never
@property(nonatomic) double installed;  // apps: bundle mtime
@property(nonatomic) BOOL isDir;
@property(nonatomic) BOOL never;        // created and never opened/modified since
@property(nonatomic) BOOL isApp;
@property(nonatomic) stale::Category category;
@property(nonatomic) int32_t dirId;     // index into ScanResult::dirs, -1 for files / foreign apps
@property(nonatomic, weak) Item* parent;
@property(nonatomic, strong) NSMutableArray<Item*>* children;  // nil until loaded
@property(nonatomic, strong) NSImage* icon;
// finder results
@property(nonatomic, copy) NSString* note;  // why it is listed
@property(nonatomic) int group;             // duplicates: copies of one file share a group, -1 otherwise
@property(nonatomic) BOOL suggested;        // preselected for the Trash
@end
@implementation Item
- (instancetype)init {
  if ((self = [super init])) _group = -1;
  return self;
}
// Quick Look
- (NSURL*)previewItemURL { return [NSURL fileURLWithPath:_path]; }
- (NSString*)previewItemTitle { return _name; }
@end

// Where the Apps view gets its bundles from: a subtree of the main index when the scanned
// root contains /Applications, otherwise a small separate scan of that folder.
struct AppSource {
  std::shared_ptr<ScanResult> r;
  int32_t dirId = -1;
  bool inMain = false;
};
struct AppSources {
  AppSource s[2];
};

struct Model {
  std::shared_ptr<ScanResult> result;
  AppSources apps;
  double now = 0;        // wall clock when the model was installed; ages are relative to this
  double indexedAt = 0;  // when the scan behind `result` finished
  IndexMeta meta;        // FSEvents position the model is current to
};

// Resolve both app folders against `main`; scans (and caches) the ones it doesn't cover.
static AppSources resolveApps(const std::shared_ptr<ScanResult>& main, const std::string& home,
                              std::atomic<bool>* cancel) {
  AppSources out;
  const std::string roots[2] = {"/Applications", home + "/Applications"};
  for (int i = 0; i < 2; ++i) {
    AppSource& s = out.s[i];
    int32_t id = main ? findDir(*main, roots[i]) : -1;
    if (id >= 0) {
      s.r = main;
      s.dirId = id;
      s.inMain = true;
      continue;
    }
    struct stat st;
    if (::stat(roots[i].c_str(), &st) != 0) continue;
    auto r = std::make_shared<ScanResult>();
    if (loadIndex(indexPath(roots[i]), roots[i], *r, nullptr)) {
      s.r = r;
      s.dirId = 0;
      continue;
    }
    if (cancel && cancel->load()) continue;
    ScanOptions ao;
    ao.root = roots[i];
    ao.cancel = cancel;
    *r = scan(ao);
    if (cancel && cancel->load()) continue;
    if (!r->dirs.empty()) {
      IndexMeta meta;
      meta.savedAt = unixNow();
      saveIndex(indexPath(roots[i]), roots[i], *r, meta);
      s.r = r;
      s.dirId = 0;
    }
  }
  return out;
}

enum class Mode { Overview = 0, Browse, Reclaim, Duplicates, Leftovers, Downloads, Forgotten, BigFiles, Apps, Trash, Count };

// Pages whose rows come from a finder that runs on demand, off the main thread.
static bool isFinderMode(Mode m) {
  return m == Mode::Duplicates || m == Mode::Leftovers || m == Mode::Downloads || m == Mode::Trash;
}

struct ModeInfo {
  NSString* title;
  NSString* symbol;
  NSString* hint;
  NSString* emptyTitle;
  NSString* emptyHint;
};
static const ModeInfo kModes[] = {
    {@"Overview", @"chart.pie.fill", @"", @"", @""},
    {@"All folders", @"folder.fill",
     @"Everything on the disk, biggest first. Expand a folder to see what's inside; "
     @"the dot shows how recently something in it was used.",
     @"Empty folder", @"There's nothing in here."},
    {@"Safe to delete", @"sparkles",
     @"Data that tools generate and can regenerate: npm packages, build output, caches, Xcode and "
     @"Docker data. Deleting it frees space without losing any of your own files.",
     @"Nothing to regenerate", @"No npm packages, build output, caches or Xcode data here."},
    {@"Duplicates", @"doc.on.doc.fill",
     @"Files of 4 MB or more that exist more than once with identical content (verified byte for byte). "
     @"The most recently used copy of each is kept; the others are preselected.",
     @"No duplicates", @"Every file over 4 MB exists only once."},
    {@"Leftovers", @"puzzlepiece.extension.fill",
     @"Settings, caches and containers in your Library that belong to apps no longer installed, "
     @"plus old iPhone and iPad backups.",
     @"No leftovers", @"Everything in your Library belongs to an installed app."},
    {@"Old downloads", @"arrow.down.circle.fill",
     @"Downloads not opened for 30 days. Installers whose app is already installed are preselected; "
     @"have a look at the rest before you decide.",
     @"Downloads are tidy", @"Nothing in ~/Downloads has sat there for 30 days."},
    {@"Forgotten", @"clock.arrow.circlepath",
     @"Folders of 50 MB or more where nothing has been opened or changed in over 6 months. "
     @"If you don't recognise one, you probably don't need it.",
     @"No forgotten folders", @"Every folder over 50 MB has been touched in the last 6 months."},
    {@"Big unused files", @"shippingbox.fill",
     @"Single files of 100 MB or more untouched for over 6 months: old downloads, installers, "
     @"videos, disk images.",
     @"No big unused files", @"Nothing over 100 MB has gone untouched for 6 months."},
    {@"Apps", @"app.badge.fill",
     @"Apps in /Applications and ~/Applications by when you last launched them (from Spotlight). "
     @"Apps you never open can be removed and reinstalled later.",
     @"No apps found", @"Nothing in /Applications or ~/Applications."},
    {@"Trash", @"trash.fill",
     @"What's waiting in your Trash. Emptying it is the only step in Stale that deletes for good.",
     @"The Trash is empty", @"Nothing to empty."},
};

// ───────────────────────────── views ─────────────────────────────

// Rounded panel with a hairline border; the building block of the Overview page.
@interface SurfaceView : NSView
@property(nonatomic) CGFloat radius;
@property(nonatomic, strong) NSColor* fill;
@property(nonatomic, strong) NSColor* stroke;
@end
@implementation SurfaceView
- (instancetype)initWithFrame:(NSRect)f {
  if (!(self = [super initWithFrame:f])) return nil;
  _radius = 14;
  _fill = surfaceFill();
  _stroke = surfaceStroke();
  return self;
}
- (void)drawRect:(NSRect)r {
  NSBezierPath* p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:_radius yRadius:_radius];
  [_fill setFill];
  [p fill];
  [_stroke setStroke];
  p.lineWidth = 1;
  [p stroke];
}
@end

// Segmented recency bar with rounded ends and hairline gaps between segments.
@interface RecencyBarView : NSView
@property(nonatomic) std::vector<double> parts;  // NBUCKETS values
@property(nonatomic) CGFloat gap;
@end
@implementation RecencyBarView
- (void)setParts:(std::vector<double>)p { _parts = std::move(p); [self setNeedsDisplay:YES]; }
- (void)drawRect:(NSRect)r {
  NSRect b = self.bounds;
  CGFloat rad = b.size.height / 2;
  NSBezierPath* clip = [NSBezierPath bezierPathWithRoundedRect:b xRadius:rad yRadius:rad];
  [clip addClip];
  [NSColor.quaternaryLabelColor setFill];
  NSRectFill(b);
  double total = 0;
  for (double v : _parts) total += v;
  if (total <= 0) return;
  CGFloat x = 0;
  CGFloat gap = _gap;
  for (size_t i = 0; i < _parts.size() && i < NBUCKETS; ++i) {
    CGFloat w = b.size.width * _parts[i] / total;
    if (w <= 0) continue;
    [kBucketColors[i] setFill];
    NSRectFill(NSMakeRect(x, 0, std::max<CGFloat>(0, w - gap), b.size.height));
    x += w;
  }
}
@end

// DaisyDisk-style two-level ring: inner ring = folders of the root, outer ring = their folders.
struct RingSeg {
  int32_t dirId;      // -1 for "files here" / "everything else"
  double a0, a1;      // fraction of a full turn, clockwise from 12 o'clock
  int level;          // 0 inner, 1 outer
  int hue;            // palette index, -1 = neutral
  int shade;          // outer ring: alternates to separate neighbours
  NSString* name;
  NSString* detail;
};

@interface RingView : NSView
@property(nonatomic) std::vector<RingSeg> segs;
@property(nonatomic, copy) NSString* centerTitle;
@property(nonatomic, copy) NSString* centerSub;
@property(nonatomic, strong) NSColor* gapColor;
@property(nonatomic, weak) id target;
@property(nonatomic) SEL action;
@property(nonatomic, readonly) int32_t clickedDir;
@end
@implementation RingView {
  int _hover;
  NSTrackingArea* _track;
}
- (instancetype)initWithFrame:(NSRect)f {
  if (!(self = [super initWithFrame:f])) return nil;
  _hover = -1;
  _clickedDir = -1;
  _gapColor = surfaceFill();
  return self;
}
- (void)setSegs:(std::vector<RingSeg>)s {
  _segs = std::move(s);
  _hover = -1;
  [self setNeedsDisplay:YES];
}
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_track) [self removeTrackingArea:_track];
  _track = [[NSTrackingArea alloc] initWithRect:self.bounds
                                        options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                                                NSTrackingActiveInKeyWindow
                                          owner:self
                                       userInfo:nil];
  [self addTrackingArea:_track];
}
- (void)radiiFor:(int)level inner:(CGFloat*)r0 outer:(CGFloat*)r1 {
  CGFloat R = std::min(self.bounds.size.width, self.bounds.size.height) / 2 - 6;
  if (level == 0) { *r0 = R * 0.50; *r1 = R * 0.76; }
  else { *r0 = R * 0.80; *r1 = R; }
}
- (int)segmentAt:(NSPoint)p {
  NSPoint c = NSMakePoint(NSMidX(self.bounds), NSMidY(self.bounds));
  CGFloat dx = p.x - c.x, dy = p.y - c.y;
  CGFloat d = std::hypot(dx, dy);
  double ang = std::atan2(dy, dx) * 180 / M_PI;  // counter-clockwise from 3 o'clock
  double frac = std::fmod(90 - ang + 720, 360) / 360;  // clockwise from 12 o'clock
  for (size_t i = 0; i < _segs.size(); ++i) {
    CGFloat r0, r1;
    [self radiiFor:_segs[i].level inner:&r0 outer:&r1];
    if (d >= r0 && d <= r1 + 3 && frac >= _segs[i].a0 && frac < _segs[i].a1) return (int)i;
  }
  return -1;
}
- (void)mouseMoved:(NSEvent*)e {
  int h = [self segmentAt:[self convertPoint:e.locationInWindow fromView:nil]];
  if (h != _hover) { _hover = h; [self setNeedsDisplay:YES]; }
}
- (void)mouseExited:(NSEvent*)e { if (_hover != -1) { _hover = -1; [self setNeedsDisplay:YES]; } }
- (void)mouseDown:(NSEvent*)e {}
- (void)mouseUp:(NSEvent*)e {
  int h = [self segmentAt:[self convertPoint:e.locationInWindow fromView:nil]];
  if (h < 0 || _segs[(size_t)h].dirId < 0 || !_target || !_action) return;
  _clickedDir = _segs[(size_t)h].dirId;
  [NSApp sendAction:_action to:_target from:self];
}
- (void)resetCursorRects {
  for (const RingSeg& s : _segs)
    if (s.dirId >= 0) { [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor]; break; }
}
- (NSColor*)colorFor:(const RingSeg&)s {
  NSColor* c = s.hue < 0 ? kRingOther : kRingColors[s.hue % kRingPalette];
  if (s.level == 1) c = [c blendedColorWithFraction:(s.shade ? 0.28 : 0.10) ofColor:NSColor.whiteColor] ?: c;
  if (s.dirId < 0 && s.level == 1) c = [c colorWithAlphaComponent:0.45];
  return c;
}
- (void)drawRect:(NSRect)rect {
  NSPoint c = NSMakePoint(NSMidX(self.bounds), NSMidY(self.bounds));
  const RingSeg* hov = _hover >= 0 && (size_t)_hover < _segs.size() ? &_segs[(size_t)_hover] : nullptr;
  for (size_t i = 0; i < _segs.size(); ++i) {
    const RingSeg& s = _segs[i];
    if (s.a1 - s.a0 <= 0) continue;
    CGFloat r0, r1;
    [self radiiFor:s.level inner:&r0 outer:&r1];
    BOOL isHover = hov == &s;
    // Highlight the hovered segment and, for an inner one, its outer children.
    BOOL related = hov && !isHover && hov->level == 0 && s.level == 1 && s.a0 >= hov->a0 - 1e-9 && s.a1 <= hov->a1 + 1e-9;
    if (isHover) r1 += 3;
    CGFloat start = 90 - s.a0 * 360, end = 90 - s.a1 * 360;
    NSBezierPath* p = [NSBezierPath bezierPath];
    [p appendBezierPathWithArcWithCenter:c radius:r1 startAngle:start endAngle:end clockwise:YES];
    [p appendBezierPathWithArcWithCenter:c radius:r0 startAngle:end endAngle:start clockwise:NO];
    [p closePath];
    NSColor* col = [self colorFor:s];
    if (hov && !isHover && !related) col = [col colorWithAlphaComponent:0.35];
    [col setFill];
    [p fill];
    [_gapColor setStroke];
    p.lineWidth = 1.5;
    [p stroke];
  }
  // Centre text.
  NSString* title = hov ? hov->name : _centerTitle;
  NSString* sub = hov ? hov->detail : _centerSub;
  CGFloat r0, r1;
  [self radiiFor:0 inner:&r0 outer:&r1];
  CGFloat maxW = r0 * 2 - 12;
  NSMutableParagraphStyle* ps = [NSMutableParagraphStyle new];
  ps.alignment = NSTextAlignmentCenter;
  ps.lineBreakMode = NSLineBreakByTruncatingTail;
  // Shrink the headline until it fits the hole (folder names may still truncate).
  NSFont* tf = hov ? [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold] : roundedFont(24, NSFontWeightBold);
  if (!hov) {
    for (CGFloat sz = 24; sz >= 13; sz -= 1) {
      tf = roundedFont(sz, NSFontWeightBold);
      if ([title ?: @"" sizeWithAttributes:@{NSFontAttributeName : tf}].width <= maxW) break;
    }
  }
  NSDictionary* ta = @{
    NSFontAttributeName : tf,
    NSForegroundColorAttributeName : NSColor.labelColor,
    NSParagraphStyleAttributeName : ps
  };
  NSDictionary* sa = @{
    NSFontAttributeName : monoDigits(11, NSFontWeightMedium),
    NSForegroundColorAttributeName : NSColor.secondaryLabelColor,
    NSParagraphStyleAttributeName : ps
  };
  NSAttributedString* t = [[NSAttributedString alloc] initWithString:title ?: @"" attributes:ta];
  NSAttributedString* u = [[NSAttributedString alloc] initWithString:sub ?: @"" attributes:sa];
  NSRect tb = [t boundingRectWithSize:NSMakeSize(maxW, 60) options:NSStringDrawingUsesLineFragmentOrigin];
  NSRect ub = [u boundingRectWithSize:NSMakeSize(maxW, 40) options:NSStringDrawingUsesLineFragmentOrigin];
  ub.size.height = std::min<CGFloat>(ub.size.height, 30);
  CGFloat total = tb.size.height + 2 + ub.size.height;
  CGFloat y = c.y + total / 2;
  [t drawWithRect:NSMakeRect(c.x - maxW / 2, y - tb.size.height, maxW, tb.size.height) options:NSStringDrawingUsesLineFragmentOrigin];
  [u drawWithRect:NSMakeRect(c.x - maxW / 2, y - tb.size.height - 2 - ub.size.height, maxW, ub.size.height)
          options:NSStringDrawingUsesLineFragmentOrigin];
}
@end

// Scroll document view that lays out from the top like the rest of the UI.
@interface FlippedView : NSView
@end
@implementation FlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface HairlineView : NSView
@end
@implementation HairlineView
- (void)drawRect:(NSRect)r { [NSColor.separatorColor setFill]; NSRectFill(self.bounds); }
@end

// Size cell: text on top of a faint bar proportional to the item's share of its parent.
@interface SizeCellView : NSTableCellView
@property(nonatomic) double fraction;
@end
@implementation SizeCellView
- (void)drawRect:(NSRect)r {
  [super drawRect:r];
  if (_fraction <= 0) return;
  NSRect b = NSInsetRect(self.bounds, 4, 6);
  CGFloat w = std::max<CGFloat>(3, b.size.width * std::min(1.0, _fraction));
  NSRect bar = NSMakeRect(NSMaxX(b) - w, b.origin.y, w, b.size.height);
  [[NSColor.controlAccentColor colorWithAlphaComponent:0.16] setFill];
  [[NSBezierPath bezierPathWithRoundedRect:bar xRadius:4 yRadius:4] fill];
}
- (void)setFraction:(double)f { _fraction = f; [self setNeedsDisplay:YES]; }
@end

// Clickable summary card on the Overview page.
@interface CardView : SurfaceView
@property(nonatomic) Mode mode;
@property(nonatomic, weak) id target;
@property(nonatomic) SEL action;
@property(nonatomic, strong) NSTextField* valueLabel;
@property(nonatomic, strong) NSTextField* detailLabel;
@property(nonatomic) BOOL hover;
@end
@implementation CardView
- (instancetype)initWithMode:(Mode)m tint:(NSColor*)tint {
  if (!(self = [super initWithFrame:NSZeroRect])) return nil;
  _mode = m;
  const ModeInfo& mi = kModes[(int)m];
  NSView* badge = [NSView new];
  badge.wantsLayer = YES;
  badge.layer.cornerRadius = 8;
  badge.layer.backgroundColor = [tint colorWithAlphaComponent:0.16].CGColor;
  fixSize(badge, 28, 28);
  NSImageView* icon = [NSImageView imageViewWithImage:symbol(mi.symbol, 13, NSFontWeightSemibold)];
  icon.contentTintColor = tint;
  icon.translatesAutoresizingMaskIntoConstraints = NO;
  [badge addSubview:icon];
  [NSLayoutConstraint activateConstraints:@[
    [icon.centerXAnchor constraintEqualToAnchor:badge.centerXAnchor],
    [icon.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor],
  ]];
  NSTextField* title = label(mi.title, 12, NSFontWeightMedium, NSColor.secondaryLabelColor);
  NSImageView* chevron = [NSImageView imageViewWithImage:symbol(@"chevron.right", 10, NSFontWeightSemibold)];
  chevron.contentTintColor = NSColor.tertiaryLabelColor;
  NSStackView* top = [NSStackView stackViewWithViews:@[ badge, title, chevron ]];
  top.spacing = 8;
  [top setCustomSpacing:0 afterView:title];
  [title setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
  _valueLabel = label(@"—", 22, NSFontWeightSemibold, NSColor.labelColor);
  _valueLabel.font = roundedFont(22, NSFontWeightSemibold);
  _detailLabel = [NSTextField wrappingLabelWithString:@""];
  _detailLabel.font = [NSFont systemFontOfSize:11];
  _detailLabel.textColor = NSColor.secondaryLabelColor;
  _detailLabel.selectable = NO;
  _detailLabel.maximumNumberOfLines = 2;
  NSStackView* col = [NSStackView stackViewWithViews:@[ top, _valueLabel, _detailLabel ]];
  col.orientation = NSUserInterfaceLayoutOrientationVertical;
  col.alignment = NSLayoutAttributeLeading;
  col.spacing = 2;
  [col setCustomSpacing:12 afterView:top];
  pin(col, self, NSEdgeInsetsMake(14, 16, 14, 14));
  [top.widthAnchor constraintEqualToAnchor:col.widthAnchor].active = YES;
  [_detailLabel.widthAnchor constraintEqualToAnchor:col.widthAnchor].active = YES;
  [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                     options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow |
                                                             NSTrackingInVisibleRect
                                                       owner:self
                                                    userInfo:nil]];
  self.toolTip = [NSString stringWithFormat:@"Show %@", mi.title.lowercaseString];
  return self;
}
- (void)drawRect:(NSRect)r {
  self.stroke = _hover ? [NSColor.controlAccentColor colorWithAlphaComponent:0.7] : surfaceStroke();
  [super drawRect:r];
  if (_hover) {
    NSBezierPath* p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:self.radius yRadius:self.radius];
    [[NSColor.controlAccentColor colorWithAlphaComponent:0.04] setFill];
    [p fill];
  }
}
- (void)mouseEntered:(NSEvent*)e { _hover = YES; [self setNeedsDisplay:YES]; }
- (void)mouseExited:(NSEvent*)e { _hover = NO; [self setNeedsDisplay:YES]; }
- (void)mouseDown:(NSEvent*)e {}
- (void)mouseUp:(NSEvent*)e {
  NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
  if (NSPointInRect(p, self.bounds) && _target && _action) [NSApp sendAction:_action to:_target from:self];
}
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor]; }
@end

// ───────────────────────────── sidebar ─────────────────────────────

@interface SidebarEntry : NSObject
@property(nonatomic) Mode mode;
@property(nonatomic) BOOL isGroup;
@property(nonatomic, copy) NSString* title;
@property(nonatomic, copy) NSString* badge;
@end
@implementation SidebarEntry
@end

// ───────────────────────────── controller ─────────────────────────────

@interface StaleController : NSObject <NSApplicationDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate,
                                       NSToolbarDelegate, NSMenuDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate>
- (void)togglePreview:(id)sender;
- (void)openSelected:(id)sender;
@end

// File list: Space previews, ⌘↓ opens, like the Finder.
@interface FileOutlineView : NSOutlineView
@end
@implementation FileOutlineView
- (void)keyDown:(NSEvent*)e {
  StaleController* c = (StaleController*)NSApp.delegate;
  NSString* chars = e.charactersIgnoringModifiers;
  BOOL cmd = (e.modifierFlags & NSEventModifierFlagCommand) != 0;
  if ([chars isEqual:@" "] && !cmd) {
    [c togglePreview:self];
    return;
  }
  if (cmd && chars.length == 1 && [chars characterAtIndex:0] == NSDownArrowFunctionKey) {
    [c openSelected:self];
    return;
  }
  [super keyDown:e];
}
- (BOOL)acceptsPreviewPanelControl:(QLPreviewPanel*)panel { return YES; }
- (void)beginPreviewPanelControl:(QLPreviewPanel*)panel {
  panel.dataSource = (StaleController*)NSApp.delegate;
  panel.delegate = (StaleController*)NSApp.delegate;
}
- (void)endPreviewPanelControl:(QLPreviewPanel*)panel {
  panel.dataSource = nil;
  panel.delegate = nil;
}
@end

@implementation StaleController {
  NSWindow* _window;
  NSSplitViewController* _split;

  // sidebar
  NSOutlineView* _sidebar;
  NSArray<SidebarEntry*>* _entries;
  BOOL _syncingSidebar;

  // content
  NSView* _content;
  NSView* _fdaBanner;
  NSTextField* _pageTitle;
  NSTextField* _pageHint;

  // index status pill (top right of every page)
  SurfaceView* _statusPill;
  NSImageView* _statusIcon;
  NSProgressIndicator* _statusSpinner;
  NSTextField* _statusText;
  NSButton* _statusStop;

  // overview page
  NSScrollView* _overviewScroll;
  RingView* _ring;
  NSTextField* _heroCaption;
  RecencyBarView* _bar;
  NSStackView* _legend;
  NSMutableArray<CardView*>* _cards;
  NSStackView* _topList;
  NSTextField* _topTitle;
  SurfaceView* _topSurface;

  // list page
  NSView* _listBox;
  NSOutlineView* _outline;
  NSScrollView* _scroll;
  NSView* _empty;
  NSImageView* _emptyIcon;
  NSTextField* _emptyTitle;
  NSTextField* _emptyHint;
  NSView* _bottom;
  NSTextField* _status;
  NSButton* _trashButton;
  NSButton* _revealButton;

  // first index of a root: full-page progress
  NSView* _firstRun;
  NSTextField* _firstRunTitle;
  NSTextField* _firstRunCount;
  NSProgressIndicator* _firstRunSpinner;
  NSTimer* _progressTimer;

  Model _model;
  Item* _root;
  NSArray<Item*>* _flat;  // items shown in non-browse modes
  NSMutableArray<Item*>* _appItems;
  Mode _mode;

  // Finder pages: results are computed on first visit and kept until the index changes.
  NSMutableArray<Item*>* _finderItems[(int)Mode::Count];
  BOOL _finderRunning[(int)Mode::Count];
  BOOL _finderUnreadable[(int)Mode::Count];  // the folder is TCC-protected; the empty list means nothing
  int _finderGeneration;
  std::shared_ptr<std::atomic<bool>> _finderCancel;
  std::shared_ptr<std::atomic<uint64_t>> _finderProgress;
  std::shared_ptr<std::atomic<uint64_t>> _finderProgressTotal;
  NSProgressIndicator* _emptySpinner;
  NSTimer* _finderTimer;
  NSButton* _emptyTrashButton;
  std::string _scanPath;    // root being (or last asked to be) indexed
  std::string _resultPath;  // root the current model describes
  std::shared_ptr<std::atomic<uint64_t>> _progress;
  std::shared_ptr<std::atomic<bool>> _cancel;  // owned by the scan in flight
  int _scanGeneration;
  BOOL _scanning;
  BOOL _loading;  // reading the index from disk
  NSTimer* _persistTimer;
  NSString* _sortKey;
  BOOL _sortAscending;
  std::string _launchRoot;  // folder handed over by Finder/`open` before the window exists

  // Keeping the index fresh: FSEvents since the saved event id, then live while the app is open.
  std::unique_ptr<FsWatcher> _watcher;
  int _watchGeneration;  // bumped whenever the watcher is replaced; late batches of an old one are dropped
  dispatch_queue_t _fsQueue;
  std::vector<RefreshRequest> _pendingChanges;
  uint64_t _pendingEventId;
  BOOL _historyDone;  // everything that happened while the app was closed has been delivered
  BOOL _refreshing;   // a patch is being collected off the main thread
  double _refreshStarted;
  NSTimer* _refreshTimer;
}

// ───── app lifecycle ─────

- (void)applicationDidFinishLaunching:(NSNotification*)n {
  initColors();
  _sortKey = @"size";
  _sortAscending = NO;
  _mode = Mode::Overview;
  [self buildMenus];
  [self buildWindow];
  [self installEscapeMonitor];
  [NSApp activateIgnoringOtherApps:YES];
  std::string start = _launchRoot.empty() ? "/" : _launchRoot;
  NSArray<NSString*>* args = NSProcessInfo.processInfo.arguments;
  if (args.count > 1 && ![args[1] hasPrefix:@"-"]) {
    BOOL isDir = NO;
    if ([NSFileManager.defaultManager fileExistsAtPath:args[1] isDirectory:&isDir] && isDir)
      start = std_str(args[1].stringByStandardizingPath);
  }
  [self openRoot:start];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)a { return YES; }

- (void)applicationWillTerminate:(NSNotification*)n {
  _watcher.reset();
  if (_persistTimer) {
    [_persistTimer invalidate];
    _persistTimer = nil;
    [self persistIndexNow];
  }
}

- (BOOL)application:(NSApplication*)app openFile:(NSString*)path {
  BOOL isDir = NO;
  if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir] || !isDir) return NO;
  std::string root = std_str(path.stringByStandardizingPath);
  if (_window) [self openRoot:root];
  else _launchRoot = root;  // cold launch: this arrives before applicationDidFinishLaunching
  return YES;
}

// Escape stops an in-flight scan unless a text field owns the key (it uses Escape itself).
- (void)installEscapeMonitor {
  __weak StaleController* weakSelf = self;
  [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                        handler:^NSEvent*(NSEvent* e) {
    StaleController* s = weakSelf;
    if (!s || e.keyCode != 53 || !s->_scanning || e.window != s->_window) return e;
    if ([s->_window.firstResponder isKindOfClass:NSText.class]) return e;
    [s cancelScan:nil];
    return nil;
  }];
}

- (void)buildMenus {
  NSMenu* menubar = [NSMenu new];
  NSMenuItem* appItem = [NSMenuItem new];
  [menubar addItem:appItem];
  NSMenu* app = [NSMenu new];
  [app addItemWithTitle:@"About Stale" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
  [app addItem:NSMenuItem.separatorItem];
  [app addItemWithTitle:@"Hide Stale" action:@selector(hide:) keyEquivalent:@"h"];
  NSMenuItem* hideOthers = [app addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
  hideOthers.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
  [app addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
  [app addItem:NSMenuItem.separatorItem];
  [app addItemWithTitle:@"Quit Stale" action:@selector(terminate:) keyEquivalent:@"q"];
  appItem.submenu = app;

  NSMenuItem* fileItem = [NSMenuItem new];
  [menubar addItem:fileItem];
  NSMenu* file = [[NSMenu alloc] initWithTitle:@"File"];
  [file addItemWithTitle:@"Open Folder…" action:@selector(chooseFolder:) keyEquivalent:@"o"];
  [file addItemWithTitle:@"Whole Disk" action:@selector(openDisk:) keyEquivalent:@"D"];
  [file addItemWithTitle:@"Home Folder" action:@selector(openHome:) keyEquivalent:@"H"];
  [file addItem:NSMenuItem.separatorItem];
  [file addItemWithTitle:@"Rescan" action:@selector(rescan:) keyEquivalent:@"r"];
  [file addItemWithTitle:@"Stop Indexing" action:@selector(cancelScan:) keyEquivalent:@"."];
  [file addItem:NSMenuItem.separatorItem];
  NSMenuItem* openIt = [file addItemWithTitle:@"Open" action:@selector(openSelected:) keyEquivalent:[NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey]];
  openIt.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  [file addItemWithTitle:@"Quick Look" action:@selector(togglePreview:) keyEquivalent:@"y"];
  [file addItemWithTitle:@"Reveal in Finder" action:@selector(revealSelected:) keyEquivalent:@"R"];
  [file addItem:NSMenuItem.separatorItem];
  NSMenuItem* trash = [file addItemWithTitle:@"Move to Trash" action:@selector(trashSelected:) keyEquivalent:@"\b"];
  trash.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  [file addItemWithTitle:@"Empty Trash…" action:@selector(emptyTrash:) keyEquivalent:@""];
  [file addItem:NSMenuItem.separatorItem];
  [file addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
  fileItem.submenu = file;

  NSMenuItem* editItem = [NSMenuItem new];
  [menubar addItem:editItem];
  NSMenu* edit = [[NSMenu alloc] initWithTitle:@"Edit"];
  [edit addItemWithTitle:@"Copy Path" action:@selector(copyPath:) keyEquivalent:@"c"];
  [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
  editItem.submenu = edit;

  NSMenuItem* viewItem = [NSMenuItem new];
  [menubar addItem:viewItem];
  NSMenu* view = [[NSMenu alloc] initWithTitle:@"View"];
  for (int i = 0; i < (int)Mode::Count; ++i) {
    NSMenuItem* mi = [view addItemWithTitle:kModes[i].title action:@selector(modeFromMenu:)
                              keyEquivalent:[NSString stringWithFormat:@"%d", (i + 1) % 10]];
    mi.tag = i;
  }
  [view addItem:NSMenuItem.separatorItem];
  [view addItemWithTitle:@"Toggle Sidebar" action:@selector(toggleSidebar:) keyEquivalent:@"s"].keyEquivalentModifierMask =
      NSEventModifierFlagCommand | NSEventModifierFlagControl;
  viewItem.submenu = view;

  NSMenuItem* windowItem = [NSMenuItem new];
  [menubar addItem:windowItem];
  NSMenu* window = [[NSMenu alloc] initWithTitle:@"Window"];
  [window addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
  [window addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
  windowItem.submenu = window;
  NSApp.windowsMenu = window;

  NSMenuItem* helpItem = [NSMenuItem new];
  [menubar addItem:helpItem];
  NSMenu* help = [[NSMenu alloc] initWithTitle:@"Help"];
  [help addItemWithTitle:@"Stale on GitHub" action:@selector(openGitHub:) keyEquivalent:@""];
  [help addItemWithTitle:@"Grant Full Disk Access…" action:@selector(openFDA:) keyEquivalent:@""];
  [help addItem:NSMenuItem.separatorItem];
  [help addItemWithTitle:@"Show Index Files in Finder" action:@selector(revealIndex:) keyEquivalent:@""];
  helpItem.submenu = help;
  NSApp.helpMenu = help;

  NSApp.mainMenu = menubar;
}

- (void)buildWindow {
  _window = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(0, 0, 1180, 780)
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                          NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView
                  backing:NSBackingStoreBuffered
                    defer:NO];
  _window.title = @"Stale";
  _window.minSize = NSMakeSize(860, 560);
  _window.toolbarStyle = NSWindowToolbarStyleUnified;
  _window.titlebarSeparatorStyle = NSTitlebarSeparatorStyleAutomatic;
  NSToolbar* tb = [[NSToolbar alloc] initWithIdentifier:@"main"];
  tb.delegate = self;
  tb.displayMode = NSToolbarDisplayModeIconOnly;
  _window.toolbar = tb;

  _split = [NSSplitViewController new];
  _split.splitView.autosaveName = @"StaleSplit";

  NSViewController* sideVC = [NSViewController new];
  sideVC.view = [self buildSidebar];
  NSSplitViewItem* side = [NSSplitViewItem sidebarWithViewController:sideVC];
  side.minimumThickness = 220;
  side.maximumThickness = 320;
  side.canCollapse = YES;
  [_split addSplitViewItem:side];

  NSViewController* contentVC = [NSViewController new];
  contentVC.view = [self buildContent];
  NSSplitViewItem* main = [NSSplitViewItem splitViewItemWithViewController:contentVC];
  main.minimumThickness = 640;
  [_split addSplitViewItem:main];

  _window.contentViewController = _split;
  [_window setContentSize:NSMakeSize(1180, 780)];
  [_window center];
  [_window setFrameAutosaveName:@"StaleMain"];
  [_window makeKeyAndOrderFront:nil];
}

- (NSView*)buildSidebar {
  NSMutableArray<SidebarEntry*>* e = [NSMutableArray new];
  auto add = [&](Mode m, BOOL group, NSString* title) {
    SidebarEntry* s = [SidebarEntry new];
    s.mode = m;
    s.isGroup = group;
    s.title = title ?: kModes[(int)m].title;
    [e addObject:s];
  };
  add(Mode::Overview, NO, nil);
  add(Mode::Browse, NO, nil);
  add(Mode::Overview, YES, @"Clean up");
  add(Mode::Reclaim, NO, nil);
  add(Mode::Duplicates, NO, nil);
  add(Mode::Leftovers, NO, nil);
  add(Mode::Downloads, NO, nil);
  add(Mode::Overview, YES, @"Review");
  add(Mode::Forgotten, NO, nil);
  add(Mode::BigFiles, NO, nil);
  add(Mode::Apps, NO, nil);
  add(Mode::Trash, NO, nil);
  _entries = e;

  _sidebar = [NSOutlineView new];
  _sidebar.dataSource = self;
  _sidebar.delegate = self;
  _sidebar.headerView = nil;
  _sidebar.style = NSTableViewStyleSourceList;
  _sidebar.rowSizeStyle = NSTableViewRowSizeStyleDefault;
  _sidebar.floatsGroupRows = NO;
  _sidebar.indentationPerLevel = 0;
  _sidebar.allowsEmptySelection = NO;
  _sidebar.focusRingType = NSFocusRingTypeNone;
  _sidebar.refusesFirstResponder = YES;  // keyboard focus stays in the file list
  NSTableColumn* col = [[NSTableColumn alloc] initWithIdentifier:@"side"];
  col.resizingMask = NSTableColumnAutoresizingMask;
  [_sidebar addTableColumn:col];
  _sidebar.outlineTableColumn = col;

  NSScrollView* sc = [NSScrollView new];
  sc.documentView = _sidebar;
  sc.hasVerticalScroller = YES;
  sc.drawsBackground = NO;
  sc.automaticallyAdjustsContentInsets = YES;

  NSView* v = [NSView new];
  pin(sc, v, NSEdgeInsetsMake(0, 0, 0, 0));
  return v;
}

- (NSView*)buildContent {
  _content = [NSView new];

  _fdaBanner = [self makeBanner];
  _fdaBanner.hidden = YES;

  _pageTitle = label(@"Overview", 26, NSFontWeightBold, NSColor.labelColor);
  _pageTitle.font = roundedFont(26, NSFontWeightBold);
  [self buildStatusPill];
  NSView* titleSpacer = [[NSView alloc] initWithFrame:NSZeroRect];
  [titleSpacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
  NSStackView* titleRow = [NSStackView stackViewWithViews:@[ _pageTitle, _statusPill, titleSpacer ]];
  titleRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  titleRow.alignment = NSLayoutAttributeCenterY;
  titleRow.spacing = 12;

  _pageHint = [NSTextField wrappingLabelWithString:@""];
  _pageHint.font = [NSFont systemFontOfSize:12];
  _pageHint.textColor = NSColor.secondaryLabelColor;
  _pageHint.selectable = NO;

  [self buildOverview];
  [self buildList];
  [self buildFirstRun];

  NSStackView* page = [NSStackView
      stackViewWithViews:@[ _fdaBanner, titleRow, _pageHint, _overviewScroll, _listBox, _firstRun, _bottom ]];
  page.orientation = NSUserInterfaceLayoutOrientationVertical;
  page.alignment = NSLayoutAttributeLeading;
  page.spacing = 8;
  [page setCustomSpacing:16 afterView:_fdaBanner];
  [page setCustomSpacing:4 afterView:titleRow];
  [page setCustomSpacing:16 afterView:_pageHint];
  [page setCustomSpacing:12 afterView:_listBox];
  page.translatesAutoresizingMaskIntoConstraints = NO;
  [_content addSubview:page];
  [NSLayoutConstraint activateConstraints:@[
    [page.leadingAnchor constraintEqualToAnchor:_content.leadingAnchor constant:24],
    [page.trailingAnchor constraintEqualToAnchor:_content.trailingAnchor constant:-24],
    [page.topAnchor constraintEqualToAnchor:_content.safeAreaLayoutGuide.topAnchor constant:16],
    [page.bottomAnchor constraintEqualToAnchor:_content.bottomAnchor constant:-16],
    [_fdaBanner.widthAnchor constraintEqualToAnchor:page.widthAnchor],
    [titleRow.widthAnchor constraintEqualToAnchor:page.widthAnchor],
    [_pageHint.widthAnchor constraintEqualToAnchor:page.widthAnchor],
    [_overviewScroll.widthAnchor constraintEqualToAnchor:page.widthAnchor],
    [_listBox.widthAnchor constraintEqualToAnchor:page.widthAnchor],
    [_firstRun.widthAnchor constraintEqualToAnchor:page.widthAnchor],
    [_bottom.widthAnchor constraintEqualToAnchor:page.widthAnchor],
  ]];
  for (NSView* v in @[ _listBox, _overviewScroll, _firstRun ])
    [v setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];
  return _content;
}

- (void)buildStatusPill {
  _statusPill = [[SurfaceView alloc] initWithFrame:NSZeroRect];
  _statusPill.radius = 13;
  _statusIcon = [NSImageView imageViewWithImage:symbol(@"clock", 11, NSFontWeightSemibold)];
  _statusIcon.contentTintColor = NSColor.secondaryLabelColor;
  _statusSpinner = [NSProgressIndicator new];
  _statusSpinner.style = NSProgressIndicatorStyleSpinning;
  _statusSpinner.controlSize = NSControlSizeSmall;
  _statusSpinner.displayedWhenStopped = NO;
  fixSize(_statusSpinner, 14, 14);
  _statusText = label(@"", 12, NSFontWeightMedium, NSColor.secondaryLabelColor);
  _statusText.font = monoDigits(12, NSFontWeightMedium);
  _statusStop = [NSButton buttonWithTitle:@"Stop" target:self action:@selector(cancelScan:)];
  _statusStop.bezelStyle = NSBezelStyleInline;
  _statusStop.controlSize = NSControlSizeSmall;
  _statusStop.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
  NSStackView* row = [NSStackView stackViewWithViews:@[ _statusIcon, _statusSpinner, _statusText, _statusStop ]];
  row.spacing = 6;
  row.alignment = NSLayoutAttributeCenterY;
  [row setHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
  pin(row, _statusPill, NSEdgeInsetsMake(4, 10, 4, 8));
  [_statusPill.heightAnchor constraintEqualToConstant:26].active = YES;
  _statusPill.hidden = YES;
}

- (void)buildOverview {
  // ── hero: ring + recency
  SurfaceView* hero = [[SurfaceView alloc] initWithFrame:NSZeroRect];
  _ring = [[RingView alloc] initWithFrame:NSZeroRect];
  _ring.target = self;
  _ring.action = @selector(ringClicked:);
  fixSize(_ring, 240, 240);

  _heroCaption = label(@"BY LAST USE", 11, NSFontWeightSemibold, NSColor.tertiaryLabelColor);
  _bar = [RecencyBarView new];
  _bar.gap = 2;
  fixSize(_bar, 0, 14);
  _legend = [NSStackView new];
  _legend.orientation = NSUserInterfaceLayoutOrientationVertical;
  _legend.alignment = NSLayoutAttributeLeading;
  _legend.spacing = 6;
  NSTextField* heroNote = [NSTextField wrappingLabelWithString:
      @"Recency comes from Spotlight's “last opened” dates where available, otherwise from when a file was last changed."];
  heroNote.font = [NSFont systemFontOfSize:11];
  heroNote.textColor = NSColor.tertiaryLabelColor;
  heroNote.selectable = NO;
  NSStackView* right = [NSStackView stackViewWithViews:@[ _heroCaption, _bar, _legend, heroNote ]];
  right.orientation = NSUserInterfaceLayoutOrientationVertical;
  right.alignment = NSLayoutAttributeLeading;
  right.spacing = 12;
  [right setCustomSpacing:14 afterView:_bar];
  [right setCustomSpacing:16 afterView:_legend];
  NSStackView* heroRow = [NSStackView stackViewWithViews:@[ _ring, right ]];
  heroRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  heroRow.alignment = NSLayoutAttributeCenterY;
  heroRow.spacing = 28;
  pin(heroRow, hero, NSEdgeInsetsMake(20, 24, 20, 24));
  [NSLayoutConstraint activateConstraints:@[
    [_bar.widthAnchor constraintEqualToAnchor:right.widthAnchor],
    [_legend.widthAnchor constraintEqualToAnchor:right.widthAnchor],
    [heroNote.widthAnchor constraintEqualToAnchor:right.widthAnchor],
  ]];
  [right setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

  // ── cards
  _cards = [NSMutableArray new];
  NSStackView* cardRow = [NSStackView new];
  cardRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  cardRow.distribution = NSStackViewDistributionFillEqually;
  cardRow.alignment = NSLayoutAttributeHeight;
  cardRow.spacing = 12;
  struct CardDef { Mode m; NSColor* tint; };
  CardDef defs[] = {{Mode::Reclaim, kBucketColors[HOT]},
                    {Mode::Forgotten, kBucketColors[STALE]},
                    {Mode::BigFiles, kBucketColors[COLD]},
                    {Mode::Apps, kRingColors[9]}};
  for (const CardDef& d : defs) {
    CardView* c = [[CardView alloc] initWithMode:d.m tint:d.tint];
    c.target = self;
    c.action = @selector(cardClicked:);
    [_cards addObject:c];
    [cardRow addView:c inGravity:NSStackViewGravityLeading];
  }

  // ── biggest folders
  _topTitle = label(@"BIGGEST FOLDERS", 11, NSFontWeightSemibold, NSColor.tertiaryLabelColor);
  _topList = [NSStackView new];
  _topList.orientation = NSUserInterfaceLayoutOrientationVertical;
  _topList.alignment = NSLayoutAttributeLeading;
  _topList.spacing = 0;
  _topSurface = [[SurfaceView alloc] initWithFrame:NSZeroRect];
  pin(_topList, _topSurface, NSEdgeInsetsMake(6, 8, 6, 8));

  NSStackView* stack = [NSStackView stackViewWithViews:@[ hero, cardRow, _topTitle, _topSurface ]];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = 16;
  [stack setCustomSpacing:24 afterView:cardRow];
  [stack setCustomSpacing:8 afterView:_topTitle];
  stack.edgeInsets = NSEdgeInsetsMake(2, 0, 20, 0);

  _overviewScroll = [NSScrollView new];
  _overviewScroll.drawsBackground = NO;
  _overviewScroll.hasVerticalScroller = YES;
  FlippedView* doc = [FlippedView new];
  _overviewScroll.documentView = doc;
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  doc.translatesAutoresizingMaskIntoConstraints = NO;
  [doc addSubview:stack];
  NSClipView* clip = _overviewScroll.contentView;
  [NSLayoutConstraint activateConstraints:@[
    [doc.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor],
    [doc.trailingAnchor constraintEqualToAnchor:clip.trailingAnchor],
    [doc.topAnchor constraintEqualToAnchor:clip.topAnchor],
    [doc.widthAnchor constraintEqualToAnchor:clip.widthAnchor],
    [stack.leadingAnchor constraintEqualToAnchor:doc.leadingAnchor],
    [stack.trailingAnchor constraintEqualToAnchor:doc.trailingAnchor],
    [stack.topAnchor constraintEqualToAnchor:doc.topAnchor],
    [stack.bottomAnchor constraintEqualToAnchor:doc.bottomAnchor],
    [hero.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
    [cardRow.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
    [_topSurface.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
  ]];
}

- (void)buildList {
  _outline = [FileOutlineView new];
  _outline.dataSource = self;
  _outline.delegate = self;
  _outline.allowsMultipleSelection = YES;
  _outline.usesAlternatingRowBackgroundColors = NO;
  _outline.gridStyleMask = NSTableViewSolidHorizontalGridLineMask;
  _outline.gridColor = [NSColor.separatorColor colorWithAlphaComponent:0.35];
  _outline.rowHeight = 28;
  _outline.style = NSTableViewStyleInset;
  _outline.autoresizesOutlineColumn = YES;
  _outline.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
  _outline.doubleAction = @selector(doubleClicked:);
  _outline.target = self;
  _outline.autosaveTableColumns = YES;
  _outline.autosaveName = @"StaleColumns2";
  _outline.menu = [self makeContextMenu];

  struct Col { NSString* id; NSString* title; CGFloat w; CGFloat minW; NSString* sortKey; };
  Col cols[] = {{@"name", @"Name", 320, 180, @"name"},
                {@"size", @"Size", 110, 90, @"size"},
                {@"used", @"Last used", 160, 130, @"lastUsed"},
                {@"note", @"What is it", 260, 120, nil}};
  for (const Col& c : cols) {
    NSTableColumn* col = [[NSTableColumn alloc] initWithIdentifier:c.id];
    col.title = c.title;
    col.width = c.w;
    col.minWidth = c.minW;
    if (c.sortKey)
      col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:c.sortKey
                                                                  ascending:[c.sortKey isEqual:@"name"]];
    if ([c.id isEqual:@"size"]) col.headerCell.alignment = NSTextAlignmentRight;
    [_outline addTableColumn:col];
  }
  _outline.outlineTableColumn = _outline.tableColumns[0];
  _outline.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"size" ascending:NO] ];

  _scroll = [NSScrollView new];
  _scroll.documentView = _outline;
  _scroll.hasVerticalScroller = YES;
  _scroll.borderType = NSNoBorder;
  _scroll.wantsLayer = YES;
  _scroll.layer.cornerRadius = 10;
  _scroll.layer.masksToBounds = YES;

  _emptyIcon = [NSImageView imageViewWithImage:symbol(@"checkmark.circle", 40, NSFontWeightLight)];
  _emptyIcon.contentTintColor = NSColor.tertiaryLabelColor;
  _emptyTitle = label(@"", 15, NSFontWeightSemibold, NSColor.secondaryLabelColor);
  _emptyTitle.alignment = NSTextAlignmentCenter;
  _emptyHint = [NSTextField wrappingLabelWithString:@""];
  _emptyHint.font = [NSFont systemFontOfSize:12];
  _emptyHint.textColor = NSColor.tertiaryLabelColor;
  _emptyHint.alignment = NSTextAlignmentCenter;
  _emptyHint.selectable = NO;
  _emptySpinner = [NSProgressIndicator new];
  _emptySpinner.style = NSProgressIndicatorStyleBar;
  _emptySpinner.controlSize = NSControlSizeSmall;
  _emptySpinner.indeterminate = YES;
  _emptySpinner.minValue = 0;
  _emptySpinner.maxValue = 1;
  _emptySpinner.hidden = YES;
  fixSize(_emptySpinner, 240, 0);
  NSStackView* es = [NSStackView stackViewWithViews:@[ _emptyIcon, _emptyTitle, _emptyHint, _emptySpinner ]];
  es.orientation = NSUserInterfaceLayoutOrientationVertical;
  es.spacing = 6;
  [es setCustomSpacing:12 afterView:_emptyIcon];
  [es setCustomSpacing:14 afterView:_emptyHint];
  es.translatesAutoresizingMaskIntoConstraints = NO;
  _empty = [NSView new];
  [_empty addSubview:es];
  [NSLayoutConstraint activateConstraints:@[
    [es.centerXAnchor constraintEqualToAnchor:_empty.centerXAnchor],
    [es.centerYAnchor constraintEqualToAnchor:_empty.centerYAnchor constant:-16],
    [_emptyHint.widthAnchor constraintLessThanOrEqualToConstant:380],
  ]];
  _empty.hidden = YES;

  _listBox = [NSView new];
  for (NSView* v in @[ _scroll, _empty ]) pin(v, _listBox, NSEdgeInsetsMake(0, 0, 0, 0));

  // ── bottom bar
  _status = label(@"Select folders or files to move them to the Trash.", 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
  _status.lineBreakMode = NSLineBreakByTruncatingMiddle;
  _revealButton = [NSButton buttonWithTitle:@"Reveal in Finder" target:self action:@selector(revealSelected:)];
  _trashButton = [NSButton buttonWithTitle:@"Move to Trash…" target:self action:@selector(trashSelected:)];
  _trashButton.keyEquivalent = @"";
  _trashButton.bezelColor = NSColor.controlAccentColor;
  _revealButton.enabled = _trashButton.enabled = NO;
  _emptyTrashButton = [NSButton buttonWithTitle:@"Empty Trash…" target:self action:@selector(emptyTrash:)];
  _emptyTrashButton.hidden = YES;
  NSStackView* bottom = [NSStackView stackViewWithViews:@[ _status, _revealButton, _trashButton, _emptyTrashButton ]];
  bottom.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  bottom.spacing = 10;
  [_status setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
  [_status setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
  _bottom = bottom;
}

- (void)buildFirstRun {
  NSImageView* icon = [NSImageView imageViewWithImage:symbol(@"internaldrive.fill", 44, NSFontWeightRegular)];
  icon.contentTintColor = NSColor.controlAccentColor;
  _firstRunTitle = label(@"Indexing your Mac", 20, NSFontWeightSemibold, NSColor.labelColor);
  _firstRunTitle.alignment = NSTextAlignmentCenter;
  _firstRunTitle.font = roundedFont(20, NSFontWeightSemibold);
  _firstRunCount = label(@"", 13, NSFontWeightMedium, NSColor.secondaryLabelColor);
  _firstRunCount.font = monoDigits(13, NSFontWeightMedium);
  _firstRunCount.alignment = NSTextAlignmentCenter;
  _firstRunSpinner = [NSProgressIndicator new];
  _firstRunSpinner.style = NSProgressIndicatorStyleBar;
  _firstRunSpinner.indeterminate = YES;
  _firstRunSpinner.controlSize = NSControlSizeSmall;
  fixSize(_firstRunSpinner, 260, 0);
  NSTextField* hint = [NSTextField wrappingLabelWithString:
      @"This happens once. Stale remembers the result, so the next launch is instant — "
      @"re-index whenever you like with the Rescan button."];
  hint.font = [NSFont systemFontOfSize:12];
  hint.textColor = NSColor.tertiaryLabelColor;
  hint.alignment = NSTextAlignmentCenter;
  hint.selectable = NO;
  NSButton* stop = [NSButton buttonWithTitle:@"Stop" target:self action:@selector(cancelScan:)];
  stop.controlSize = NSControlSizeSmall;
  stop.font = [NSFont systemFontOfSize:11];
  NSStackView* col = [NSStackView stackViewWithViews:@[ icon, _firstRunTitle, _firstRunCount, _firstRunSpinner, hint, stop ]];
  col.orientation = NSUserInterfaceLayoutOrientationVertical;
  col.spacing = 8;
  [col setCustomSpacing:16 afterView:icon];
  [col setCustomSpacing:14 afterView:_firstRunCount];
  [col setCustomSpacing:14 afterView:_firstRunSpinner];
  [col setCustomSpacing:18 afterView:hint];
  col.translatesAutoresizingMaskIntoConstraints = NO;
  _firstRun = [NSView new];
  [_firstRun addSubview:col];
  [NSLayoutConstraint activateConstraints:@[
    [col.centerXAnchor constraintEqualToAnchor:_firstRun.centerXAnchor],
    [col.centerYAnchor constraintEqualToAnchor:_firstRun.centerYAnchor constant:-24],
    [hint.widthAnchor constraintLessThanOrEqualToConstant:400],
    [_firstRunTitle.widthAnchor constraintLessThanOrEqualToConstant:520],
  ]];
  _firstRun.hidden = YES;
}

- (NSView*)makeBanner {
  NSImageView* icon = [NSImageView imageViewWithImage:symbol(@"lock.shield.fill", 14, NSFontWeightMedium)];
  icon.contentTintColor = kBucketColors[STALE];
  NSTextField* text = [NSTextField wrappingLabelWithString:
      @"Some folders couldn't be read (Mail, Safari, Messages…). Give Stale Full Disk Access, then Rescan, to see everything."];
  text.font = [NSFont systemFontOfSize:12];
  text.selectable = NO;
  NSButton* open = [NSButton buttonWithTitle:@"Open Privacy Settings" target:self action:@selector(openFDA:)];
  open.controlSize = NSControlSizeSmall;
  open.font = [NSFont systemFontOfSize:11];
  NSStackView* row = [NSStackView stackViewWithViews:@[ icon, text, open ]];
  row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  row.spacing = 10;
  row.edgeInsets = NSEdgeInsetsMake(8, 12, 8, 10);
  row.wantsLayer = YES;
  row.layer.backgroundColor = [kBucketColors[STALE] colorWithAlphaComponent:0.12].CGColor;
  row.layer.cornerRadius = 10;
  [text setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
  return row;
}

- (NSMenu*)makeContextMenu {
  NSMenu* m = [NSMenu new];
  m.delegate = self;
  [m addItemWithTitle:@"Open" action:@selector(openSelected:) keyEquivalent:@""];
  [m addItemWithTitle:@"Quick Look" action:@selector(togglePreview:) keyEquivalent:@""];
  [m addItemWithTitle:@"Reveal in Finder" action:@selector(revealSelected:) keyEquivalent:@""];
  [m addItemWithTitle:@"Copy Path" action:@selector(copyPath:) keyEquivalent:@""];
  [m addItem:NSMenuItem.separatorItem];
  [m addItemWithTitle:@"Move to Trash…" action:@selector(trashSelected:) keyEquivalent:@""];
  return m;
}

- (void)menuNeedsUpdate:(NSMenu*)menu {
  // Right-clicking a row that isn't selected acts on that row.
  NSInteger row = _outline.clickedRow;
  if (row >= 0 && ![_outline.selectedRowIndexes containsIndex:(NSUInteger)row])
    [_outline selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
}

// ───── toolbar ─────

- (NSArray<NSToolbarItemIdentifier>*)toolbarDefaultItemIdentifiers:(NSToolbar*)tb {
  return @[
    NSToolbarToggleSidebarItemIdentifier, NSToolbarSidebarTrackingSeparatorItemIdentifier, @"folder", @"rescan",
    NSToolbarFlexibleSpaceItemIdentifier, @"reveal", @"trash"
  ];
}
- (NSArray<NSToolbarItemIdentifier>*)toolbarAllowedItemIdentifiers:(NSToolbar*)tb {
  return [self toolbarDefaultItemIdentifiers:tb];
}
- (NSToolbarItem*)toolbar:(NSToolbar*)tb itemForItemIdentifier:(NSToolbarItemIdentifier)id
    willBeInsertedIntoToolbar:(BOOL)flag {
  struct Def { NSString* id; NSString* label; NSString* symbol; SEL action; };
  Def defs[] = {
      {@"folder", @"Open Folder…", @"folder.badge.plus", @selector(chooseFolder:)},
      {@"rescan", @"Rescan", @"arrow.clockwise", @selector(rescan:)},
      {@"reveal", @"Reveal in Finder", @"magnifyingglass", @selector(revealSelected:)},
      {@"trash", @"Move to Trash", @"trash", @selector(trashSelected:)},
  };
  for (const Def& d : defs) {
    if (![id isEqual:d.id]) continue;
    NSToolbarItem* it = [[NSToolbarItem alloc] initWithItemIdentifier:id];
    it.target = self;
    it.label = d.label;
    it.paletteLabel = d.label;
    it.toolTip = d.label;
    it.image = [NSImage imageWithSystemSymbolName:d.symbol accessibilityDescription:d.label];
    it.action = d.action;
    it.bordered = YES;
    return it;
  }
  return nil;
}

- (BOOL)validateToolbarItem:(NSToolbarItem*)item {
  if (item.action == @selector(trashSelected:)) return _mode != Mode::Trash && [self selectedItems].count > 0;
  if (item.action == @selector(revealSelected:)) return [self selectedItems].count > 0;
  if ([item.itemIdentifier isEqual:@"rescan"]) {
    // Doubles as the Stop button while indexing.
    BOOL busy = _scanning;
    item.label = item.toolTip = busy ? @"Stop Indexing" : @"Rescan";
    item.image = [NSImage imageWithSystemSymbolName:busy ? @"stop.circle" : @"arrow.clockwise" accessibilityDescription:item.label];
    item.action = busy ? @selector(cancelScan:) : @selector(rescan:);
    return !_loading;
  }
  return !_scanning && !_loading;
}

- (BOOL)validateMenuItem:(NSMenuItem*)item {
  SEL a = item.action;
  if (a == @selector(trashSelected:)) return _mode != Mode::Trash && [self selectedItems].count > 0;
  if (a == @selector(revealSelected:) || a == @selector(copyPath:) || a == @selector(openSelected:) ||
      a == @selector(togglePreview:))
    return [self selectedItems].count > 0;
  if (a == @selector(emptyTrash:)) return !_scanning && !_loading && !_finderUnreadable[(int)Mode::Trash];
  if (a == @selector(modeFromMenu:)) item.state = item.tag == (NSInteger)_mode ? NSControlStateValueOn : NSControlStateValueOff;
  if (a == @selector(cancelScan:)) return _scanning;
  if (a == @selector(rescan:) || a == @selector(chooseFolder:) || a == @selector(openHome:) || a == @selector(openDisk:))
    return !_scanning && !_loading;
  return YES;
}

- (void)toggleSidebar:(id)sender { [_split toggleSidebar:sender]; }
- (void)openGitHub:(id)sender {
  [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/HustleCoding/stale"]];
}
- (void)openFDA:(id)sender {
  [[NSWorkspace sharedWorkspace]
      openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"]];
}
- (void)revealIndex:(id)sender {
  NSString* dir = ns_str(indexDir());
  [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
  [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[ [NSURL fileURLWithPath:dir] ]];
}

// ───── indexing ─────

- (void)chooseFolder:(id)sender {
  NSOpenPanel* p = [NSOpenPanel openPanel];
  p.canChooseDirectories = YES;
  p.canChooseFiles = NO;
  p.allowsMultipleSelection = NO;
  p.prompt = @"Open";
  p.message = @"Choose a folder to analyse. Stale indexes it once and remembers the result.";
  p.directoryURL = [NSURL fileURLWithPath:ns_str(_scanPath.empty() ? std::string("/") : _scanPath)];
  [p beginSheetModalForWindow:_window completionHandler:^(NSModalResponse r) {
    if (r == NSModalResponseOK && p.URL) [self openRoot:std_str(p.URL.path)];
  }];
}

- (void)openDisk:(id)sender { [self openRoot:"/"]; }
- (void)openHome:(id)sender { [self openRoot:std_str(NSHomeDirectory())]; }
- (void)rescan:(id)sender { if (!_scanPath.empty()) [self scanPath:_scanPath]; }

// Show the saved index for `root` if there is one, otherwise index it now.
- (void)openRoot:(const std::string&)rootRef {
  const std::string root = rootRef;
  if (_cancel) _cancel->store(true);
  int gen = ++_scanGeneration;
  if (_scanning) [self endScanUI];
  _scanPath = root;
  _loading = YES;
  [self updateStatusPill];
  [_window.toolbar validateVisibleItems];
  if (root != _resultPath) {
    // A different root: drop the old model rather than show it under a new title.
    [self clearModel];
    [self showMode:_mode];
  }
  std::string home = std_str(NSHomeDirectory());
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    auto res = std::make_shared<ScanResult>();
    IndexMeta meta;
    bool ok = loadIndex(indexPath(root), root, *res, &meta);
    AppSources apps;
    if (ok) apps = resolveApps(res, home, nullptr);
    // fseventsd rebuilt its database (or the disk was replaced): the saved position means
    // nothing, so the index has to be rebuilt. The old one stays on screen meanwhile.
    bool stalePosition = ok && (meta.eventId == 0 || meta.volumeUUIDs != volumeUUIDs(root));
    dispatch_async(dispatch_get_main_queue(), ^{
      if (gen != self->_scanGeneration) return;
      self->_loading = NO;
      if (ok) [self installResult:res apps:apps meta:meta];
      if (!ok || stalePosition) [self scanPath:root];
    });
  });
}

- (void)scanPath:(const std::string&)pathRef {
  const std::string path = pathRef;  // the async block below needs its own copy
  if (_cancel) _cancel->store(true);  // stop any scan in flight; its result is dropped by generation check
  int gen = ++_scanGeneration;
  _scanPath = path;
  _loading = NO;
  _progress = std::make_shared<std::atomic<uint64_t>>(0);
  _cancel = std::make_shared<std::atomic<bool>>(false);
  _scanning = YES;
  if (path != _resultPath) [self clearModel];

  BOOL haveOld = _model.result && !_model.result->dirs.empty();
  _firstRunTitle.stringValue = [NSString stringWithFormat:@"Indexing %@", [self titleForRoot:path]];
  _firstRunCount.stringValue = @"Starting…";
  if (!haveOld) {
    [_firstRunSpinner startAnimation:nil];
    [self showMode:_mode];
  }
  [self updateStatusPill];
  [_progressTimer invalidate];
  __weak StaleController* weakSelf = self;
  _progressTimer = [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:YES block:^(NSTimer*) {
    StaleController* s = weakSelf;
    if (!s || !s->_progress) return;
    NSString* n = fmtCount(s->_progress->load(), @"file");
    s->_firstRunCount.stringValue = n;
    s->_statusText.stringValue = [NSString stringWithFormat:@"Indexing… %@", n];
  }];
  [_window.toolbar validateVisibleItems];

  auto cancelPtr = _cancel;
  auto progressPtr = _progress;
  std::string home = std_str(NSHomeDirectory());
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    // Anything that changes during the scan is replayed from here afterwards.
    IndexMeta meta;
    meta.eventId = currentEventId();
    meta.volumeUUIDs = volumeUUIDs(path);
    ScanOptions o;
    o.root = path;
    o.progressFiles = progressPtr.get();
    o.cancel = cancelPtr.get();
    auto res = std::make_shared<ScanResult>(scan(o));
    if (cancelPtr->load()) return;  // cancelScan already restored the UI
    meta.savedAt = unixNow();
    AppSources apps;
    if (!res->dirs.empty()) {
      saveIndex(indexPath(path), path, *res, meta);  // only complete scans are remembered
      apps = resolveApps(res, home, cancelPtr.get());
    }
    if (cancelPtr->load()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (gen != self->_scanGeneration) return;
      [self installResult:res apps:apps meta:meta];
    });
  });
}

- (void)cancelScan:(id)sender {
  if (!_scanning) return;
  if (_cancel) _cancel->store(true);
  ++_scanGeneration;
  [self endScanUI];
  _scanPath = _resultPath.empty() ? _scanPath : _resultPath;
  [self updateStatusPill];
  if (!_pendingChanges.empty()) [self runRefresh];  // changes queued while the scan ran
  if (!_model.result || _model.result->dirs.empty()) {
    [self showEmpty:@"Indexing stopped"
               hint:@"Nothing was saved. Press Rescan to index, or open a smaller folder."
             symbol:@"stop.circle"];
  }
}

- (void)endScanUI {
  _scanning = NO;
  [_progressTimer invalidate];
  _progressTimer = nil;
  [_firstRunSpinner stopAnimation:nil];
  [_window.toolbar validateVisibleItems];
}

- (void)clearModel {
  [self stopWatching];
  _model = Model();
  _root = nil;
  _flat = @[];
  _appItems = nil;
  _resultPath.clear();
  _fdaBanner.hidden = YES;
  [_outline reloadData];
  for (SidebarEntry* e in _entries) e.badge = nil;
  [self reloadSidebarBadges];
}

- (void)installResult:(std::shared_ptr<ScanResult>)res apps:(AppSources)apps meta:(const IndexMeta&)meta {
  [self endScanUI];
  [self stopWatching];
  _resultPath = _scanPath;
  _model.result = res;
  _model.apps = apps;
  _model.now = unixNow();
  _model.indexedAt = meta.savedAt;
  _model.meta = meta;
  const ScanResult& r = *res;
  if (r.dirs.empty()) {
    _root = nil;
    _flat = @[];
    _appItems = nil;
    [_outline reloadData];
    [self updateStatusPill];
    [self showEmpty:@"Couldn't read this folder"
               hint:[NSString stringWithFormat:@"%@ isn't readable. Try another folder, or grant Full Disk Access.",
                                               ns_str(_scanPath).stringByAbbreviatingWithTildeInPath]
             symbol:@"exclamationmark.triangle"];
    return;
  }
  _root = [self itemForDir:0 parent:nil];
  _fdaBanner.hidden = r.errors < 20;
  _appItems = nil;
  [self dropFinderResults:YES];
  [self refreshSummary];
  [self showMode:_mode];
  [self startWatching];
  [self updateStatusPill];
}

// Forget finder results so the next visit recomputes them. Duplicates are expensive (they
// hash files), so a small incremental refresh keeps them; a new index drops everything.
- (void)dropFinderResults:(BOOL)all {
  for (int i = 0; i < (int)Mode::Count; ++i) {
    if (!isFinderMode((Mode)i)) continue;
    // The page on screen keeps its rows (they're filtered against the disk anyway) rather
    // than flashing on every live update.
    if (!all && ((Mode)i == Mode::Duplicates || (Mode)i == _mode || _finderRunning[i])) continue;
    _finderItems[i] = nil;
  }
  if (!all) return;
  if (_finderCancel) _finderCancel->store(true);
  _finderCancel = nullptr;
  for (int i = 0; i < (int)Mode::Count; ++i) _finderRunning[i] = NO;
  ++_finderGeneration;
}

// ───── keeping the index fresh ─────

- (void)stopWatching {
  ++_watchGeneration;
  _watcher.reset();
  [_refreshTimer invalidate];
  _refreshTimer = nil;
  _pendingChanges.clear();
  _pendingEventId = 0;
  _historyDone = NO;
}

// Replay what changed since the index was saved, then follow the disk live.
- (void)startWatching {
  [self stopWatching];
  if (!_model.result || _model.result->dirs.empty() || _model.meta.eventId == 0) return;
  if (!_fsQueue) _fsQueue = dispatch_queue_create("app.stale.fsevents", DISPATCH_QUEUE_SERIAL);
  int gen = _watchGeneration;
  __weak StaleController* weakSelf = self;
  _watcher = std::make_unique<FsWatcher>(_resultPath, _model.meta.eventId, 2.0, _fsQueue, [weakSelf, gen](FsBatch b) {
    // Batches arrive on _fsQueue; the model is only touched on the main thread.
    auto shared = std::make_shared<FsBatch>(std::move(b));
    dispatch_async(dispatch_get_main_queue(), ^{
      StaleController* s = weakSelf;
      if (s && gen == s->_watchGeneration) [s fsBatch:*shared];
    });
  });
  if (!_watcher->running()) _watcher.reset();
}

- (void)fsBatch:(FsBatch&)b {
  if (b.needFullScan) {
    if (!_scanning) [self scanPath:_resultPath];  // a scan already running will pick up the new position
    return;
  }
  if (b.historyDone) _historyDone = YES;
  // Writing our own index file is a change too; following it would re-read and re-write forever.
  std::string own = indexDir();
  for (auto& c : b.changes) {
    c.path = normalizeEventPath(std::move(c.path));
    if (c.subtree || c.path != own) _pendingChanges.push_back(std::move(c));
  }
  _pendingEventId = std::max(_pendingEventId, b.lastEventId);
  [_refreshTimer invalidate];
  __weak StaleController* weakSelf = self;
  // During the replay events arrive in quick succession; wait for a lull before re-reading.
  _refreshTimer = [NSTimer scheduledTimerWithTimeInterval:_historyDone ? 0.3 : 0.8 repeats:NO block:^(NSTimer*) {
    StaleController* s = weakSelf;
    if (!s) return;
    s->_refreshTimer = nil;
    [s runRefresh];
  }];
  [self updateStatusPill];
}

- (void)runRefresh {
  if (_scanning || _loading || _refreshing || !_model.result || _model.result->dirs.empty()) return;
  if (_pendingChanges.empty()) {
    [self updateStatusPill];
    return;
  }
  std::vector<RefreshRequest> changes = std::move(_pendingChanges);
  _pendingChanges.clear();
  uint64_t eventId = _pendingEventId;
  RefreshPlan plan = planRefresh(*_model.result, std::move(changes));
  if (plan.tooMuch) {
    [self scanPath:_resultPath];
    return;
  }
  if (plan.jobs.empty()) {
    if (eventId > _model.meta.eventId) {
      _model.meta.eventId = eventId;
      [self persistIndexAfter:30];
    }
    [self updateStatusPill];
    return;
  }
  _refreshing = YES;
  _refreshStarted = CACurrentMediaTime();
  [self updateStatusPill];
  // Small live updates finish in milliseconds and shouldn't flicker the pill; long ones show.
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateStatusPill) object:nil];
  [self performSelector:@selector(updateStatusPill) withObject:nil afterDelay:1.0];
  int gen = _watchGeneration;
  auto res = _model.result;  // spotlight is only written by applyRefresh, which waits for us
  auto planPtr = std::make_shared<RefreshPlan>(std::move(plan));
  std::string root = _resultPath;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    ScanOptions o;
    o.root = root;
    auto patch = std::make_shared<RefreshPatch>(collectRefresh(o, *planPtr, res->spotlight));
    dispatch_async(dispatch_get_main_queue(), ^{
      self->_refreshing = NO;
      if (gen != self->_watchGeneration || self->_model.result != res) return;
      std::unordered_set<int32_t> touched;
      for (const RefreshJob& j : planPtr->jobs) touched.insert(j.id);
      if (applyRefresh(*res, std::move(*patch))) {
        self->_model.meta.eventId = std::max(self->_model.meta.eventId, eventId);
        [self modelChanged:touched];
        [self persistIndexAfter:30];
      }
      if (!self->_pendingChanges.empty()) [self runRefresh];
      else [self updateStatusPill];
    });
  });
}

// The scan model changed underneath the UI (refresh or trash): bring items and pages in line
// while keeping expansion, selection and scroll position.
- (void)modelChanged:(const std::unordered_set<int32_t>&)touched {
  const ScanResult& r = *_model.result;
  _fdaBanner.hidden = r.errors < 20;
  _appItems = nil;
  if (!isFinderMode(_mode) || !_finderRunning[(int)_mode]) [self dropFinderResults:NO];
  NSMutableSet<NSString*>* selected = [NSMutableSet new];
  for (Item* it in [self selectedItems]) [selected addObject:it.path];
  if (_root) [self syncItem:_root touched:touched];
  if (_mode != Mode::Browse && _mode != Mode::Overview) _flat = [self flatItemsForMode:_mode];
  [self refreshSummary];
  if (_mode != Mode::Overview) {
    [_outline reloadData];
    NSMutableIndexSet* rows = [NSMutableIndexSet new];
    for (NSInteger i = 0; i < _outline.numberOfRows; ++i)
      if ([selected containsObject:((Item*)[_outline itemAtRow:i]).path]) [rows addIndex:(NSUInteger)i];
    [_outline selectRowIndexes:rows byExtendingSelection:NO];
    [self selectionChanged];
    BOOL empty = [self topItems].count == 0;
    if (empty != _scroll.hidden) [self showMode:_mode];
  }
}

// Update a loaded item (and its loaded descendants) from the model; re-list the files of
// folders that were re-read.
- (void)syncItem:(Item*)it touched:(const std::unordered_set<int32_t>&)touched {
  const ScanResult& r = *_model.result;
  if (it.dirId >= 0) {
    const DirNode& d = r.dirs[(size_t)it.dirId];
    it.size = d.size;
    it.files = d.files;
    it.lastUsed = d.lastUsed;
    it.category = d.category;
    it.never = d.size > 0 && d.neverOpenedSize * 2 > d.size;
  }
  if (!it.children) return;
  BOOL relist = it.dirId >= 0 && touched.count(it.dirId) > 0;
  NSMutableArray<Item*>* kids = [NSMutableArray new];
  std::unordered_set<int32_t> present;
  for (Item* k in it.children) {
    if (k.dirId >= 0) {
      if (r.dirs[(size_t)k.dirId].path.empty()) continue;  // gone
      present.insert(k.dirId);
      [self syncItem:k touched:touched];
      [kids addObject:k];
    } else if (!relist && access(k.path.fileSystemRepresentation, F_OK) == 0) {
      [kids addObject:k];
    }
  }
  if (it.dirId >= 0)
    for (int32_t c : r.dirs[(size_t)it.dirId].children)
      if (!r.dirs[(size_t)c].path.empty() && !present.count(c)) [kids addObject:[self itemForDir:c parent:it]];
  if (relist) [kids addObjectsFromArray:[self fileItemsIn:it]];
  [self sortItems:kids];
  it.children = kids;
}

- (NSString*)titleForRoot:(const std::string&)root {
  if (root == "/") return displayName(@"/");
  if (root == std_str(NSHomeDirectory())) return @"Home";
  return displayName(ns_str(root));
}
- (NSString*)scanTitle { return [self titleForRoot:_resultPath]; }

- (void)updateStatusPill {
  BOOL have = _model.result && !_model.result->dirs.empty();
  if (_scanning) {
    _statusPill.hidden = NO;
    _statusIcon.hidden = YES;
    [_statusSpinner startAnimation:nil];
    _statusStop.hidden = NO;
    _statusText.stringValue = @"Indexing…";
    _statusPill.toolTip = @"Your existing index stays until this finishes.";
  } else if (_loading) {
    _statusPill.hidden = NO;
    _statusIcon.hidden = YES;
    [_statusSpinner startAnimation:nil];
    _statusStop.hidden = YES;
    _statusText.stringValue = @"Opening index…";
    _statusPill.toolTip = @"";
  } else if (have && _watcher &&
             (!_historyDone || (_refreshing && CACurrentMediaTime() - _refreshStarted >= 1.0))) {
    _statusPill.hidden = NO;
    _statusIcon.hidden = YES;
    [_statusSpinner startAnimation:nil];
    _statusStop.hidden = YES;
    _statusText.stringValue = @"Updating…";
    _statusPill.toolTip = @"Re-reading the folders that changed since the index was saved.";
  } else if (have) {
    const ScanResult& r = *_model.result;
    BOOL live = _watcher != nullptr;
    _statusPill.hidden = NO;
    _statusIcon.hidden = NO;
    _statusIcon.image = symbol(live ? @"checkmark.circle.fill" : @"clock", 11, NSFontWeightSemibold);
    _statusIcon.contentTintColor = live ? NSColor.systemGreenColor : NSColor.secondaryLabelColor;
    [_statusSpinner stopAnimation:nil];
    _statusStop.hidden = YES;
    _statusText.stringValue = live ? @"Up to date" : [NSString stringWithFormat:@"Indexed %@", fmtIndexedAgo(_model.indexedAt, unixNow())];
    _statusPill.toolTip = [NSString stringWithFormat:@"%@%@\n%@ · scanned in %.1f s%@\nRescan (⌘R) to rebuild from scratch.",
                                                     live ? @"Following changes on the disk. Indexed " : @"Indexed ",
                                                     fmtDateTime(_model.indexedAt), fmtCount(r.dirs[0].files, @"file"), r.seconds,
                                                     r.errors ? [NSString stringWithFormat:@" · %@ unreadable", fmtCount(r.errors, @"folder")] : @""];
  } else {
    _statusPill.hidden = YES;
    [_statusSpinner stopAnimation:nil];
  }
  _window.subtitle = have ? [self summaryLine] : (_scanning ? @"Indexing…" : @"");
}

- (NSString*)summaryLine {
  const DirNode& root = _model.result->dirs[0];
  return [NSString stringWithFormat:@"%@  ·  %@  ·  %@", ns_str(_resultPath).stringByAbbreviatingWithTildeInPath,
                                    fmtBytes(root.size), fmtCount(root.files, @"file")];
}

// ───── persistence after edits ─────

// Trashing edits the in-memory model; write it back so the next launch matches. Debounced,
// encoded on the main thread (tens of ms) and written off it.
- (void)persistIndexSoon { [self persistIndexAfter:1.5]; }

// Live updates are written lazily (the disk changes all the time, the index is tens of MB); an
// earlier deadline already pending is kept.
- (void)persistIndexAfter:(NSTimeInterval)delay {
  if (_persistTimer && _persistTimer.fireDate.timeIntervalSinceNow <= delay) return;
  [_persistTimer invalidate];
  __weak StaleController* weakSelf = self;
  _persistTimer = [NSTimer scheduledTimerWithTimeInterval:delay repeats:NO block:^(NSTimer*) {
    StaleController* s = weakSelf;
    if (!s) return;
    s->_persistTimer = nil;
    [s persistIndexNow];
  }];
}

- (void)persistIndexNow {
  if (!_model.result || _model.result->dirs.empty() || _resultPath.empty()) return;
  IndexMeta meta = _model.meta;
  meta.savedAt = _model.indexedAt;
  std::string bytes = encodeIndex(_resultPath, *_model.result, meta);
  std::string file = indexPath(_resultPath);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ writeIndex(file, bytes); });
}

// ───── summary ─────

// Ring, bar, legend, cards, sidebar badges, biggest folders; recomputed after a scan and after trashing.
- (void)refreshSummary {
  const ScanResult& r = *_model.result;
  const DirNode& root = r.dirs[0];

  _window.subtitle = [self summaryLine];
  [self rebuildRing];

  std::vector<double> parts;
  for (int b = 0; b < NBUCKETS; ++b) parts.push_back((double)root.bucketSize[b]);
  _bar.parts = parts;

  for (NSView* v in [_legend.views copy]) [_legend removeView:v];
  for (int b = 0; b <= NBUCKETS; ++b) {
    uint64_t bytes = b < NBUCKETS ? root.bucketSize[b] : root.neverOpenedSize;
    double pct = root.size ? 100.0 * bytes / root.size : 0;
    NSView* row = [self legendRow:b bytes:bytes pct:pct];
    [_legend addView:row inGravity:NSStackViewGravityTop];
  }

  // Flat lists for the other modes.
  std::vector<int32_t> ids;
  collectUnits(r, 0, ids, [](const DirNode& d) { return categoryReclaimable(d.category); });
  uint64_t reclaimBytes = 0;
  for (int32_t i : ids) reclaimBytes += r.dirs[i].size;
  std::vector<int32_t> forgotten;
  collectForgotten(r, 0, forgotten, 50ull << 20);
  uint64_t forgottenBytes = 0;
  for (int32_t i : forgotten) forgottenBytes += r.dirs[i].size;
  uint64_t bigBytes = 0;
  size_t bigCount = 0;
  for (const FileRec& f : r.bigFiles)
    if (f.size >= kBigFileReport && bucketFor(f.lastUsed, _model.now) >= STALE) { bigBytes += f.size; ++bigCount; }
  if (!_appItems) [self buildAppItems];
  uint64_t appBytes = 0, unusedAppBytes = 0;
  size_t unusedApps = 0;
  for (Item* it in _appItems) {
    appBytes += it.size;
    if (it.lastUsed <= 0 || bucketFor(it.lastUsed, _model.now) >= STALE) { unusedAppBytes += it.size; ++unusedApps; }
  }

  auto card = [&](Mode m) -> CardView* {
    for (CardView* c in _cards) if (c.mode == m) return c;
    return nil;
  };
  card(Mode::Reclaim).valueLabel.stringValue = fmtBytes(reclaimBytes);
  card(Mode::Reclaim).detailLabel.stringValue =
      ids.empty() ? @"Nothing regenerable found." : [NSString stringWithFormat:@"%@ you can delete and regenerate.", fmtCount(ids.size(), @"folder")];
  card(Mode::Forgotten).valueLabel.stringValue = fmtBytes(forgottenBytes);
  card(Mode::Forgotten).detailLabel.stringValue =
      forgotten.empty() ? @"Everything big was used recently." : [NSString stringWithFormat:@"%@ untouched for 6+ months.", fmtCount(forgotten.size(), @"folder")];
  card(Mode::BigFiles).valueLabel.stringValue = fmtBytes(bigBytes);
  card(Mode::BigFiles).detailLabel.stringValue =
      bigCount == 0 ? @"No big files gathering dust." : [NSString stringWithFormat:@"%@ over 100 MB, unused 6+ months.", fmtCount(bigCount, @"file")];
  card(Mode::Apps).valueLabel.stringValue = fmtBytes(appBytes);
  card(Mode::Apps).detailLabel.stringValue =
      unusedApps ? [NSString stringWithFormat:@"%@ (%@) not launched in 6+ months.", fmtCount(unusedApps, @"app"), fmtBytes(unusedAppBytes)]
                 : [NSString stringWithFormat:@"%@ installed.", fmtCount(_appItems.count, @"app")];

  for (SidebarEntry* e in _entries) {
    if (e.isGroup) continue;
    switch (e.mode) {
      case Mode::Browse: e.badge = fmtBytes(root.size); break;
      case Mode::Reclaim: e.badge = fmtBytes(reclaimBytes); break;
      case Mode::Forgotten: e.badge = fmtBytes(forgottenBytes); break;
      case Mode::BigFiles: e.badge = fmtBytes(bigBytes); break;
      case Mode::Apps: e.badge = fmtBytes(appBytes); break;
      default: if (!isFinderMode(e.mode)) e.badge = nil;
    }
  }
  [self reloadSidebarBadges];

  // Biggest top-level folders.
  for (NSView* v in [_topList.views copy]) [_topList removeView:v];
  std::vector<int32_t> kids;
  for (int32_t c : root.children) if (!r.dirs[c].path.empty() && r.dirs[c].size > 0) kids.push_back(c);
  std::sort(kids.begin(), kids.end(), [&](int32_t a, int32_t b) { return r.dirs[a].size > r.dirs[b].size; });
  if (kids.size() > 8) kids.resize(8);
  for (size_t i = 0; i < kids.size(); ++i) {
    if (i) {
      HairlineView* h = [HairlineView new];
      fixSize(h, 0, 1);
      [_topList addView:h inGravity:NSStackViewGravityTop];
      [h.widthAnchor constraintEqualToAnchor:_topList.widthAnchor constant:-8].active = YES;
    }
    NSView* row = [self topRow:r.dirs[kids[i]] total:root.size];
    [_topList addView:row inGravity:NSStackViewGravityTop];
    [row.widthAnchor constraintEqualToAnchor:_topList.widthAnchor].active = YES;
  }
  _topTitle.hidden = _topSurface.hidden = kids.empty();
}

- (void)reloadSidebarBadges {
  // Refresh badges in place; reloadData would drop the selection and bounce the mode.
  if (_sidebar.numberOfRows == 0) [_sidebar reloadData];
  else [_sidebar reloadDataForRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, (NSUInteger)_sidebar.numberOfRows)]
                           columnIndexes:[NSIndexSet indexSetWithIndex:0]];
  [self syncSidebar];
}

- (void)rebuildRing {
  const ScanResult& r = *_model.result;
  const DirNode& root = r.dirs[0];
  std::vector<RingSeg> segs;
  uint64_t total = root.size;
  if (total == 0) {
    _ring.segs = segs;
    _ring.centerTitle = fmtBytes(0);
    _ring.centerSub = [self scanTitle];
    return;
  }
  auto sortedKids = [&](const DirNode& d) {
    std::vector<int32_t> k;
    for (int32_t c : d.children) if (!r.dirs[c].path.empty() && r.dirs[c].size > 0) k.push_back(c);
    std::sort(k.begin(), k.end(), [&](int32_t a, int32_t b) { return r.dirs[a].size > r.dirs[b].size; });
    return k;
  };
  auto detail = [&](const DirNode& d, uint64_t of) {
    return [NSString stringWithFormat:@"%@ · %.0f%%\n%@", fmtBytes(d.size), 100.0 * d.size / of,
                                      fmtAgo(d.lastUsed, _model.now)];
  };
  const double minFrac = 0.006;  // ~2°; anything thinner is pooled into "everything else"
  double cursor = 0;
  int hue = 0;
  uint64_t other = 0, placed = 0;
  for (int32_t c : sortedKids(root)) {
    const DirNode& d = r.dirs[c];
    double frac = (double)d.size / total;
    if (frac < minFrac || hue >= kRingPalette) { other += d.size; continue; }
    RingSeg s{c, cursor, cursor + frac, 0, hue, 0, displayName(ns_str(d.path)), detail(d, total)};
    segs.push_back(s);
    // Outer ring: this folder's own folders, largest first, remainder = its loose files.
    double sub = cursor;
    uint64_t subPlaced = 0;
    int shade = 0;
    for (int32_t g : sortedKids(d)) {
      const DirNode& gd = r.dirs[g];
      double gf = (double)gd.size / total;
      if (gf < minFrac) break;
      segs.push_back(RingSeg{g, sub, sub + gf, 1, hue, shade++ & 1, ns_str(gd.path).lastPathComponent, detail(gd, d.size)});
      sub += gf;
      subPlaced += gd.size;
    }
    if (d.size > subPlaced) {
      NSString* rest = [NSString stringWithFormat:@"%@ · %.0f%%\nfiles and small folders", fmtBytes(d.size - subPlaced),
                                                  100.0 * (d.size - subPlaced) / d.size];
      segs.push_back(RingSeg{-1, sub, cursor + frac, 1, hue, 0, [NSString stringWithFormat:@"Rest of %@", s.name], rest});
    }
    cursor += frac;
    placed += d.size;
    ++hue;
  }
  if (other > 0) {
    segs.push_back(RingSeg{-1, cursor, cursor + (double)other / total, 0, -1, 0, @"Smaller folders",
                           [NSString stringWithFormat:@"%@ · %.0f%%", fmtBytes(other), 100.0 * other / total]});
    cursor += (double)other / total;
    placed += other;
  }
  if (total > placed) {
    uint64_t loose = total - placed;
    segs.push_back(RingSeg{-1, cursor, 1.0, 0, -1, 1, @"Files here",
                           [NSString stringWithFormat:@"%@ · %.0f%%", fmtBytes(loose), 100.0 * loose / total]});
  }
  _ring.segs = std::move(segs);
  _ring.centerTitle = fmtBytes(total);
  _ring.centerSub = [self scanTitle];
}

- (NSView*)legendRow:(int)bucket bytes:(uint64_t)bytes pct:(double)pct {
  NSView* dot = [NSView new];
  dot.wantsLayer = YES;
  dot.layer.backgroundColor = kBucketColors[bucket].CGColor;
  dot.layer.cornerRadius = 4.5;
  fixSize(dot, 9, 9);
  NSTextField* name = label(kBucketLabels[bucket], 12, NSFontWeightMedium, NSColor.labelColor);
  if (bucket == NBUCKETS) name.textColor = NSColor.secondaryLabelColor;
  fixSize(name, 112, 0);
  NSTextField* val = label(fmtBytes(bytes), 12, NSFontWeightSemibold, NSColor.labelColor);
  val.font = monoDigits(12, NSFontWeightSemibold);
  val.alignment = NSTextAlignmentRight;
  fixSize(val, 78, 0);
  NSTextField* p = label([NSString stringWithFormat:@"%.0f%%", pct], 11, NSFontWeightMedium, NSColor.tertiaryLabelColor);
  p.font = monoDigits(11, NSFontWeightMedium);
  p.alignment = NSTextAlignmentRight;
  fixSize(p, 34, 0);
  NSStackView* row = [NSStackView stackViewWithViews:@[ dot, name, val, p ]];
  row.spacing = 8;
  row.alignment = NSLayoutAttributeCenterY;
  [row setHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
  row.toolTip = bucket == NBUCKETS ? @"Files created and never opened or changed since (overlaps the other buckets)."
                                   : [NSString stringWithFormat:@"Data last used %@.", kBucketLabels[bucket].lowercaseString];
  return row;
}

- (NSView*)topRow:(const DirNode&)d total:(uint64_t)total {
  NSString* path = ns_str(d.path);
  NSImageView* icon = [NSImageView imageViewWithImage:[[NSWorkspace sharedWorkspace] iconForFile:path]];
  fixSize(icon, 20, 20);
  NSTextField* name = label(displayName(path), 13, NSFontWeightMedium, NSColor.labelColor);
  NSString* hint = categoryHint(d.category);
  NSTextField* note = label(hint.length ? categoryTitle(d.category) : fmtCount(d.files, @"file"), 11, NSFontWeightRegular,
                            NSColor.tertiaryLabelColor);
  RecencyBarView* bar = [RecencyBarView new];
  bar.gap = 1;
  std::vector<double> parts;
  for (int b = 0; b < NBUCKETS; ++b) parts.push_back((double)d.bucketSize[b]);
  bar.parts = parts;
  fixSize(bar, std::max(6.0, 150.0 * (total ? (double)d.size / total : 0)), 6);
  NSView* barBox = [NSView new];
  bar.translatesAutoresizingMaskIntoConstraints = NO;
  [barBox addSubview:bar];
  [NSLayoutConstraint activateConstraints:@[
    [barBox.widthAnchor constraintEqualToConstant:150],
    [bar.leadingAnchor constraintEqualToAnchor:barBox.leadingAnchor],
    [bar.centerYAnchor constraintEqualToAnchor:barBox.centerYAnchor],
    [barBox.heightAnchor constraintEqualToConstant:6],
  ]];
  NSTextField* size = label(fmtBytes(d.size), 13, NSFontWeightSemibold, NSColor.labelColor);
  size.font = monoDigits(13, NSFontWeightSemibold);
  size.alignment = NSTextAlignmentRight;
  fixSize(size, 84, 0);
  NSTextField* used = label(fmtAgo(d.lastUsed, _model.now), 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
  used.alignment = NSTextAlignmentRight;
  fixSize(used, 100, 0);
  NSStackView* row = [NSStackView stackViewWithViews:@[ icon, name, note, barBox, size, used ]];
  row.spacing = 10;
  row.edgeInsets = NSEdgeInsetsMake(8, 8, 8, 8);
  for (NSView* v in @[ icon, name, size, used ])
    [v setContentHuggingPriority:NSLayoutPriorityRequired - 1 forOrientation:NSLayoutConstraintOrientationHorizontal];
  [note setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
  [note setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
  [name setContentCompressionResistancePriority:2 forOrientation:NSLayoutConstraintOrientationHorizontal];
  [name.widthAnchor constraintLessThanOrEqualToConstant:320].active = YES;
  row.toolTip = path;
  return row;
}

- (void)buildAppItems {
  _appItems = [NSMutableArray new];
  for (int k = 0; k < 2; ++k) {
    const AppSource& src = _model.apps.s[k];
    if (!src.r || src.r->dirs.empty() || src.dirId < 0) continue;
    const ScanResult& ar = *src.r;
    std::vector<int32_t> appIds;
    collectUnits(ar, src.dirId, appIds, [](const DirNode& d) { return d.category == CAT_APP; });
    for (int32_t i : appIds) {
      const DirNode& d = ar.dirs[i];
      if (d.path.empty() || access(d.path.c_str(), F_OK) != 0) continue;  // gone since the index was made
      Item* it = [Item new];
      it.path = ns_str(d.path);
      it.name = [it.path.lastPathComponent stringByDeletingPathExtension];
      it.size = d.size;
      it.files = d.files;
      it.lastUsed = d.mdLastUsed;
      it.installed = d.lastUsed;
      it.never = d.mdLastUsed <= 0;
      it.isDir = YES;
      it.isApp = YES;
      it.category = CAT_APP;
      it.dirId = src.inMain ? i : -1;  // in-main apps edit the shared model when trashed
      it.children = [NSMutableArray new];  // don't drill into bundles
      [_appItems addObject:it];
    }
  }
}

// ───── items ─────

- (Item*)itemForDir:(int32_t)id parent:(Item*)parent {
  const DirNode& d = _model.result->dirs[id];
  Item* it = [Item new];
  it.path = ns_str(d.path);
  it.name = id == 0 ? it.path : it.path.lastPathComponent;
  it.size = d.size;
  it.files = d.files;
  it.lastUsed = d.lastUsed;
  it.isDir = YES;
  it.category = d.category;
  it.never = d.size > 0 && d.neverOpenedSize * 2 > d.size;
  it.dirId = id;
  it.parent = parent;
  return it;
}

- (Item*)itemForFile:(const std::string&)path size:(uint64_t)sz lastUsed:(double)lu never:(BOOL)never parent:(Item*)parent {
  Item* it = [Item new];
  it.path = ns_str(path);
  it.name = it.path.lastPathComponent;
  it.size = sz;
  it.files = 1;
  it.lastUsed = lu;
  it.never = never;
  it.isDir = NO;
  it.dirId = -1;
  it.parent = parent;
  return it;
}

- (void)loadChildren:(Item*)item {
  if (item.children) return;
  NSMutableArray<Item*>* kids = [NSMutableArray new];
  const ScanResult& r = *_model.result;
  if (item.dirId >= 0) {
    for (int32_t c : r.dirs[item.dirId].children) {
      if (r.dirs[c].path.empty()) continue;
      [kids addObject:[self itemForDir:c parent:item]];
    }
  }
  [kids addObjectsFromArray:[self fileItemsIn:item]];
  item.children = kids;
  [self sortItems:kids];
}

// Files are not kept in the index; list them now.
- (NSArray<Item*>*)fileItemsIn:(Item*)item {
  NSMutableArray<Item*>* kids = [NSMutableArray new];
  const ScanResult& r = *_model.result;
  if (DIR* dp = opendir(item.path.fileSystemRepresentation)) {
    struct stat st;
    while (struct dirent* de = readdir(dp)) {
      if (de->d_name[0] == '.' && (de->d_name[1] == 0 || (de->d_name[1] == '.' && de->d_name[2] == 0))) continue;
      if (fstatat(dirfd(dp), de->d_name, &st, AT_SYMLINK_NOFOLLOW) != 0 || S_ISDIR(st.st_mode)) continue;
      std::string full = std_str(item.path);
      if (full.empty() || full.back() != '/') full += '/';
      full += de->d_name;
      double mt = st.st_mtimespec.tv_sec, lu = mt;
      auto md = r.spotlight.find(full);
      bool hasMd = md != r.spotlight.end();
      if (hasMd) lu = std::max(lu, md->second);
      double birth = st.st_birthtimespec.tv_sec;
      bool never = !hasMd && std::fabs(mt - birth) < 60 && (_model.now - birth) > 30 * 86400.0;
      [kids addObject:[self itemForFile:full
                                   size:(uint64_t)st.st_blocks * 512
                               lastUsed:std::min(lu, _model.now)
                                  never:never
                                 parent:item]];
    }
    closedir(dp);
  }
  return kids;
}

- (void)sortItems:(NSMutableArray<Item*>*)items {
  NSString* key = _sortKey;
  BOOL asc = _sortAscending;
  BOOL grouped = items.count > 0 && items[0].group >= 0;  // duplicates stay together, kept copy first
  [items sortUsingComparator:^NSComparisonResult(Item* a, Item* b) {
    NSComparisonResult r;
    if (grouped) {
      if (a.group != b.group) return a.group < b.group ? NSOrderedAscending : NSOrderedDescending;
      if (a.suggested != b.suggested) return a.suggested ? NSOrderedDescending : NSOrderedAscending;
    }
    if ([key isEqual:@"name"]) r = [a.name localizedStandardCompare:b.name];
    else if ([key isEqual:@"lastUsed"]) r = a.lastUsed < b.lastUsed ? NSOrderedAscending : a.lastUsed > b.lastUsed ? NSOrderedDescending : NSOrderedSame;
    else r = a.size < b.size ? NSOrderedAscending : a.size > b.size ? NSOrderedDescending : NSOrderedSame;
    if (r == NSOrderedSame) r = [a.name localizedStandardCompare:b.name];
    return asc ? r : (NSComparisonResult)(-r);
  }];
}

- (void)resortLoaded:(Item*)item {
  if (!item.children) return;
  [self sortItems:item.children];
  for (Item* c in item.children) [self resortLoaded:c];
}

- (NSArray<Item*>*)topItems {
  if (_mode == Mode::Browse) {
    if (!_root) return @[];
    [self loadChildren:_root];
    return _root.children;
  }
  return _flat ?: @[];
}

// ───── modes ─────

- (void)showEmpty:(NSString*)title hint:(NSString*)hint symbol:(NSString*)sym {
  _overviewScroll.hidden = YES;
  _firstRun.hidden = YES;
  _listBox.hidden = NO;
  _scroll.hidden = YES;
  _bottom.hidden = YES;
  _empty.hidden = NO;
  _emptyIcon.image = symbol(sym, 40, NSFontWeightLight);
  _emptyTitle.stringValue = title;
  _emptyHint.stringValue = hint;
}

- (void)showMode:(Mode)m {
  // Coming back to a page whose folder was protected: access may have been granted since, look again.
  if (_mode != m && isFinderMode(m) && _finderUnreadable[(int)m]) _finderItems[(int)m] = nil;
  _mode = m;
  [self syncSidebar];
  const ModeInfo& mi = kModes[(int)m];
  const ScanResult* r = _model.result.get();
  BOOL haveScan = r && !r->dirs.empty();

  _pageTitle.stringValue = m == Mode::Overview ? (haveScan ? [self scanTitle] : [self titleForRoot:_scanPath]) : mi.title;
  _pageHint.stringValue = m == Mode::Overview ? @"" : mi.hint;
  _pageHint.hidden = m == Mode::Overview;

  if (!haveScan) {
    if (_scanning) {
      _overviewScroll.hidden = YES;
      _listBox.hidden = YES;
      _bottom.hidden = YES;
      _firstRun.hidden = NO;
    } else if (_loading) {
      _overviewScroll.hidden = YES;
      _listBox.hidden = YES;
      _bottom.hidden = YES;
      _firstRun.hidden = YES;
    } else {
      [self showEmpty:@"Nothing indexed yet" hint:@"Press Rescan to index this folder." symbol:@"internaldrive"];
    }
    return;
  }
  _firstRun.hidden = YES;
  if (m == Mode::Overview) {
    _overviewScroll.hidden = NO;
    _listBox.hidden = YES;
    _bottom.hidden = YES;
    return;
  }

  _overviewScroll.hidden = YES;
  _listBox.hidden = NO;
  _emptyTrashButton.hidden = m != Mode::Trash;
  _trashButton.hidden = m == Mode::Trash;
  if (isFinderMode(m) && !_finderItems[(int)m]) {
    _flat = @[];
    [_outline reloadData];
    [self selectionChanged];
    [self showFinderProgress];
    [self runFinder:m];
    return;
  }
  _emptySpinner.hidden = YES;
  [_finderTimer invalidate];
  _finderTimer = nil;

  _flat = [self flatItemsForMode:m];
  [_outline reloadData];
  [_outline deselectAll:nil];
  if (isFinderMode(m)) [self selectSuggested];
  [self selectionChanged];

  BOOL empty = [self topItems].count == 0;
  _scroll.hidden = empty;
  [_outline sizeLastColumnToFit];
  if (!empty) [_window makeFirstResponder:_outline];
  _bottom.hidden = empty;
  _empty.hidden = !empty;
  if (empty && isFinderMode(m) && _finderUnreadable[(int)m]) {
    _emptyIcon.image = symbol(@"lock.shield", 40, NSFontWeightLight);
    _emptyTitle.stringValue = [NSString stringWithFormat:@"Stale isn't allowed to see %@",
                                                         m == Mode::Trash ? @"the Trash" : @"your Downloads"];
    _emptyHint.stringValue = @"Give Stale Full Disk Access in System Settings › Privacy & Security, then open this page again.";
  } else if (empty) {
    _emptyIcon.image = symbol(m == Mode::Browse ? @"folder" : @"checkmark.circle", 40, NSFontWeightLight);
    _emptyTitle.stringValue = mi.emptyTitle;
    _emptyHint.stringValue = mi.emptyHint;
  }
}

// ───── finder pages ─────

- (void)showFinderProgress {
  const ModeInfo& mi = kModes[(int)_mode];
  _scroll.hidden = YES;
  _bottom.hidden = YES;
  _empty.hidden = NO;
  _emptyIcon.image = symbol(mi.symbol, 40, NSFontWeightLight);
  _emptyTitle.stringValue = [NSString stringWithFormat:@"Looking for %@…", mi.title.lowercaseString];
  _emptyHint.stringValue = _mode == Mode::Duplicates ? @"Comparing files with the same size byte for byte. Large libraries take a moment."
                                                     : @"This only takes a second.";
  _emptySpinner.hidden = NO;
  _emptySpinner.indeterminate = YES;
  [_emptySpinner startAnimation:nil];
}

- (void)runFinder:(Mode)m {
  if (_finderRunning[(int)m] || !_model.result || _model.result->dirs.empty()) return;
  _finderRunning[(int)m] = YES;
  int gen = _finderGeneration;
  if (!_finderCancel) _finderCancel = std::make_shared<std::atomic<bool>>(false);
  auto cancel = _finderCancel;
  auto progress = std::make_shared<std::atomic<uint64_t>>(0);
  auto progressTotal = std::make_shared<std::atomic<uint64_t>>(0);
  _finderProgress = progress;
  _finderProgressTotal = progressTotal;
  auto res = _model.result;
  std::string home = std_str(NSHomeDirectory());
  double now = _model.now;
  if (m == Mode::Duplicates) {
    [_finderTimer invalidate];
    __weak StaleController* weakSelf = self;
    _finderTimer = [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer*) {
      StaleController* s = weakSelf;
      if (!s) return;
      uint64_t total = progressTotal->load(), done = progress->load();
      if (total == 0) return;
      s->_emptySpinner.indeterminate = NO;
      s->_emptySpinner.doubleValue = std::min(1.0, (double)done / (double)total);
      s->_emptyHint.stringValue = [NSString stringWithFormat:@"Comparing %@ of %@ byte for byte.", fmtBytes(done), fmtBytes(total)];
    }];
  }
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    FinderOptions o;
    o.index = res.get();
    o.home = home;
    o.now = now;
    o.cancel = cancel.get();
    o.progress = progress.get();
    o.progressTotal = progressTotal.get();
    FinderResult fr;
    switch (m) {
      case Mode::Duplicates: fr = findDuplicates(o); break;
      case Mode::Leftovers: fr = findLeftovers(o); break;
      case Mode::Downloads: fr = findOldDownloads(o); break;
      case Mode::Trash: fr = findTrash(o); break;
      default: break;
    }
    auto out = std::make_shared<FinderResult>(std::move(fr));
    dispatch_async(dispatch_get_main_queue(), ^{
      if (gen != self->_finderGeneration || cancel->load() || self->_model.result != res) return;
      self->_finderRunning[(int)m] = NO;
      NSMutableArray<Item*>* items = [NSMutableArray new];
      for (const Found& f : out->items) {
        Item* it = [Item new];
        it.path = ns_str(f.path);
        it.name = it.path.lastPathComponent;
        it.size = f.size;
        it.lastUsed = f.lastUsed;
        it.isDir = f.isDir;
        it.dirId = f.isDir && m != Mode::Trash ? findDir(*res, f.path) : -1;
        it.files = it.dirId >= 0 ? res->dirs[(size_t)it.dirId].files : (f.isDir && m != Mode::Trash ? 1 : 0);
        it.category = it.dirId >= 0 ? res->dirs[(size_t)it.dirId].category : CAT_NONE;
        it.note = ns_str(f.note);
        it.group = f.group;
        it.suggested = f.preselect;
        [items addObject:it];
      }
      self->_finderItems[(int)m] = items;
      self->_finderUnreadable[(int)m] = out->unreadable;
      [self refreshFinderBadge:m];
      if (self->_mode == m) [self showMode:m];
    });
  });
}

- (void)refreshFinderBadge:(Mode)m {
  uint64_t bytes = 0;
  for (Item* it in _finderItems[(int)m]) bytes += m == Mode::Trash || it.suggested ? it.size : 0;
  for (SidebarEntry* e in _entries)
    if (!e.isGroup && e.mode == m)
      e.badge = _finderItems[(int)m] && !_finderUnreadable[(int)m] && (bytes || _finderItems[(int)m].count == 0) ? fmtBytes(bytes) : nil;
  [self reloadSidebarBadges];
}

- (void)selectSuggested {
  NSMutableIndexSet* rows = [NSMutableIndexSet new];
  for (NSInteger i = 0; i < _outline.numberOfRows; ++i)
    if (((Item*)[_outline itemAtRow:i]).suggested) [rows addIndex:(NSUInteger)i];
  [_outline selectRowIndexes:rows byExtendingSelection:NO];
  if (rows.count) [_outline scrollRowToVisible:(NSInteger)rows.firstIndex];
}

// Rows of a list page, sorted the way the table currently is.
- (NSMutableArray<Item*>*)flatItemsForMode:(Mode)m {
  const ScanResult* r = _model.result.get();
  NSMutableArray<Item*>* flat = [NSMutableArray new];
  if (!r || r->dirs.empty()) return flat;
  auto stillThere = [](const std::string& p) { return !p.empty() && access(p.c_str(), F_OK) == 0; };
  switch (m) {
    case Mode::Reclaim: {
      std::vector<int32_t> ids;
      collectUnits(*r, 0, ids, [](const DirNode& d) { return categoryReclaimable(d.category); });
      for (int32_t i : ids) if (stillThere(r->dirs[i].path)) [flat addObject:[self itemForDir:i parent:nil]];
      break;
    }
    case Mode::Forgotten: {
      std::vector<int32_t> ids;
      collectForgotten(*r, 0, ids, 50ull << 20);
      for (int32_t i : ids) if (stillThere(r->dirs[i].path)) [flat addObject:[self itemForDir:i parent:nil]];
      break;
    }
    case Mode::BigFiles:
      for (const FileRec& f : r->bigFiles)
        if (f.size >= kBigFileReport && bucketFor(f.lastUsed, _model.now) >= STALE && stillThere(f.path))
          [flat addObject:[self itemForFile:f.path size:f.size lastUsed:f.lastUsed never:f.neverOpened parent:nil]];
      break;
    case Mode::Apps:
      if (!_appItems) [self buildAppItems];
      [flat addObjectsFromArray:_appItems ?: @[]];
      break;
    case Mode::Duplicates:
    case Mode::Leftovers:
    case Mode::Downloads:
    case Mode::Trash:
      for (Item* it in _finderItems[(int)m]) if (stillThere(std_str(it.path))) [flat addObject:it];
      break;
    default: break;
  }
  [self sortItems:flat];
  return flat;
}

- (void)syncSidebar {
  _syncingSidebar = YES;
  for (NSUInteger i = 0; i < _entries.count; ++i) {
    SidebarEntry* e = _entries[i];
    if (!e.isGroup && e.mode == _mode) {
      NSInteger row = [_sidebar rowForItem:e];
      if (row >= 0) [_sidebar selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    }
  }
  _syncingSidebar = NO;
}

- (void)modeFromMenu:(NSMenuItem*)mi { [self showMode:(Mode)mi.tag]; }
- (void)cardClicked:(CardView*)c { [self showMode:c.mode]; }

// Clicking a ring segment opens All folders with that folder expanded and selected.
- (void)ringClicked:(RingView*)ring {
  int32_t id = ring.clickedDir;
  if (id < 0 || !_model.result) return;
  const ScanResult& r = *_model.result;
  std::vector<int32_t> chain;  // root … target
  for (int32_t d = id; d >= 0; d = r.dirs[(size_t)d].parent) chain.push_back(d);
  std::reverse(chain.begin(), chain.end());
  [self showMode:Mode::Browse];
  Item* cur = _root;
  for (size_t i = 1; i < chain.size() && cur; ++i) {
    [self loadChildren:cur];
    Item* next = nil;
    for (Item* k in cur.children) if (k.dirId == chain[i]) { next = k; break; }
    if (!next) break;
    if (i + 1 < chain.size()) [_outline expandItem:next];
    cur = next;
  }
  if (!cur || cur == _root) return;
  [_outline expandItem:cur];
  NSInteger row = [_outline rowForItem:cur];
  if (row >= 0) {
    [_outline selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    [_outline scrollRowToVisible:row];
  }
}

// ───── outline data source (sidebar + tree) ─────

- (NSInteger)outlineView:(NSOutlineView*)ov numberOfChildrenOfItem:(Item*)item {
  if (ov == _sidebar) return item ? 0 : (NSInteger)_entries.count;
  if (!item) return (NSInteger)[self topItems].count;
  [self loadChildren:item];
  return (NSInteger)item.children.count;
}
- (id)outlineView:(NSOutlineView*)ov child:(NSInteger)i ofItem:(Item*)item {
  if (ov == _sidebar) return _entries[(NSUInteger)i];
  if (!item) return [self topItems][(NSUInteger)i];
  [self loadChildren:item];
  return item.children[(NSUInteger)i];
}
- (BOOL)outlineView:(NSOutlineView*)ov isItemExpandable:(id)obj {
  if (ov == _sidebar) return NO;
  Item* item = obj;
  return item.isDir && !item.isApp && (item.files > 0 || (item.dirId >= 0 && !_model.result->dirs[item.dirId].children.empty()));
}
- (BOOL)outlineView:(NSOutlineView*)ov isGroupItem:(id)obj {
  return ov == _sidebar && ((SidebarEntry*)obj).isGroup;
}
- (BOOL)outlineView:(NSOutlineView*)ov shouldSelectItem:(id)obj {
  if (ov == _sidebar) return !((SidebarEntry*)obj).isGroup;
  return YES;
}
- (CGFloat)outlineView:(NSOutlineView*)ov heightOfRowByItem:(id)obj {
  if (ov == _sidebar) return ((SidebarEntry*)obj).isGroup ? 28 : 30;
  return ov.rowHeight;
}

- (void)outlineView:(NSOutlineView*)ov sortDescriptorsDidChange:(NSArray<NSSortDescriptor*>*)old {
  if (ov == _sidebar) return;
  NSSortDescriptor* d = ov.sortDescriptors.firstObject;
  if (!d) return;
  _sortKey = d.key;
  _sortAscending = d.ascending;
  if (_root) [self resortLoaded:_root];
  NSMutableArray* flat = [_flat mutableCopy];
  [self sortItems:flat];
  for (Item* it in flat) [self resortLoaded:it];
  _flat = flat;
  [ov reloadData];
}

// ───── outline delegate (cells) ─────

- (NSTableCellView*)cellWithId:(NSString*)id inView:(NSOutlineView*)ov image:(BOOL)image size:(BOOL)sizeCell {
  NSTableCellView* v = [ov makeViewWithIdentifier:id owner:self];
  if (v) return v;
  v = sizeCell ? [SizeCellView new] : [NSTableCellView new];
  v.identifier = id;
  NSTextField* t = [NSTextField labelWithString:@""];
  t.translatesAutoresizingMaskIntoConstraints = NO;
  t.lineBreakMode = image ? NSLineBreakByTruncatingMiddle : NSLineBreakByTruncatingTail;
  t.maximumNumberOfLines = 1;
  t.font = [NSFont systemFontOfSize:13];
  [v addSubview:t];
  v.textField = t;
  CGFloat lead = 4;
  if (image) {
    NSImageView* iv = [NSImageView new];
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    iv.imageScaling = NSImageScaleProportionallyDown;
    [v addSubview:iv];
    v.imageView = iv;
    [NSLayoutConstraint activateConstraints:@[
      [iv.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:2],
      [iv.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
      [iv.widthAnchor constraintEqualToConstant:17],
      [iv.heightAnchor constraintEqualToConstant:17],
    ]];
    lead = 25;
  }
  [NSLayoutConstraint activateConstraints:@[
    [t.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:lead],
    [t.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-4],
    [t.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
  ]];
  return v;
}

- (NSView*)sidebarCellFor:(SidebarEntry*)e {
  if (e.isGroup) {
    NSTableCellView* v = [_sidebar makeViewWithIdentifier:@"group" owner:self];
    if (!v) {
      v = [NSTableCellView new];
      v.identifier = @"group";
      NSTextField* t = label(@"", 11, NSFontWeightSemibold, NSColor.secondaryLabelColor);
      t.translatesAutoresizingMaskIntoConstraints = NO;
      [v addSubview:t];
      v.textField = t;
      [NSLayoutConstraint activateConstraints:@[
        [t.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:2],
        [t.bottomAnchor constraintEqualToAnchor:v.bottomAnchor constant:-4],
      ]];
    }
    v.textField.stringValue = e.title.uppercaseString;
    return v;
  }
  NSTableCellView* v = [_sidebar makeViewWithIdentifier:@"side" owner:self];
  NSTextField* badge;
  if (!v) {
    v = [NSTableCellView new];
    v.identifier = @"side";
    NSImageView* iv = [NSImageView new];
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    iv.imageScaling = NSImageScaleProportionallyDown;
    NSTextField* t = label(@"", 13, NSFontWeightRegular, NSColor.labelColor);
    t.translatesAutoresizingMaskIntoConstraints = NO;
    badge = label(@"", 11, NSFontWeightMedium, NSColor.tertiaryLabelColor);
    badge.font = monoDigits(11, NSFontWeightMedium);
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    badge.identifier = @"badge";
    [v addSubview:iv];
    [v addSubview:t];
    [v addSubview:badge];
    v.imageView = iv;
    v.textField = t;
    [NSLayoutConstraint activateConstraints:@[
      [iv.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:2],
      [iv.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
      [iv.widthAnchor constraintEqualToConstant:20],
      [iv.heightAnchor constraintEqualToConstant:20],
      [t.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:6],
      [t.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
      [badge.leadingAnchor constraintGreaterThanOrEqualToAnchor:t.trailingAnchor constant:6],
      [badge.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-4],
      [badge.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
    ]];
    [badge setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
  } else {
    for (NSView* s in v.subviews)
      if ([s.identifier isEqual:@"badge"]) badge = (NSTextField*)s;
  }
  const ModeInfo& mi = kModes[(int)e.mode];
  v.imageView.image = symbol(mi.symbol, 14, NSFontWeightMedium);
  v.imageView.contentTintColor = NSColor.controlAccentColor;
  v.textField.stringValue = e.title;
  badge.stringValue = e.badge ?: @"";
  return v;
}

- (NSView*)outlineView:(NSOutlineView*)ov viewForTableColumn:(NSTableColumn*)col item:(id)obj {
  if (ov == _sidebar) return [self sidebarCellFor:obj];
  Item* item = obj;
  NSString* id = col.identifier;
  double now = _model.now;
  if ([id isEqual:@"name"]) {
    NSTableCellView* v = [self cellWithId:@"nameCell" inView:ov image:YES size:NO];
    if (!item.icon) item.icon = [[NSWorkspace sharedWorkspace] iconForFile:item.path];
    v.imageView.image = item.icon;
    NSString* name = _mode == Mode::Browse || item.parent || item.isApp ? item.name : [item.path stringByAbbreviatingWithTildeInPath];
    if (_mode == Mode::Browse && !item.parent) name = displayName(item.path);
    if (_mode == Mode::Trash && !item.parent) name = item.name;
    v.textField.stringValue = name;
    v.textField.textColor = NSColor.labelColor;
    v.toolTip = item.path;
    return v;
  }
  if ([id isEqual:@"size"]) {
    SizeCellView* v = (SizeCellView*)[self cellWithId:@"sizeCell" inView:ov image:NO size:YES];
    v.textField.alignment = NSTextAlignmentRight;
    v.textField.stringValue = fmtBytes(item.size);
    v.textField.font = monoDigits(13, NSFontWeightRegular);
    uint64_t base = item.parent ? item.parent.size : (_root ? _root.size : 0);
    if (!item.parent && _mode != Mode::Browse) {
      base = 0;
      for (Item* t in _flat) base = std::max(base, t.size);
    }
    v.fraction = base ? (double)item.size / base : 0;
    return v;
  }
  if ([id isEqual:@"used"]) {
    NSTableCellView* v = [self cellWithId:@"usedCell" inView:ov image:NO size:NO];
    NSString* text;
    NSColor* color = bucketColor(item.lastUsed, now);
    if (item.isApp) text = item.lastUsed <= 0 ? @"Never launched" : fmtAgo(item.lastUsed, now);
    else if (item.never && !item.isDir) text = [NSString stringWithFormat:@"Never opened · %@", [fmtAgo(item.lastUsed, now) lowercaseString]];
    else text = fmtAgo(item.lastUsed, now);
    NSMutableAttributedString* s = [[NSMutableAttributedString alloc]
        initWithString:@"● "
            attributes:@{NSForegroundColorAttributeName : color, NSFontAttributeName : [NSFont systemFontOfSize:10]}];
    [s appendAttributedString:[[NSAttributedString alloc]
                                  initWithString:text
                                      attributes:@{
                                        NSForegroundColorAttributeName : NSColor.labelColor,
                                        NSFontAttributeName : [NSFont systemFontOfSize:13]
                                      }]];
    v.textField.attributedStringValue = s;
    v.toolTip = item.lastUsed > 0 ? fmtDateTime(item.lastUsed) : @"";
    return v;
  }
  // note
  NSTableCellView* v = [self cellWithId:@"noteCell" inView:ov image:NO size:NO];
  NSMutableArray<NSString*>* parts = [NSMutableArray new];
  if (item.note.length && !item.parent) {
    v.textField.stringValue = item.note;
    v.textField.textColor = item.suggested ? NSColor.secondaryLabelColor : NSColor.systemGreenColor;
    if (_mode != Mode::Duplicates) v.textField.textColor = NSColor.secondaryLabelColor;
    return v;
  }
  if (item.isApp) {
    [parts addObject:[NSString stringWithFormat:@"Installed or updated %@", [fmtAgo(item.installed, now) lowercaseString]]];
  } else if (item.isDir) {
    NSString* hint = categoryHint(item.category);
    if (hint.length) [parts addObject:[NSString stringWithFormat:@"%@ · %@", categoryTitle(item.category), hint]];
    else [parts addObject:fmtCount(item.files, @"file")];
    if (item.never && !hint.length) [parts addObject:@"mostly never opened"];
  } else {
    NSString* ext = item.path.pathExtension;
    if (ext.length) [parts addObject:[NSString stringWithFormat:@"%@ file", ext.uppercaseString]];
  }
  v.textField.stringValue = [parts componentsJoinedByString:@"  ·  "];
  v.textField.textColor = NSColor.secondaryLabelColor;
  return v;
}

- (void)outlineViewSelectionDidChange:(NSNotification*)n {
  if (n.object == _sidebar) {
    if (_syncingSidebar) return;
    NSInteger row = _sidebar.selectedRow;
    if (row < 0) return;
    SidebarEntry* e = [_sidebar itemAtRow:row];
    if (!e.isGroup && e.mode != _mode) [self showMode:e.mode];
    return;
  }
  [self selectionChanged];
}

- (NSArray<Item*>*)selectedItems {
  NSMutableArray<Item*>* out = [NSMutableArray new];
  NSIndexSet* sel = _outline.selectedRowIndexes;
  [sel enumerateIndexesUsingBlock:^(NSUInteger row, BOOL*) {
    Item* it = [self->_outline itemAtRow:(NSInteger)row];
    if (it) [out addObject:it];
  }];
  // Drop items whose ancestor is also selected.
  NSMutableArray<Item*>* pruned = [NSMutableArray new];
  for (Item* it in out) {
    BOOL covered = NO;
    for (Item* p = it.parent; p; p = p.parent)
      if ([out containsObject:p]) { covered = YES; break; }
    if (!covered) [pruned addObject:it];
  }
  return pruned;
}

- (void)selectionChanged {
  NSArray<Item*>* sel = [self selectedItems];
  uint64_t total = 0;
  for (Item* it in sel) total += it.size;
  BOOL any = sel.count > 0;
  _trashButton.enabled = _revealButton.enabled = any;
  if (_mode == Mode::Trash) {
    uint64_t all = 0;
    for (Item* it in _flat) all += it.size;
    _emptyTrashButton.enabled = _flat.count > 0 && !_finderUnreadable[(int)Mode::Trash];
    _status.stringValue = any ? [NSString stringWithFormat:@"%@ selected  ·  %@  ·  %@ in the Trash altogether", fmtCount(sel.count, @"item"), fmtBytes(total), fmtBytes(all)]
                              : [NSString stringWithFormat:@"%@ in %@. Emptying deletes them for good.", fmtBytes(all), fmtCount(_flat.count, @"item")];
  } else if (!any) {
    _status.stringValue = @"Select folders or files to move them to the Trash.";
  } else if (isFinderMode(_mode) && sel.count > 1) {
    NSUInteger suggested = 0;
    for (Item* it in sel) suggested += it.suggested;
    _status.stringValue = suggested == sel.count
        ? [NSString stringWithFormat:@"%@ suggested  ·  %@  ·  review, then Move to Trash", fmtCount(sel.count, @"item"), fmtBytes(total)]
        : [NSString stringWithFormat:@"%@ selected  ·  %@", fmtCount(sel.count, @"item"), fmtBytes(total)];
  } else if (sel.count == 1) {
    Item* it = sel[0];
    _status.stringValue = [NSString stringWithFormat:@"%@  ·  %@  ·  last used %@", it.path.stringByAbbreviatingWithTildeInPath,
                                                     fmtBytes(it.size), [fmtAgo(it.lastUsed, _model.now) lowercaseString]];
  } else {
    _status.stringValue = [NSString stringWithFormat:@"%@ selected  ·  %@", fmtCount(sel.count, @"item"), fmtBytes(total)];
  }
  [_window.toolbar validateVisibleItems];
  QLPreviewPanel* ql = QLPreviewPanel.sharedPreviewPanelExists ? QLPreviewPanel.sharedPreviewPanel : nil;
  if (ql.visible && ql.dataSource == self) [ql reloadData];
}

// Folders expand, files open in their app, apps are shown in the Finder (launching them would
// change the very "last used" date this list is about).
- (void)doubleClicked:(id)sender {
  NSInteger row = _outline.clickedRow;
  if (row < 0) return;
  Item* it = [_outline itemAtRow:row];
  if ([self outlineView:_outline isItemExpandable:it]) {
    if ([_outline isItemExpanded:it]) [_outline collapseItem:it];
    else [_outline expandItem:it];
  } else if (it.isApp || it.isDir) {
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[ [NSURL fileURLWithPath:it.path] ]];
  } else {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:it.path]];
  }
}

- (void)openSelected:(id)sender {
  for (Item* it in [self selectedItems]) {
    NSURL* u = [NSURL fileURLWithPath:it.path];
    if (it.isApp) [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[ u ]];
    else [[NSWorkspace sharedWorkspace] openURL:u];
  }
}

// ───── Quick Look ─────

- (void)togglePreview:(id)sender {
  QLPreviewPanel* ql = QLPreviewPanel.sharedPreviewPanel;
  if (ql.visible) [ql orderOut:nil];
  else if ([self selectedItems].count) {
    [_window makeFirstResponder:_outline];
    [ql makeKeyAndOrderFront:nil];
  }
}

- (NSInteger)numberOfPreviewItemsInPreviewPanel:(QLPreviewPanel*)panel { return (NSInteger)[self selectedItems].count; }
- (id<QLPreviewItem>)previewPanel:(QLPreviewPanel*)panel previewItemAtIndex:(NSInteger)i {
  NSArray<Item*>* sel = [self selectedItems];
  return i >= 0 && (NSUInteger)i < sel.count ? sel[(NSUInteger)i] : nil;
}
- (BOOL)previewPanel:(QLPreviewPanel*)panel handleEvent:(NSEvent*)e {
  // Arrow keys move the selection in the list while the panel is up, like the Finder.
  if (e.type == NSEventTypeKeyDown && e.charactersIgnoringModifiers.length == 1) {
    unichar c = [e.charactersIgnoringModifiers characterAtIndex:0];
    if (c == NSUpArrowFunctionKey || c == NSDownArrowFunctionKey) {
      [_outline keyDown:e];
      return YES;
    }
  }
  return NO;
}
- (NSRect)previewPanel:(QLPreviewPanel*)panel sourceFrameOnScreenForPreviewItem:(id<QLPreviewItem>)item {
  NSInteger row = [_outline rowForItem:item];
  if (row < 0) return NSZeroRect;
  NSRect r = [_outline frameOfCellAtColumn:0 row:row];
  r = [_outline convertRect:r toView:nil];
  return [_window convertRectToScreen:r];
}

// ───── emptying the Trash ─────

- (void)emptyTrash:(id)sender {
  NSArray<Item*>* items = _mode == Mode::Trash && _finderItems[(int)Mode::Trash] ? _flat : nil;
  NSString* trashDir = [NSHomeDirectory() stringByAppendingPathComponent:@".Trash"];
  if (!items) {
    NSMutableArray<Item*>* found = [NSMutableArray new];
    NSError* listErr = nil;
    NSArray<NSString*>* names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:trashDir error:&listErr];
    if (!names && listErr) {
      NSAlert* a = [NSAlert new];
      a.messageText = @"Stale isn't allowed to see the Trash";
      a.informativeText = @"Give Stale Full Disk Access in System Settings › Privacy & Security, then try again.";
      [a addButtonWithTitle:@"OK"];
      [a beginSheetModalForWindow:_window completionHandler:nil];
      return;
    }
    for (NSString* n in names) {
      if ([n isEqual:@".DS_Store"]) continue;
      Item* it = [Item new];
      it.path = [trashDir stringByAppendingPathComponent:n];
      it.name = n;
      [found addObject:it];
    }
    items = found;
  }
  uint64_t total = 0;
  for (Item* it in items) total += it.size;
  NSAlert* a = [NSAlert new];
  a.alertStyle = NSAlertStyleCritical;
  a.messageText = items.count ? @"Empty the Trash?" : @"The Trash is already empty";
  a.informativeText = items.count
      ? [NSString stringWithFormat:@"%@ in %@ will be deleted permanently. This can't be undone.", total ? fmtBytes(total) : @"Everything", fmtCount(items.count, @"item")]
      : @"";
  if (items.count) [a addButtonWithTitle:@"Empty Trash"];
  [a addButtonWithTitle:items.count ? @"Cancel" : @"OK"];
  [a beginSheetModalForWindow:_window completionHandler:^(NSModalResponse r) {
    if (!items.count || r != NSAlertFirstButtonReturn) return;
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* prefix = [trashDir stringByAppendingString:@"/"];
    NSMutableArray<NSString*>* failures = [NSMutableArray new];
    for (Item* it in items) {
      // Only ever delete directly inside ~/.Trash, whatever the list says.
      NSString* p = it.path.stringByStandardizingPath;
      if (![p hasPrefix:prefix] || [p.stringByDeletingLastPathComponent isEqual:trashDir] == NO) continue;
      NSError* err = nil;
      if (![fm removeItemAtPath:p error:&err])
        [failures addObject:[NSString stringWithFormat:@"%@: %@", it.name, err.localizedDescription ?: @"unknown error"]];
    }
    self->_finderItems[(int)Mode::Trash] = nil;
    if (self->_mode == Mode::Trash) [self showMode:Mode::Trash];
    else [self refreshFinderBadge:Mode::Trash];
    if (failures.count) {
      NSAlert* b = [NSAlert new];
      b.alertStyle = NSAlertStyleCritical;
      b.messageText = @"Some items couldn't be deleted";
      b.informativeText = [failures componentsJoinedByString:@"\n"];
      [b beginSheetModalForWindow:self->_window completionHandler:nil];
    }
  }];
}

// ───── actions ─────

- (void)revealSelected:(id)sender {
  NSMutableArray<NSURL*>* urls = [NSMutableArray new];
  for (Item* it in [self selectedItems]) [urls addObject:[NSURL fileURLWithPath:it.path]];
  if (urls.count) [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:urls];
}

- (void)copyPath:(id)sender {
  NSMutableArray<NSString*>* paths = [NSMutableArray new];
  for (Item* it in [self selectedItems]) [paths addObject:it.path];
  if (!paths.count) return;
  [NSPasteboard.generalPasteboard clearContents];
  [NSPasteboard.generalPasteboard setString:[paths componentsJoinedByString:@"\n"] forType:NSPasteboardTypeString];
}

- (void)selectAll:(id)sender { [_outline selectAll:sender]; }

- (void)trashSelected:(id)sender {
  NSArray<Item*>* sel = [self selectedItems];
  if (!sel.count) return;
  uint64_t total = 0;
  for (Item* it in sel) total += it.size;

  NSAlert* a = [NSAlert new];
  a.alertStyle = NSAlertStyleWarning;
  a.messageText = sel.count == 1
                      ? [NSString stringWithFormat:@"Move “%@” to the Trash?", sel[0].name]
                      : [NSString stringWithFormat:@"Move %@ to the Trash?", fmtCount(sel.count, @"item")];
  NSMutableString* info = [NSMutableString stringWithFormat:@"This frees %@ once you empty the Trash. Nothing is deleted "
                                                            @"permanently — you can put it back from the Trash.", fmtBytes(total)];
  BOOL anyOwn = NO, anyRecent = NO;
  for (Item* it in sel) {
    if (!(it.isDir && categoryReclaimable(it.category)) && !it.isApp) anyOwn = YES;
    if (it.lastUsed > 0 && bucketFor(it.lastUsed, _model.now) <= WARM) anyRecent = YES;
  }
  if (anyRecent) [info appendString:@"\n\n⚠︎ Something here was used in the last 30 days."];
  else if (anyOwn) [info appendString:@"\n\nThis includes your own files, not just regenerable data."];
  a.informativeText = info;
  [a addButtonWithTitle:@"Move to Trash"];
  [a addButtonWithTitle:@"Cancel"];
  [a beginSheetModalForWindow:_window completionHandler:^(NSModalResponse r) {
    if (r != NSAlertFirstButtonReturn) return;
    [self performTrash:sel];
  }];
}

- (void)performTrash:(NSArray<Item*>*)items {
  NSFileManager* fm = NSFileManager.defaultManager;
  uint64_t moved = 0;
  NSMutableArray<NSString*>* failures = [NSMutableArray new];
  for (Item* it in items) {
    NSError* err = nil;
    if ([fm trashItemAtURL:[NSURL fileURLWithPath:it.path] resultingItemURL:nil error:&err]) {
      moved += it.size;
      [self removeItem:it];
    } else {
      [failures addObject:[NSString stringWithFormat:@"%@: %@", it.name, err.localizedDescription ?: @"unknown error"]];
    }
  }
  if (_model.result && !_model.result->dirs.empty()) {
    if (moved) rollup(*_model.result);
    if (_root) [self syncItem:_root touched:{}];
  }
  [_outline reloadData];
  [self selectionChanged];
  if (_model.result && !_model.result->dirs.empty()) {
    [self refreshSummary];
    if ([self topItems].count == 0) [self showMode:_mode];  // switch to the empty state
    if (moved) [self persistIndexSoon];
  }
  _status.stringValue = [NSString stringWithFormat:@"Moved %@ to the Trash.", fmtBytes(moved)];
  if (failures.count) {
    NSAlert* a = [NSAlert new];
    a.alertStyle = NSAlertStyleCritical;
    a.messageText = @"Some items couldn't be moved to the Trash";
    a.informativeText = [failures componentsJoinedByString:@"\n"];
    [a beginSheetModalForWindow:_window completionHandler:nil];
  }
}

// Remove from the tree and flat lists and from the scan model (the caller re-rolls totals).
- (void)removeItem:(Item*)it {
  if (it.parent) [it.parent.children removeObject:it];
  else if (_root && _root.children) [_root.children removeObject:it];
  NSMutableArray* flat = [_flat mutableCopy];
  [flat removeObject:it];
  _flat = flat;
  [_appItems removeObject:it];
  for (int i = 0; i < (int)Mode::Count; ++i) [_finderItems[i] removeObject:it];
  _finderItems[(int)Mode::Trash] = nil;  // it just gained an item
  if (!_model.result) return;
  ScanResult& r = *_model.result;
  if (!it.isDir) {
    std::string p = std_str(it.path);
    r.bigFiles.erase(std::remove_if(r.bigFiles.begin(), r.bigFiles.end(),
                                    [&](const FileRec& f) { return f.path == p; }),
                     r.bigFiles.end());
  }
  // Keep the scan model consistent so the summary and other modes don't resurrect it.
  auto sub = [](uint64_t& a, uint64_t b) { a -= std::min(a, b); };
  if (it.dirId >= 0) {
    markGone(r, it.dirId);
  } else if (!it.isDir) {
    int32_t owner = findDir(r, std_str(it.path.stringByDeletingLastPathComponent));
    if (owner >= 0) {
      DirOwn& o = r.dirs[(size_t)owner].own;
      sub(o.size, it.size);
      sub(o.files, 1);
      sub(o.bucketSize[bucketFor(it.lastUsed, _model.now)], it.size);
      if (it.never) sub(o.neverOpenedSize, it.size);
    }
  }
}

@end

int main(int argc, const char* argv[]) {
  @autoreleasepool {
    NSApplication* app = NSApplication.sharedApplication;
    app.activationPolicy = NSApplicationActivationPolicyRegular;
    StaleController* c = [StaleController new];
    app.delegate = c;
    [app run];
  }
  return 0;
}
