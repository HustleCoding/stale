// Stale.app — a native window over the stale scanner.
// Sidebar of views (Overview, All folders, Safe to delete, Forgotten, Big unused files, Apps),
// a folder tree with size / last-used / what-is-it columns, and a "Move to Trash" action.
// Everything goes to the Trash, nothing is deleted outright.
#import <Cocoa/Cocoa.h>

#include <dirent.h>
#include <sys/stat.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <memory>
#include <string>
#include <vector>

#include "../src/scan.h"

using namespace stale;

// ───────────────────────────── helpers ─────────────────────────────

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

static NSColor* kBucketColors[NBUCKETS + 1];  // + never opened
static NSString* kBucketLabels[NBUCKETS + 1] = {@"This week", @"This month", @"Last 6 months", @"6–12 months",
                                                @"Over a year", @"Never opened"};

static void initColors() {
  kBucketColors[HOT] = NSColor.systemGreenColor;
  kBucketColors[WARM] = NSColor.systemTealColor;
  kBucketColors[COLD] = NSColor.systemYellowColor;
  kBucketColors[STALE] = NSColor.systemOrangeColor;
  kBucketColors[FROZEN] = NSColor.systemRedColor;
  kBucketColors[NBUCKETS] = NSColor.systemGrayColor;
}

static NSColor* bucketColor(double lastUsed, double now) {
  if (lastUsed <= 0) return kBucketColors[NBUCKETS];
  return kBucketColors[bucketFor(lastUsed, now)];
}

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

// ───────────────────────────── model ─────────────────────────────

@interface Item : NSObject
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
@property(nonatomic) int32_t dirId;     // index into ScanResult::dirs, -1 for files
@property(nonatomic, weak) Item* parent;
@property(nonatomic, strong) NSMutableArray<Item*>* children;  // nil until loaded
@property(nonatomic, strong) NSImage* icon;
@end
@implementation Item
@end

struct Model {
  std::shared_ptr<ScanResult> result;
  std::shared_ptr<ScanResult> apps[2];
  double now = 0;
};

enum class Mode { Overview = 0, Browse, Reclaim, Forgotten, BigFiles, Apps, Count };

struct ModeInfo {
  NSString* title;
  NSString* symbol;
  NSString* hint;
  NSString* emptyTitle;
  NSString* emptyHint;
};
static const ModeInfo kModes[] = {
    {@"Overview", @"chart.pie", @"", @"", @""},
    {@"All folders", @"folder",
     @"Everything in this folder, biggest first. Expand a folder to see what's inside; "
     @"the colour shows how recently something in it was used.",
     @"Empty folder", @"There's nothing in here."},
    {@"Safe to delete", @"sparkles",
     @"Data that tools generate and can regenerate: npm packages, build output, caches, Xcode and "
     @"Docker data. Deleting it frees space without losing any of your own files.",
     @"Nothing to regenerate", @"No npm packages, build output, caches or Xcode data in this folder."},
    {@"Forgotten", @"clock.arrow.circlepath",
     @"Folders of 50 MB or more where nothing has been opened or changed in over 6 months. "
     @"If you don't recognise one, you probably don't need it.",
     @"No forgotten folders", @"Every folder over 50 MB has been touched in the last 6 months."},
    {@"Big unused files", @"shippingbox",
     @"Single files of 100 MB or more untouched for over 6 months: old downloads, installers, "
     @"videos, disk images.",
     @"No big unused files", @"Nothing over 100 MB has gone untouched for 6 months."},
    {@"Apps", @"app.badge",
     @"Apps in /Applications and ~/Applications by when you last launched them (from Spotlight). "
     @"Apps you never open can be removed and reinstalled later.",
     @"No apps found", @"Nothing in /Applications or ~/Applications."},
};

// ───────────────────────────── views ─────────────────────────────

@interface UsageBarView : NSView
@property(nonatomic) std::vector<double> parts;  // NBUCKETS values
@end
@implementation UsageBarView
- (void)drawRect:(NSRect)r {
  CGFloat rad = self.bounds.size.height / 2;
  NSBezierPath* clip = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:rad yRadius:rad];
  [clip addClip];
  [NSColor.quaternaryLabelColor setFill];
  NSRectFill(self.bounds);
  double total = 0;
  for (double v : _parts) total += v;
  if (total <= 0) return;
  CGFloat x = 0;
  for (size_t i = 0; i < _parts.size() && i < NBUCKETS; ++i) {
    CGFloat w = self.bounds.size.width * _parts[i] / total;
    [kBucketColors[i] setFill];
    NSRectFill(NSMakeRect(x, 0, w, self.bounds.size.height));
    x += w;
  }
}
@end

// Scroll document view that lays out from the top like the rest of the UI.
@interface FlippedView : NSView
@end
@implementation FlippedView
- (BOOL)isFlipped { return YES; }
@end

// Size cell: text on top of a faint bar proportional to the item's share of its parent.
@interface SizeCellView : NSTableCellView
@property(nonatomic) double fraction;
@end
@implementation SizeCellView
- (void)drawRect:(NSRect)r {
  [super drawRect:r];
  if (_fraction <= 0) return;
  NSRect b = NSInsetRect(self.bounds, 4, 5);
  CGFloat w = std::max<CGFloat>(2, b.size.width * std::min(1.0, _fraction));
  NSRect bar = NSMakeRect(NSMaxX(b) - w, b.origin.y, w, b.size.height);
  [[NSColor.controlAccentColor colorWithAlphaComponent:0.18] setFill];
  [[NSBezierPath bezierPathWithRoundedRect:bar xRadius:3 yRadius:3] fill];
}
- (void)setFraction:(double)f { _fraction = f; [self setNeedsDisplay:YES]; }
@end

// Rounded, clickable card used on the Overview page.
@interface CardView : NSView
@property(nonatomic) Mode mode;
@property(nonatomic, weak) id target;
@property(nonatomic) SEL action;
@property(nonatomic, strong) NSTextField* valueLabel;
@property(nonatomic, strong) NSTextField* detailLabel;
@property(nonatomic) BOOL hover;
@end
@implementation CardView
- (instancetype)initWithMode:(Mode)m {
  if (!(self = [super initWithFrame:NSZeroRect])) return nil;
  _mode = m;
  const ModeInfo& mi = kModes[(int)m];
  NSImageView* icon = [NSImageView imageViewWithImage:symbol(mi.symbol, 15, NSFontWeightMedium)];
  icon.contentTintColor = NSColor.controlAccentColor;
  NSTextField* title = label(mi.title, 13, NSFontWeightMedium, NSColor.labelColor);
  NSStackView* top = [NSStackView stackViewWithViews:@[ icon, title ]];
  top.spacing = 6;
  _valueLabel = label(@"—", 24, NSFontWeightSemibold, NSColor.labelColor);
  _valueLabel.font = [NSFont monospacedDigitSystemFontOfSize:24 weight:NSFontWeightSemibold];
  _detailLabel = [NSTextField wrappingLabelWithString:@""];
  _detailLabel.font = [NSFont systemFontOfSize:11];
  _detailLabel.textColor = NSColor.secondaryLabelColor;
  _detailLabel.selectable = NO;
  _detailLabel.maximumNumberOfLines = 2;
  NSStackView* col = [NSStackView stackViewWithViews:@[ top, _valueLabel, _detailLabel ]];
  col.orientation = NSUserInterfaceLayoutOrientationVertical;
  col.alignment = NSLayoutAttributeLeading;
  col.spacing = 4;
  [col setCustomSpacing:10 afterView:top];
  col.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:col];
  [NSLayoutConstraint activateConstraints:@[
    [col.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
    [col.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-14],
    [col.topAnchor constraintEqualToAnchor:self.topAnchor constant:12],
    [col.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-12],
  ]];
  [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                     options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow |
                                                             NSTrackingInVisibleRect
                                                       owner:self
                                                    userInfo:nil]];
  self.toolTip = [NSString stringWithFormat:@"Show %@", mi.title.lowercaseString];
  return self;
}
- (void)drawRect:(NSRect)r {
  NSBezierPath* p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:10 yRadius:10];
  [NSColor.controlBackgroundColor setFill];
  [p fill];
  if (_hover) {
    [[NSColor.controlAccentColor colorWithAlphaComponent:0.06] setFill];
    [p fill];
  }
  [[NSColor.separatorColor colorWithAlphaComponent:_hover ? 0.9 : 0.5] setStroke];
  p.lineWidth = 1;
  [p stroke];
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
                                       NSToolbarDelegate, NSMenuDelegate>
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

  // overview page
  NSScrollView* _overviewScroll;
  NSTextField* _bigNumber;
  NSTextField* _bigSub;
  UsageBarView* _bar;
  NSStackView* _legend;
  NSMutableArray<CardView*>* _cards;
  NSStackView* _topList;
  NSTextField* _topTitle;

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

  // scanning
  NSView* _overlay;
  NSTextField* _overlayText;
  NSTextField* _overlayCount;
  NSProgressIndicator* _spinner;
  NSTimer* _progressTimer;

  Model _model;
  Item* _root;
  NSArray<Item*>* _flat;  // items shown in non-browse modes
  NSMutableArray<Item*>* _appItems;
  Mode _mode;
  std::string _scanPath;    // folder being (or last asked to be) scanned
  std::string _resultPath;  // folder the current model describes
  std::shared_ptr<std::atomic<uint64_t>> _progress;
  std::shared_ptr<std::atomic<bool>> _cancel;  // owned by the scan in flight
  int _scanGeneration;
  BOOL _scanning;
  NSString* _sortKey;
  BOOL _sortAscending;
}

// ───── app lifecycle ─────

- (void)applicationDidFinishLaunching:(NSNotification*)n {
  initColors();
  _sortKey = @"size";
  _sortAscending = NO;
  _mode = Mode::Overview;
  [self buildMenus];
  [self buildWindow];
  [NSApp activateIgnoringOtherApps:YES];
  std::string start = std_str(NSHomeDirectory());
  NSArray<NSString*>* args = NSProcessInfo.processInfo.arguments;
  if (args.count > 1 && ![args[1] hasPrefix:@"-"]) {
    BOOL isDir = NO;
    if ([NSFileManager.defaultManager fileExistsAtPath:args[1] isDirectory:&isDir] && isDir)
      start = std_str(args[1].stringByStandardizingPath);
  }
  [self scanPath:start];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)a { return YES; }

- (BOOL)application:(NSApplication*)app openFile:(NSString*)path {
  BOOL isDir = NO;
  if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir] || !isDir) return NO;
  [self scanPath:std_str(path.stringByStandardizingPath)];
  return YES;
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
  [file addItemWithTitle:@"Scan Folder…" action:@selector(chooseFolder:) keyEquivalent:@"o"];
  [file addItemWithTitle:@"Scan Home Folder" action:@selector(scanHome:) keyEquivalent:@"H"];
  [file addItemWithTitle:@"Rescan" action:@selector(rescan:) keyEquivalent:@"r"];
  [file addItemWithTitle:@"Stop Scan" action:@selector(cancelScan:) keyEquivalent:@"."];
  [file addItem:NSMenuItem.separatorItem];
  [file addItemWithTitle:@"Reveal in Finder" action:@selector(revealSelected:) keyEquivalent:@"R"];
  NSMenuItem* trash = [file addItemWithTitle:@"Move to Trash" action:@selector(trashSelected:) keyEquivalent:@"\b"];
  trash.keyEquivalentModifierMask = NSEventModifierFlagCommand;
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
                              keyEquivalent:[NSString stringWithFormat:@"%d", i + 1]];
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
  helpItem.submenu = help;
  NSApp.helpMenu = help;

  NSApp.mainMenu = menubar;
}

- (void)buildWindow {
  _window = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(0, 0, 1140, 760)
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                          NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView
                  backing:NSBackingStoreBuffered
                    defer:NO];
  _window.title = @"Stale";
  _window.minSize = NSMakeSize(820, 520);
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
  main.minimumThickness = 600;
  [_split addSplitViewItem:main];

  _window.contentViewController = _split;
  [_window setContentSize:NSMakeSize(1140, 760)];
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
  add(Mode::Forgotten, NO, nil);
  add(Mode::BigFiles, NO, nil);
  add(Mode::Apps, NO, nil);
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
  sc.translatesAutoresizingMaskIntoConstraints = NO;
  [v addSubview:sc];
  [NSLayoutConstraint activateConstraints:@[
    [sc.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
    [sc.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
    [sc.topAnchor constraintEqualToAnchor:v.topAnchor],
    [sc.bottomAnchor constraintEqualToAnchor:v.bottomAnchor],
  ]];
  return v;
}

- (NSView*)buildContent {
  _content = [NSView new];

  _fdaBanner = [self makeBanner];
  _fdaBanner.hidden = YES;

  _pageTitle = label(@"Overview", 22, NSFontWeightBold, NSColor.labelColor);
  _pageHint = [NSTextField wrappingLabelWithString:@""];
  _pageHint.font = [NSFont systemFontOfSize:12];
  _pageHint.textColor = NSColor.secondaryLabelColor;
  _pageHint.selectable = NO;

  [self buildOverview];
  [self buildList];

  NSStackView* page = [NSStackView stackViewWithViews:@[ _fdaBanner, _pageTitle, _pageHint, _overviewScroll, _listBox, _bottom ]];
  page.orientation = NSUserInterfaceLayoutOrientationVertical;
  page.alignment = NSLayoutAttributeLeading;
  page.spacing = 6;
  [page setCustomSpacing:14 afterView:_fdaBanner];
  [page setCustomSpacing:14 afterView:_pageHint];
  [page setCustomSpacing:10 afterView:_listBox];
  page.translatesAutoresizingMaskIntoConstraints = NO;
  [_content addSubview:page];
  [NSLayoutConstraint activateConstraints:@[
    [page.leadingAnchor constraintEqualToAnchor:_content.leadingAnchor constant:24],
    [page.trailingAnchor constraintEqualToAnchor:_content.trailingAnchor constant:-24],
    [page.topAnchor constraintEqualToAnchor:_content.safeAreaLayoutGuide.topAnchor constant:18],
    [page.bottomAnchor constraintEqualToAnchor:_content.bottomAnchor constant:-14],
    [_fdaBanner.widthAnchor constraintEqualToAnchor:page.widthAnchor],
    [_pageHint.widthAnchor constraintEqualToAnchor:page.widthAnchor],
    [_overviewScroll.widthAnchor constraintEqualToAnchor:page.widthAnchor],
    [_listBox.widthAnchor constraintEqualToAnchor:page.widthAnchor],
    [_bottom.widthAnchor constraintEqualToAnchor:page.widthAnchor],
  ]];
  [_listBox setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];
  [_overviewScroll setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];

  // ── scanning overlay
  _overlay = [NSVisualEffectView new];
  ((NSVisualEffectView*)_overlay).material = NSVisualEffectMaterialWindowBackground;
  ((NSVisualEffectView*)_overlay).blendingMode = NSVisualEffectBlendingModeWithinWindow;
  _spinner = [NSProgressIndicator new];
  _spinner.style = NSProgressIndicatorStyleSpinning;
  _spinner.controlSize = NSControlSizeRegular;
  _overlayText = label(@"Scanning…", 15, NSFontWeightSemibold, NSColor.labelColor);
  _overlayText.alignment = NSTextAlignmentCenter;
  _overlayText.lineBreakMode = NSLineBreakByTruncatingMiddle;
  _overlayCount = label(@"", 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
  _overlayCount.alignment = NSTextAlignmentCenter;
  _overlayCount.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
  NSButton* stop = [NSButton buttonWithTitle:@"Stop" target:self action:@selector(cancelScan:)];
  stop.controlSize = NSControlSizeSmall;
  stop.font = [NSFont systemFontOfSize:11];
  NSStackView* ov = [NSStackView stackViewWithViews:@[ _spinner, _overlayText, _overlayCount, stop ]];
  ov.orientation = NSUserInterfaceLayoutOrientationVertical;
  ov.spacing = 8;
  [ov setCustomSpacing:14 afterView:_spinner];
  [ov setCustomSpacing:16 afterView:_overlayCount];
  ov.translatesAutoresizingMaskIntoConstraints = NO;
  [_overlay addSubview:ov];
  _overlay.translatesAutoresizingMaskIntoConstraints = NO;
  [_content addSubview:_overlay];
  [NSLayoutConstraint activateConstraints:@[
    [_overlay.leadingAnchor constraintEqualToAnchor:_content.leadingAnchor],
    [_overlay.trailingAnchor constraintEqualToAnchor:_content.trailingAnchor],
    [_overlay.topAnchor constraintEqualToAnchor:_content.topAnchor],
    [_overlay.bottomAnchor constraintEqualToAnchor:_content.bottomAnchor],
    [ov.centerXAnchor constraintEqualToAnchor:_overlay.centerXAnchor],
    [ov.centerYAnchor constraintEqualToAnchor:_overlay.centerYAnchor constant:-20],
    [_overlayText.widthAnchor constraintLessThanOrEqualToConstant:520],
  ]];
  _overlay.hidden = YES;
  return _content;
}

- (void)buildOverview {
  _bigNumber = label(@"—", 40, NSFontWeightBold, NSColor.labelColor);
  _bigNumber.font = [NSFont monospacedDigitSystemFontOfSize:40 weight:NSFontWeightBold];
  _bigSub = label(@"", 13, NSFontWeightRegular, NSColor.secondaryLabelColor);
  _bigSub.lineBreakMode = NSLineBreakByTruncatingMiddle;

  _bar = [UsageBarView new];
  [_bar.heightAnchor constraintEqualToConstant:18].active = YES;

  _legend = [NSStackView new];
  _legend.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  _legend.distribution = NSStackViewDistributionFillEqually;
  _legend.alignment = NSLayoutAttributeTop;
  _legend.spacing = 12;

  NSTextField* cardsTitle = label(@"Where to look", 13, NSFontWeightSemibold, NSColor.secondaryLabelColor);
  _cards = [NSMutableArray new];
  NSStackView* cardRow = [NSStackView new];
  cardRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  cardRow.distribution = NSStackViewDistributionFillEqually;
  cardRow.alignment = NSLayoutAttributeHeight;
  cardRow.spacing = 12;
  for (Mode m : {Mode::Reclaim, Mode::Forgotten, Mode::BigFiles, Mode::Apps}) {
    CardView* c = [[CardView alloc] initWithMode:m];
    c.target = self;
    c.action = @selector(cardClicked:);
    [_cards addObject:c];
    [cardRow addView:c inGravity:NSStackViewGravityLeading];
  }

  _topTitle = label(@"Biggest folders", 13, NSFontWeightSemibold, NSColor.secondaryLabelColor);
  _topList = [NSStackView new];
  _topList.orientation = NSUserInterfaceLayoutOrientationVertical;
  _topList.alignment = NSLayoutAttributeLeading;
  _topList.spacing = 0;

  NSStackView* stack = [NSStackView
      stackViewWithViews:@[ _bigNumber, _bigSub, _bar, _legend, cardsTitle, cardRow, _topTitle, _topList ]];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = 8;
  [stack setCustomSpacing:2 afterView:_bigNumber];
  [stack setCustomSpacing:18 afterView:_bigSub];
  [stack setCustomSpacing:10 afterView:_bar];
  [stack setCustomSpacing:28 afterView:_legend];
  [stack setCustomSpacing:28 afterView:cardRow];
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
    [_bar.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
    [_legend.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
    [cardRow.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
    [_topList.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
    [_bigSub.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
  ]];
}

- (void)buildList {
  _outline = [NSOutlineView new];
  _outline.dataSource = self;
  _outline.delegate = self;
  _outline.allowsMultipleSelection = YES;
  _outline.usesAlternatingRowBackgroundColors = YES;
  _outline.rowHeight = 24;
  _outline.style = NSTableViewStyleFullWidth;
  _outline.autoresizesOutlineColumn = YES;
  _outline.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
  _outline.doubleAction = @selector(doubleClicked:);
  _outline.target = self;
  _outline.autosaveTableColumns = YES;
  _outline.autosaveName = @"StaleColumns";
  _outline.menu = [self makeContextMenu];

  struct Col { NSString* id; NSString* title; CGFloat w; CGFloat minW; NSString* sortKey; };
  Col cols[] = {{@"name", @"Name", 320, 180, @"name"},
                {@"size", @"Size", 100, 80, @"size"},
                {@"used", @"Last used", 150, 120, @"lastUsed"},
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

  _emptyIcon = [NSImageView imageViewWithImage:symbol(@"checkmark.circle", 40, NSFontWeightLight)];
  _emptyIcon.contentTintColor = NSColor.tertiaryLabelColor;
  _emptyTitle = label(@"", 15, NSFontWeightSemibold, NSColor.secondaryLabelColor);
  _emptyTitle.alignment = NSTextAlignmentCenter;
  _emptyHint = [NSTextField wrappingLabelWithString:@""];
  _emptyHint.font = [NSFont systemFontOfSize:12];
  _emptyHint.textColor = NSColor.tertiaryLabelColor;
  _emptyHint.alignment = NSTextAlignmentCenter;
  _emptyHint.selectable = NO;
  NSStackView* es = [NSStackView stackViewWithViews:@[ _emptyIcon, _emptyTitle, _emptyHint ]];
  es.orientation = NSUserInterfaceLayoutOrientationVertical;
  es.spacing = 6;
  [es setCustomSpacing:12 afterView:_emptyIcon];
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
  for (NSView* v in @[ _scroll, _empty ]) {
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [_listBox addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
      [v.leadingAnchor constraintEqualToAnchor:_listBox.leadingAnchor],
      [v.trailingAnchor constraintEqualToAnchor:_listBox.trailingAnchor],
      [v.topAnchor constraintEqualToAnchor:_listBox.topAnchor],
      [v.bottomAnchor constraintEqualToAnchor:_listBox.bottomAnchor],
    ]];
  }

  // ── bottom bar
  _status = label(@"Select folders or files to move them to the Trash.", 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
  _status.lineBreakMode = NSLineBreakByTruncatingMiddle;
  _revealButton = [NSButton buttonWithTitle:@"Reveal in Finder" target:self action:@selector(revealSelected:)];
  _trashButton = [NSButton buttonWithTitle:@"Move to Trash…" target:self action:@selector(trashSelected:)];
  _trashButton.keyEquivalent = @"";
  _revealButton.enabled = _trashButton.enabled = NO;
  NSStackView* bottom = [NSStackView stackViewWithViews:@[ _status, _revealButton, _trashButton ]];
  bottom.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  bottom.spacing = 10;
  [_status setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
  [_status setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
  _bottom = bottom;
}

- (NSView*)makeBanner {
  NSImageView* icon = [NSImageView imageViewWithImage:symbol(@"lock.shield", 14, NSFontWeightMedium)];
  icon.contentTintColor = NSColor.systemOrangeColor;
  NSTextField* text = [NSTextField wrappingLabelWithString:
      @"Some folders couldn't be read (Mail, Safari, Messages…). Give Stale Full Disk Access to see everything."];
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
  row.layer.backgroundColor = [NSColor.systemOrangeColor colorWithAlphaComponent:0.12].CGColor;
  row.layer.cornerRadius = 8;
  [text setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
  return row;
}

- (NSMenu*)makeContextMenu {
  NSMenu* m = [NSMenu new];
  m.delegate = self;
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
      {@"folder", @"Scan Folder…", @"folder.badge.plus", @selector(chooseFolder:)},
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
  if (item.action == @selector(trashSelected:) || item.action == @selector(revealSelected:))
    return [self selectedItems].count > 0;
  return !_scanning;
}

- (BOOL)validateMenuItem:(NSMenuItem*)item {
  SEL a = item.action;
  if (a == @selector(trashSelected:) || a == @selector(revealSelected:) || a == @selector(copyPath:))
    return [self selectedItems].count > 0;
  if (a == @selector(modeFromMenu:)) item.state = item.tag == (NSInteger)_mode ? NSControlStateValueOn : NSControlStateValueOff;
  if (a == @selector(cancelScan:)) return _scanning;
  if (a == @selector(rescan:) || a == @selector(chooseFolder:) || a == @selector(scanHome:)) return !_scanning;
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

// ───── scanning ─────

- (void)chooseFolder:(id)sender {
  NSOpenPanel* p = [NSOpenPanel openPanel];
  p.canChooseDirectories = YES;
  p.canChooseFiles = NO;
  p.allowsMultipleSelection = NO;
  p.prompt = @"Scan";
  p.message = @"Choose a folder to analyse";
  p.directoryURL = [NSURL fileURLWithPath:ns_str(_scanPath)];
  [p beginSheetModalForWindow:_window completionHandler:^(NSModalResponse r) {
    if (r == NSModalResponseOK && p.URL) [self scanPath:std_str(p.URL.path)];
  }];
}

- (void)scanHome:(id)sender { [self scanPath:std_str(NSHomeDirectory())]; }
- (void)rescan:(id)sender { if (!_scanPath.empty()) [self scanPath:_scanPath]; }

- (void)cancelScan:(id)sender {
  if (!_scanning) return;
  if (_cancel) _cancel->store(true);
  ++_scanGeneration;
  [self endScanUI];
  _scanPath = _resultPath;
  if (!_model.result || _model.result->dirs.empty()) {
    _window.subtitle = @"";
    [self showEmpty:@"Scan stopped" hint:@"Press Rescan, or choose another folder to analyse." symbol:@"stop.circle"];
  } else {
    _window.subtitle = [self summaryLine];
  }
}

- (NSString*)summaryLine {
  const DirNode& root = _model.result->dirs[0];
  return [NSString stringWithFormat:@"%@  ·  %@  ·  %@", ns_str(_resultPath).stringByAbbreviatingWithTildeInPath,
                                    fmtBytes(root.size), fmtCount(root.files, @"file")];
}

- (void)endScanUI {
  _scanning = NO;
  [_progressTimer invalidate];
  _progressTimer = nil;
  [_spinner stopAnimation:nil];
  _overlay.hidden = YES;
  [_window.toolbar validateVisibleItems];
}

- (void)scanPath:(const std::string&)pathRef {
  const std::string path = pathRef;  // the async block below needs its own copy
  if (_cancel) _cancel->store(true);  // stop any scan in flight; its result is dropped by generation check
  int gen = ++_scanGeneration;
  _scanPath = path;
  _progress = std::make_shared<std::atomic<uint64_t>>(0);
  _cancel = std::make_shared<std::atomic<bool>>(false);
  _scanning = YES;

  NSString* nsPath = ns_str(path);
  NSString* shown = nsPath.stringByAbbreviatingWithTildeInPath;
  _window.subtitle = [NSString stringWithFormat:@"Scanning %@…", shown];
  _overlay.hidden = NO;
  [_spinner startAnimation:nil];
  _overlayText.stringValue = [NSString stringWithFormat:@"Scanning %@", shown];
  _overlayCount.stringValue = @"";
  [_progressTimer invalidate];
  __weak StaleController* weakSelf = self;
  _progressTimer = [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:YES block:^(NSTimer*) {
    StaleController* s = weakSelf;
    if (!s || !s->_progress) return;
    s->_overlayCount.stringValue = fmtCount(s->_progress->load(), @"file");
  }];
  [_window.toolbar validateVisibleItems];

  auto cancelPtr = _cancel;
  auto progressPtr = _progress;
  std::string home = std_str(NSHomeDirectory());
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    ScanOptions o;
    o.root = path;
    o.progressFiles = progressPtr.get();
    o.cancel = cancelPtr.get();
    auto res = std::make_shared<ScanResult>(scan(o));
    std::shared_ptr<ScanResult> sysApps, userApps;
    if (!cancelPtr->load()) {
      const std::string roots[2] = {"/Applications", home + "/Applications"};
      for (int i = 0; i < 2; ++i) {
        struct stat st;
        if (::stat(roots[i].c_str(), &st) != 0) continue;
        ScanOptions ao;
        ao.root = roots[i];
        ao.cancel = cancelPtr.get();
        (i == 0 ? sysApps : userApps) = std::make_shared<ScanResult>(scan(ao));
      }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      if (gen != self->_scanGeneration) return;
      self->_model.result = res;
      self->_model.apps[0] = sysApps;
      self->_model.apps[1] = userApps;
      self->_model.now = res->now;
      [self scanFinished];
    });
  });
}

- (void)scanFinished {
  [self endScanUI];
  _resultPath = _scanPath;
  const ScanResult& r = *_model.result;
  if (r.dirs.empty()) {
    _window.subtitle = @"";
    _root = nil;
    _flat = @[];
    _appItems = nil;
    [_outline reloadData];
    [self showEmpty:@"Couldn't read this folder"
               hint:[NSString stringWithFormat:@"%@ isn't readable. Try another folder, or grant Full Disk Access.",
                                               ns_str(_scanPath).stringByAbbreviatingWithTildeInPath]
             symbol:@"exclamationmark.triangle"];
    return;
  }
  _root = [self itemForDir:0 parent:nil];
  _fdaBanner.hidden = r.errors < 20;
  _appItems = nil;
  [self refreshSummary];
  [self showMode:_mode];
}

- (NSString*)scanTitle {
  return _resultPath == std_str(NSHomeDirectory()) ? @"Home" : ns_str(_resultPath).lastPathComponent;
}

// Header, usage bar, legend, cards, sidebar badges; recomputed after a scan and after trashing.
- (void)refreshSummary {
  const ScanResult& r = *_model.result;
  const DirNode& root = r.dirs[0];

  _window.subtitle = [self summaryLine];
  _bigNumber.stringValue = fmtBytes(root.size);
  _bigSub.stringValue = [NSString
      stringWithFormat:@"in %@  ·  %@  ·  scanned in %.1f s%@", ns_str(_resultPath).stringByAbbreviatingWithTildeInPath,
                       fmtCount(root.files, @"file"), r.seconds,
                       r.spotlightHits ? @"" : @"  ·  no Spotlight “last opened” data here, so dates are last modified"];

  std::vector<double> parts;
  for (int b = 0; b < NBUCKETS; ++b) parts.push_back((double)root.bucketSize[b]);
  _bar.parts = parts;
  [_bar setNeedsDisplay:YES];

  for (NSView* v in [_legend.views copy]) [_legend removeView:v];
  for (int b = 0; b <= NBUCKETS; ++b) {
    uint64_t bytes = b < NBUCKETS ? root.bucketSize[b] : root.neverOpenedSize;
    double pct = root.size ? 100.0 * bytes / root.size : 0;
    [_legend addView:[self legendItem:b bytes:bytes pct:pct] inGravity:NSStackViewGravityLeading];
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
    if (bucketFor(f.lastUsed, r.now) >= STALE) { bigBytes += f.size; ++bigCount; }
  if (!_appItems) [self buildAppItems];
  uint64_t appBytes = 0, unusedAppBytes = 0;
  size_t unusedApps = 0;
  for (Item* it in _appItems) {
    appBytes += it.size;
    if (it.lastUsed <= 0 || bucketFor(it.lastUsed, r.now) >= STALE) { unusedAppBytes += it.size; ++unusedApps; }
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
      default: e.badge = nil;
    }
  }
  // Refresh badges in place; reloadData would drop the selection and bounce the mode.
  if (_sidebar.numberOfRows == 0) [_sidebar reloadData];
  else [_sidebar reloadDataForRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, (NSUInteger)_sidebar.numberOfRows)]
                           columnIndexes:[NSIndexSet indexSetWithIndex:0]];
  [self syncSidebar];

  // Biggest top-level folders.
  for (NSView* v in [_topList.views copy]) [_topList removeView:v];
  std::vector<int32_t> kids;
  for (int32_t c : root.children) if (!r.dirs[c].path.empty()) kids.push_back(c);
  std::sort(kids.begin(), kids.end(), [&](int32_t a, int32_t b) { return r.dirs[a].size > r.dirs[b].size; });
  if (kids.size() > 8) kids.resize(8);
  for (int32_t c : kids) {
    const DirNode& d = r.dirs[c];
    NSView* row = [self topRow:d total:root.size];
    [_topList addView:row inGravity:NSStackViewGravityTop];
    [row.widthAnchor constraintEqualToAnchor:_topList.widthAnchor].active = YES;
  }
  _topTitle.hidden = _topList.hidden = kids.empty();
}

- (NSView*)legendItem:(int)bucket bytes:(uint64_t)bytes pct:(double)pct {
  NSView* dot = [NSView new];
  dot.wantsLayer = YES;
  dot.layer.backgroundColor = kBucketColors[bucket].CGColor;
  dot.layer.cornerRadius = 4;
  [dot.widthAnchor constraintEqualToConstant:8].active = YES;
  [dot.heightAnchor constraintEqualToConstant:8].active = YES;
  NSTextField* name = label(kBucketLabels[bucket], 11, NSFontWeightMedium, NSColor.secondaryLabelColor);
  NSStackView* top = [NSStackView stackViewWithViews:@[ dot, name ]];
  top.spacing = 5;
  NSTextField* val = label([NSString stringWithFormat:@"%@", fmtBytes(bytes)], 13, NSFontWeightSemibold, NSColor.labelColor);
  val.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold];
  NSTextField* p = label([NSString stringWithFormat:@"%.0f%%", pct], 11, NSFontWeightRegular, NSColor.tertiaryLabelColor);
  p.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
  NSStackView* bottom = [NSStackView stackViewWithViews:@[ val, p ]];
  bottom.spacing = 4;
  bottom.alignment = NSLayoutAttributeFirstBaseline;
  NSStackView* col = [NSStackView stackViewWithViews:@[ top, bottom ]];
  col.orientation = NSUserInterfaceLayoutOrientationVertical;
  col.alignment = NSLayoutAttributeLeading;
  col.spacing = 3;
  [name setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
  return col;
}

- (NSView*)topRow:(const DirNode&)d total:(uint64_t)total {
  NSString* path = ns_str(d.path);
  NSImageView* icon = [NSImageView imageViewWithImage:[[NSWorkspace sharedWorkspace] iconForFile:path]];
  [icon.widthAnchor constraintEqualToConstant:18].active = YES;
  [icon.heightAnchor constraintEqualToConstant:18].active = YES;
  NSTextField* name = label(path.lastPathComponent, 13, NSFontWeightRegular, NSColor.labelColor);
  NSString* hint = categoryHint(d.category);
  NSTextField* note = label(hint.length ? categoryTitle(d.category) : fmtCount(d.files, @"file"), 12, NSFontWeightRegular,
                            NSColor.tertiaryLabelColor);
  UsageBarView* bar = [UsageBarView new];
  std::vector<double> parts;
  for (int b = 0; b < NBUCKETS; ++b) parts.push_back((double)d.bucketSize[b]);
  bar.parts = parts;
  [bar.heightAnchor constraintEqualToConstant:6].active = YES;
  NSLayoutConstraint* w = [bar.widthAnchor constraintEqualToConstant:std::max(6.0, 160.0 * (total ? (double)d.size / total : 0))];
  w.active = YES;
  NSView* barBox = [NSView new];
  bar.translatesAutoresizingMaskIntoConstraints = NO;
  [barBox addSubview:bar];
  [NSLayoutConstraint activateConstraints:@[
    [barBox.widthAnchor constraintEqualToConstant:160],
    [bar.leadingAnchor constraintEqualToAnchor:barBox.leadingAnchor],
    [bar.centerYAnchor constraintEqualToAnchor:barBox.centerYAnchor],
    [barBox.heightAnchor constraintEqualToConstant:6],
  ]];
  NSTextField* size = label(fmtBytes(d.size), 13, NSFontWeightMedium, NSColor.labelColor);
  size.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightMedium];
  size.alignment = NSTextAlignmentRight;
  [size.widthAnchor constraintEqualToConstant:80].active = YES;
  NSTextField* used = label(fmtAgo(d.lastUsed, _model.now), 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
  used.alignment = NSTextAlignmentRight;
  [used.widthAnchor constraintEqualToConstant:110].active = YES;
  NSStackView* row = [NSStackView stackViewWithViews:@[ icon, name, note, barBox, size, used ]];
  row.spacing = 10;
  row.edgeInsets = NSEdgeInsetsMake(6, 4, 6, 4);
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
    if (!_model.apps[k] || _model.apps[k]->dirs.empty()) continue;
    const ScanResult& ar = *_model.apps[k];
    std::vector<int32_t> appIds;
    collectUnits(ar, 0, appIds, [](const DirNode& d) { return d.category == CAT_APP; });
    for (int32_t i : appIds) {
      const DirNode& d = ar.dirs[i];
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
      it.dirId = -1;
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
  // Files are not kept by the scanner; list them now.
  if (DIR* dp = opendir(item.path.fileSystemRepresentation)) {
    struct stat st;
    while (struct dirent* de = readdir(dp)) {
      if (de->d_name[0] == '.' && (de->d_name[1] == 0 || (de->d_name[1] == '.' && de->d_name[2] == 0))) continue;
      if (fstatat(dirfd(dp), de->d_name, &st, AT_SYMLINK_NOFOLLOW) != 0 || S_ISDIR(st.st_mode)) continue;
      std::string full = std_str(item.path) + "/" + de->d_name;
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
  item.children = kids;
  [self sortItems:kids];
}

- (void)sortItems:(NSMutableArray<Item*>*)items {
  NSString* key = _sortKey;
  BOOL asc = _sortAscending;
  [items sortUsingComparator:^NSComparisonResult(Item* a, Item* b) {
    NSComparisonResult r;
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
  _listBox.hidden = NO;
  _scroll.hidden = YES;
  _bottom.hidden = YES;
  _empty.hidden = NO;
  _emptyIcon.image = symbol(sym, 40, NSFontWeightLight);
  _emptyTitle.stringValue = title;
  _emptyHint.stringValue = hint;
}

- (void)showMode:(Mode)m {
  _mode = m;
  [self syncSidebar];
  const ModeInfo& mi = kModes[(int)m];
  const ScanResult* r = _model.result.get();
  BOOL haveScan = r && !r->dirs.empty();

  _pageTitle.stringValue = m == Mode::Overview ? [self scanTitle] : mi.title;
  _pageHint.stringValue = m == Mode::Overview ? @"" : mi.hint;
  _pageHint.hidden = m == Mode::Overview;

  if (!haveScan) {
    if (!_scanning) [self showEmpty:@"Nothing scanned yet" hint:@"Choose a folder to analyse." symbol:@"folder.badge.questionmark"];
    return;
  }
  if (m == Mode::Overview) {
    _overviewScroll.hidden = NO;
    _listBox.hidden = YES;
    _bottom.hidden = YES;
    return;
  }

  NSMutableArray<Item*>* flat = [NSMutableArray new];
  switch (m) {
    case Mode::Reclaim: {
      std::vector<int32_t> ids;
      collectUnits(*r, 0, ids, [](const DirNode& d) { return categoryReclaimable(d.category); });
      for (int32_t i : ids) [flat addObject:[self itemForDir:i parent:nil]];
      break;
    }
    case Mode::Forgotten: {
      std::vector<int32_t> ids;
      collectForgotten(*r, 0, ids, 50ull << 20);
      for (int32_t i : ids) [flat addObject:[self itemForDir:i parent:nil]];
      break;
    }
    case Mode::BigFiles:
      for (const FileRec& f : r->bigFiles)
        if (bucketFor(f.lastUsed, r->now) >= STALE)
          [flat addObject:[self itemForFile:f.path size:f.size lastUsed:f.lastUsed never:f.neverOpened parent:nil]];
      break;
    case Mode::Apps:
      [flat addObjectsFromArray:_appItems ?: @[]];
      break;
    default: break;
  }
  [self sortItems:flat];
  _flat = flat;
  [_outline reloadData];
  [_outline deselectAll:nil];
  [self selectionChanged];

  BOOL empty = [self topItems].count == 0;
  _overviewScroll.hidden = YES;
  _listBox.hidden = NO;
  _scroll.hidden = empty;
  [_outline sizeLastColumnToFit];
  if (!empty) [_window makeFirstResponder:_outline];
  _bottom.hidden = empty;
  _empty.hidden = !empty;
  if (empty) {
    _emptyIcon.image = symbol(m == Mode::Browse ? @"folder" : @"checkmark.circle", 40, NSFontWeightLight);
    _emptyTitle.stringValue = mi.emptyTitle;
    _emptyHint.stringValue = mi.emptyHint;
  }
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
  if (ov == _sidebar) return ((SidebarEntry*)obj).isGroup ? 26 : 28;
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
      [iv.widthAnchor constraintEqualToConstant:16],
      [iv.heightAnchor constraintEqualToConstant:16],
    ]];
    lead = 24;
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
    badge = label(@"", 11, NSFontWeightMedium, NSColor.secondaryLabelColor);
    badge.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium];
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
    v.textField.stringValue = name;
    v.textField.textColor = NSColor.labelColor;
    v.toolTip = item.path;
    return v;
  }
  if ([id isEqual:@"size"]) {
    SizeCellView* v = (SizeCellView*)[self cellWithId:@"sizeCell" inView:ov image:NO size:YES];
    v.textField.alignment = NSTextAlignmentRight;
    v.textField.stringValue = fmtBytes(item.size);
    v.textField.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
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
            attributes:@{NSForegroundColorAttributeName : color, NSFontAttributeName : [NSFont systemFontOfSize:11]}];
    [s appendAttributedString:[[NSAttributedString alloc]
                                  initWithString:text
                                      attributes:@{
                                        NSForegroundColorAttributeName : NSColor.labelColor,
                                        NSFontAttributeName : [NSFont systemFontOfSize:13]
                                      }]];
    v.textField.attributedStringValue = s;
    v.toolTip = item.lastUsed > 0
                    ? [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:item.lastUsed]
                                                     dateStyle:NSDateFormatterMediumStyle
                                                     timeStyle:NSDateFormatterShortStyle]
                    : @"";
    return v;
  }
  // note
  NSTableCellView* v = [self cellWithId:@"noteCell" inView:ov image:NO size:NO];
  NSMutableArray<NSString*>* parts = [NSMutableArray new];
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
  if (!any) {
    _status.stringValue = @"Select folders or files to move them to the Trash.";
  } else if (sel.count == 1) {
    Item* it = sel[0];
    _status.stringValue = [NSString stringWithFormat:@"%@  ·  %@  ·  last used %@", it.path.stringByAbbreviatingWithTildeInPath,
                                                     fmtBytes(it.size), [fmtAgo(it.lastUsed, _model.now) lowercaseString]];
  } else {
    _status.stringValue = [NSString stringWithFormat:@"%@ selected  ·  %@", fmtCount(sel.count, @"item"), fmtBytes(total)];
  }
  [_window.toolbar validateVisibleItems];
}

- (void)doubleClicked:(id)sender {
  NSInteger row = _outline.clickedRow;
  if (row < 0) return;
  Item* it = [_outline itemAtRow:row];
  if ([self outlineView:_outline isItemExpandable:it]) {
    if ([_outline isItemExpanded:it]) [_outline collapseItem:it];
    else [_outline expandItem:it];
  } else {
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[ [NSURL fileURLWithPath:it.path] ]];
  }
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
  [_outline reloadData];
  [self selectionChanged];
  if (_model.result && !_model.result->dirs.empty()) {
    [self refreshSummary];
    if ([self topItems].count == 0) [self showMode:_mode];  // switch to the empty state
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

// Remove from the tree and flat lists, and shrink every ancestor.
- (void)removeItem:(Item*)it {
  for (Item* p = it.parent; p; p = p.parent) {
    p.size = p.size >= it.size ? p.size - it.size : 0;
    p.files = p.files >= it.files ? p.files - it.files : 0;
  }
  if (it.parent) [it.parent.children removeObject:it];
  else if (_root && _root.children) [_root.children removeObject:it];
  NSMutableArray* flat = [_flat mutableCopy];
  [flat removeObject:it];
  _flat = flat;
  [_appItems removeObject:it];
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
    const DirNode gone = r.dirs[(size_t)it.dirId];
    bool reclaim = gone.unit && categoryReclaimable(gone.category);
    for (int32_t p = gone.parent; p >= 0; p = r.dirs[(size_t)p].parent) {
      DirNode& a = r.dirs[(size_t)p];
      sub(a.size, gone.size);
      sub(a.files, gone.files);
      sub(a.neverOpenedSize, gone.neverOpenedSize);
      sub(a.reclaimableSize, reclaim ? gone.size : gone.reclaimableSize);
      for (int b = 0; b < NBUCKETS; ++b) {
        sub(a.bucketSize[b], gone.bucketSize[b]);
        sub(a.reclaimableBucketSize[b], reclaim ? gone.bucketSize[b] : gone.reclaimableBucketSize[b]);
      }
    }
    DirNode& d = r.dirs[(size_t)it.dirId];
    if (d.parent >= 0) {
      auto& sib = r.dirs[(size_t)d.parent].children;
      sib.erase(std::remove(sib.begin(), sib.end(), it.dirId), sib.end());
    }
    d.path.clear();
    d.size = 0;
  } else if (!it.isDir) {
    int32_t start = -1;
    for (Item* p = it.parent; p && start < 0; p = p.parent) start = p.dirId;
    int bucket = bucketFor(it.lastUsed, _model.now);
    for (int32_t p = start; p >= 0; p = r.dirs[(size_t)p].parent) {
      DirNode& a = r.dirs[(size_t)p];
      sub(a.size, it.size);
      sub(a.files, 1);
      sub(a.bucketSize[bucket], it.size);
      if (it.never) sub(a.neverOpenedSize, it.size);
    }
  }
  // Items removed from a flat list aren't linked to the browse tree; rebuild it lazily.
  if (!it.parent && _mode != Mode::Browse && !r.dirs.empty()) _root = [self itemForDir:0 parent:nil];
  else if (_root && !r.dirs.empty()) _root.size = r.dirs[0].size;
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
