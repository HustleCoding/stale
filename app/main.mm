// Stale.app — a native window over the stale scanner.
// One folder tree with size / last-used / what-is-it columns, a usage bar, and a
// "Move to Trash" button. Everything goes to the Trash, nothing is deleted outright.
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

static NSColor* bucketColor(double lastUsed, double now) {
  if (lastUsed <= 0) return NSColor.systemGrayColor;
  switch (bucketFor(lastUsed, now)) {
    case HOT: return NSColor.systemGreenColor;
    case WARM: return NSColor.systemTealColor;
    case COLD: return NSColor.systemYellowColor;
    case STALE: return NSColor.systemOrangeColor;
    default: return NSColor.systemRedColor;
  }
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
    case CAT_APP: return @"";
    default: return @"";
  }
}

static std::string std_str(NSString* s) { return s ? std::string(s.UTF8String) : std::string(); }
static NSString* ns_str(const std::string& s) { return [NSString stringWithUTF8String:s.c_str()] ?: @""; }

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

enum class Mode { Browse = 0, Reclaim, Forgotten, BigFiles, Apps };

// ───────────────────────────── views ─────────────────────────────

@interface UsageBarView : NSView
@property(nonatomic) std::vector<double> parts;  // 6 values: 5 buckets + never
@end
@implementation UsageBarView
- (void)drawRect:(NSRect)r {
  NSBezierPath* clip = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:5 yRadius:5];
  [clip addClip];
  [NSColor.quaternaryLabelColor setFill];
  NSRectFill(self.bounds);
  double total = 0;
  for (double v : _parts) total += v;
  if (total <= 0) return;
  NSColor* colors[6] = {NSColor.systemGreenColor, NSColor.systemTealColor, NSColor.systemYellowColor,
                        NSColor.systemOrangeColor, NSColor.systemRedColor, NSColor.systemGrayColor};
  CGFloat x = 0;
  for (size_t i = 0; i < _parts.size() && i < 6; ++i) {
    CGFloat w = self.bounds.size.width * _parts[i] / total;
    [colors[i] setFill];
    NSRectFill(NSMakeRect(x, 0, w, self.bounds.size.height));
    x += w;
  }
}
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

// ───────────────────────────── controller ─────────────────────────────

@interface StaleController : NSObject <NSApplicationDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate,
                                       NSToolbarDelegate, NSMenuDelegate>
@end

@implementation StaleController {
  NSWindow* _window;
  NSOutlineView* _outline;
  NSScrollView* _scroll;
  NSTextField* _title;
  NSTextField* _subtitle;
  UsageBarView* _bar;
  NSStackView* _legend;
  NSSegmentedControl* _modes;
  NSTextField* _hint;
  NSTextField* _status;
  NSButton* _trashButton;
  NSButton* _revealButton;
  NSView* _overlay;
  NSTextField* _overlayText;
  NSProgressIndicator* _spinner;
  NSView* _fdaBanner;
  NSTimer* _progressTimer;

  Model _model;
  Item* _root;
  NSArray<Item*>* _flat;  // items shown in non-browse modes
  NSMutableArray<Item*>* _appItems;
  Mode _mode;
  std::string _scanPath;
  std::shared_ptr<std::atomic<uint64_t>> _progress;
  std::shared_ptr<std::atomic<bool>> _cancel;  // owned by the scan in flight
  int _scanGeneration;
  NSString* _sortKey;
  BOOL _sortAscending;
}

// ───── app lifecycle ─────

- (void)applicationDidFinishLaunching:(NSNotification*)n {
  _sortKey = @"size";
  _sortAscending = NO;
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

- (void)buildMenus {
  NSMenu* menubar = [NSMenu new];
  NSMenuItem* appItem = [NSMenuItem new];
  [menubar addItem:appItem];
  NSMenu* app = [NSMenu new];
  [app addItemWithTitle:@"About Stale" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
  [app addItem:NSMenuItem.separatorItem];
  [app addItemWithTitle:@"Hide Stale" action:@selector(hide:) keyEquivalent:@"h"];
  [app addItem:NSMenuItem.separatorItem];
  [app addItemWithTitle:@"Quit Stale" action:@selector(terminate:) keyEquivalent:@"q"];
  appItem.submenu = app;

  NSMenuItem* fileItem = [NSMenuItem new];
  [menubar addItem:fileItem];
  NSMenu* file = [[NSMenu alloc] initWithTitle:@"File"];
  [file addItemWithTitle:@"Scan Folder…" action:@selector(chooseFolder:) keyEquivalent:@"o"];
  [file addItemWithTitle:@"Scan Home Folder" action:@selector(scanHome:) keyEquivalent:@"H"];
  [file addItemWithTitle:@"Rescan" action:@selector(rescan:) keyEquivalent:@"r"];
  [file addItem:NSMenuItem.separatorItem];
  [file addItemWithTitle:@"Reveal in Finder" action:@selector(revealSelected:) keyEquivalent:@"R"];
  NSMenuItem* trash = [file addItemWithTitle:@"Move to Trash" action:@selector(trashSelected:) keyEquivalent:@"\x7f"];
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
  NSArray* names = @[ @"All Folders", @"Safe to Delete", @"Forgotten", @"Big Unused Files", @"Apps" ];
  for (NSUInteger i = 0; i < names.count; ++i) {
    NSMenuItem* mi = [view addItemWithTitle:names[i] action:@selector(modeFromMenu:)
                              keyEquivalent:[NSString stringWithFormat:@"%lu", (unsigned long)(i + 1)]];
    mi.tag = (NSInteger)i;
  }
  viewItem.submenu = view;
  NSApp.mainMenu = menubar;
}

- (void)buildWindow {
  NSRect frame = NSMakeRect(0, 0, 1080, 720);
  _window = [[NSWindow alloc]
      initWithContentRect:frame
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                          NSWindowStyleMaskResizable
                  backing:NSBackingStoreBuffered
                    defer:NO];
  _window.title = @"Stale";
  _window.minSize = NSMakeSize(760, 480);
  _window.toolbarStyle = NSWindowToolbarStyleUnified;
  NSToolbar* tb = [[NSToolbar alloc] initWithIdentifier:@"main"];
  tb.delegate = self;
  tb.displayMode = NSToolbarDisplayModeIconAndLabel;
  _window.toolbar = tb;
  [_window center];
  [_window setFrameAutosaveName:@"StaleMain"];

  NSView* content = _window.contentView;

  // ── header
  _title = [NSTextField labelWithString:@"Home"];
  _title.font = [NSFont systemFontOfSize:22 weight:NSFontWeightSemibold];
  _subtitle = [NSTextField labelWithString:@""];
  _subtitle.font = [NSFont systemFontOfSize:12];
  _subtitle.textColor = NSColor.secondaryLabelColor;
  _subtitle.lineBreakMode = NSLineBreakByTruncatingMiddle;

  _bar = [UsageBarView new];
  [_bar.heightAnchor constraintEqualToConstant:14].active = YES;

  _legend = [NSStackView new];
  _legend.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  _legend.spacing = 16;
  _legend.alignment = NSLayoutAttributeCenterY;

  NSStackView* header = [NSStackView stackViewWithViews:@[ _title, _subtitle, _bar, _legend ]];
  header.orientation = NSUserInterfaceLayoutOrientationVertical;
  header.alignment = NSLayoutAttributeLeading;
  header.spacing = 6;
  [header setCustomSpacing:14 afterView:_subtitle];
  [header setCustomSpacing:8 afterView:_bar];

  // ── Full Disk Access banner (hidden unless needed)
  _fdaBanner = [self makeBanner];
  _fdaBanner.hidden = YES;

  // ── mode switcher + hint
  _modes = [NSSegmentedControl
      segmentedControlWithLabels:@[ @"All folders", @"Safe to delete", @"Forgotten", @"Big unused files", @"Apps" ]
                    trackingMode:NSSegmentSwitchTrackingSelectOne
                          target:self
                          action:@selector(modeChanged:)];
  _modes.selectedSegment = 0;
  _modes.segmentStyle = NSSegmentStyleAutomatic;
  _hint = [NSTextField wrappingLabelWithString:@""];
  _hint.font = [NSFont systemFontOfSize:12];
  _hint.textColor = NSColor.secondaryLabelColor;
  _hint.selectable = NO;

  // ── outline
  _outline = [NSOutlineView new];
  _outline.dataSource = self;
  _outline.delegate = self;
  _outline.allowsMultipleSelection = YES;
  _outline.usesAlternatingRowBackgroundColors = YES;
  _outline.rowHeight = 22;
  _outline.autoresizesOutlineColumn = YES;
  _outline.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
  _outline.doubleAction = @selector(doubleClicked:);
  _outline.target = self;
  _outline.autosaveTableColumns = YES;
  _outline.autosaveName = @"StaleColumns";
  _outline.menu = [self makeContextMenu];

  struct Col { NSString* id; NSString* title; CGFloat w; CGFloat minW; NSString* sortKey; };
  Col cols[] = {{@"name", @"Name", 380, 200, @"name"},
                {@"size", @"Size", 110, 80, @"size"},
                {@"used", @"Last used", 170, 120, @"lastUsed"},
                {@"note", @"What is it", 320, 120, nil}};
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
  _scroll.borderType = NSBezelBorder;

  // ── bottom bar
  _status = [NSTextField labelWithString:@"Select folders or files to move them to the Trash."];
  _status.textColor = NSColor.secondaryLabelColor;
  _status.font = [NSFont systemFontOfSize:12];
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

  NSStackView* modeRow = [NSStackView stackViewWithViews:@[ _modes ]];
  modeRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;

  NSStackView* main = [NSStackView stackViewWithViews:@[ header, _fdaBanner, modeRow, _hint, _scroll, bottom ]];
  main.orientation = NSUserInterfaceLayoutOrientationVertical;
  main.alignment = NSLayoutAttributeLeading;
  main.spacing = 10;
  [main setCustomSpacing:16 afterView:header];
  [main setCustomSpacing:6 afterView:modeRow];
  main.translatesAutoresizingMaskIntoConstraints = NO;
  [content addSubview:main];
  [NSLayoutConstraint activateConstraints:@[
    [main.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
    [main.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
    [main.topAnchor constraintEqualToAnchor:content.topAnchor constant:16],
    [main.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-14],
    [header.widthAnchor constraintEqualToAnchor:main.widthAnchor],
    [_bar.widthAnchor constraintEqualToAnchor:header.widthAnchor],
    [_subtitle.widthAnchor constraintEqualToAnchor:header.widthAnchor],
    [_fdaBanner.widthAnchor constraintEqualToAnchor:main.widthAnchor],
    [_hint.widthAnchor constraintEqualToAnchor:main.widthAnchor],
    [_scroll.widthAnchor constraintEqualToAnchor:main.widthAnchor],
    [bottom.widthAnchor constraintEqualToAnchor:main.widthAnchor],
  ]];
  [_scroll setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];

  // ── scanning overlay
  _overlay = [NSView new];
  _overlay.wantsLayer = YES;
  _overlay.layer.backgroundColor = [NSColor.windowBackgroundColor colorWithAlphaComponent:0.85].CGColor;
  _spinner = [NSProgressIndicator new];
  _spinner.style = NSProgressIndicatorStyleSpinning;
  _spinner.controlSize = NSControlSizeRegular;
  _overlayText = [NSTextField labelWithString:@"Scanning…"];
  _overlayText.alignment = NSTextAlignmentCenter;
  _overlayText.font = [NSFont systemFontOfSize:13];
  _overlayText.textColor = NSColor.secondaryLabelColor;
  NSStackView* ov = [NSStackView stackViewWithViews:@[ _spinner, _overlayText ]];
  ov.orientation = NSUserInterfaceLayoutOrientationVertical;
  ov.spacing = 12;
  ov.translatesAutoresizingMaskIntoConstraints = NO;
  [_overlay addSubview:ov];
  _overlay.translatesAutoresizingMaskIntoConstraints = NO;
  [content addSubview:_overlay];
  [NSLayoutConstraint activateConstraints:@[
    [_overlay.leadingAnchor constraintEqualToAnchor:_scroll.leadingAnchor],
    [_overlay.trailingAnchor constraintEqualToAnchor:_scroll.trailingAnchor],
    [_overlay.topAnchor constraintEqualToAnchor:_scroll.topAnchor],
    [_overlay.bottomAnchor constraintEqualToAnchor:_scroll.bottomAnchor],
    [ov.centerXAnchor constraintEqualToAnchor:_overlay.centerXAnchor],
    [ov.centerYAnchor constraintEqualToAnchor:_overlay.centerYAnchor],
  ]];
  _overlay.hidden = YES;

  [_window makeKeyAndOrderFront:nil];
}

- (NSView*)makeBanner {
  NSTextField* text = [NSTextField wrappingLabelWithString:
      @"Some folders couldn't be read (Mail, Safari, Messages…). Give Stale Full Disk Access to see everything."];
  text.font = [NSFont systemFontOfSize:12];
  NSButton* open = [NSButton buttonWithTitle:@"Open Privacy Settings" target:self action:@selector(openFDA:)];
  open.controlSize = NSControlSizeSmall;
  open.font = [NSFont systemFontOfSize:11];
  NSStackView* row = [NSStackView stackViewWithViews:@[ text, open ]];
  row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  row.spacing = 12;
  row.edgeInsets = NSEdgeInsetsMake(8, 12, 8, 12);
  row.wantsLayer = YES;
  row.layer.backgroundColor = [NSColor.systemYellowColor colorWithAlphaComponent:0.15].CGColor;
  row.layer.cornerRadius = 6;
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
  return @[ @"folder", @"rescan", NSToolbarFlexibleSpaceItemIdentifier, @"reveal", @"trash" ];
}
- (NSArray<NSToolbarItemIdentifier>*)toolbarAllowedItemIdentifiers:(NSToolbar*)tb {
  return [self toolbarDefaultItemIdentifiers:tb];
}
- (NSToolbarItem*)toolbar:(NSToolbar*)tb itemForItemIdentifier:(NSToolbarItemIdentifier)id
    willBeInsertedIntoToolbar:(BOOL)flag {
  NSToolbarItem* it = [[NSToolbarItem alloc] initWithItemIdentifier:id];
  it.target = self;
  if ([id isEqual:@"folder"]) {
    it.label = @"Scan Folder…";
    it.image = [NSImage imageWithSystemSymbolName:@"folder" accessibilityDescription:nil];
    it.action = @selector(chooseFolder:);
  } else if ([id isEqual:@"rescan"]) {
    it.label = @"Rescan";
    it.image = [NSImage imageWithSystemSymbolName:@"arrow.clockwise" accessibilityDescription:nil];
    it.action = @selector(rescan:);
  } else if ([id isEqual:@"reveal"]) {
    it.label = @"Show in Finder";
    it.image = [NSImage imageWithSystemSymbolName:@"magnifyingglass" accessibilityDescription:nil];
    it.action = @selector(revealSelected:);
  } else if ([id isEqual:@"trash"]) {
    it.label = @"Move to Trash";
    it.image = [NSImage imageWithSystemSymbolName:@"trash" accessibilityDescription:nil];
    it.action = @selector(trashSelected:);
  }
  it.toolTip = it.label;
  return it;
}

- (BOOL)validateToolbarItem:(NSToolbarItem*)item {
  if (item.action == @selector(trashSelected:) || item.action == @selector(revealSelected:))
    return [self selectedItems].count > 0;
  return _overlay.hidden;
}

- (BOOL)validateMenuItem:(NSMenuItem*)item {
  if (item.action == @selector(trashSelected:) || item.action == @selector(revealSelected:) ||
      item.action == @selector(copyPath:))
    return [self selectedItems].count > 0;
  if (item.action == @selector(modeFromMenu:)) item.state = item.tag == (NSInteger)_mode ? NSControlStateValueOn : NSControlStateValueOff;
  return YES;
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

- (void)scanPath:(const std::string&)pathRef {
  const std::string path = pathRef;  // the async block below needs its own copy
  if (_cancel) _cancel->store(true);  // stop any scan in flight; its result is dropped by generation check
  int gen = ++_scanGeneration;
  _scanPath = path;
  _progress = std::make_shared<std::atomic<uint64_t>>(0);
  _cancel = std::make_shared<std::atomic<bool>>(false);

  NSString* nsPath = ns_str(path);
  _title.stringValue = path == std_str(NSHomeDirectory()) ? @"Home" : nsPath.lastPathComponent;
  _subtitle.stringValue = [nsPath stringByAbbreviatingWithTildeInPath];
  _overlay.hidden = NO;
  [_spinner startAnimation:nil];
  _overlayText.stringValue = [NSString stringWithFormat:@"Scanning %@…", nsPath.stringByAbbreviatingWithTildeInPath];
  [_progressTimer invalidate];
  __weak StaleController* weakSelf = self;
  _progressTimer = [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:YES block:^(NSTimer*) {
    StaleController* s = weakSelf;
    if (!s) return;
    s->_overlayText.stringValue =
        [NSString stringWithFormat:@"Scanning %@…\n%@", nsPath.stringByAbbreviatingWithTildeInPath,
                                   fmtCount(s->_progress->load(), @"file")];
  }];

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
  [_progressTimer invalidate];
  _progressTimer = nil;
  [_spinner stopAnimation:nil];
  _overlay.hidden = YES;

  const ScanResult& r = *_model.result;
  if (r.dirs.empty()) {
    _subtitle.stringValue = [NSString stringWithFormat:@"Couldn't read %@", ns_str(_scanPath)];
    _root = nil;
    _flat = @[];
    [_outline reloadData];
    return;
  }
  const DirNode& root = r.dirs[0];
  _root = [self itemForDir:0 parent:nil];
  _subtitle.stringValue = [NSString
      stringWithFormat:@"%@  ·  %@  ·  %@  ·  scanned in %.1f s%@", ns_str(_scanPath).stringByAbbreviatingWithTildeInPath,
                       fmtBytes(root.size), fmtCount(root.files, @"file"), r.seconds,
                       r.spotlightHits ? @"" : @"  ·  no Spotlight “last opened” data here, using modified dates"];
  _fdaBanner.hidden = r.errors < 20;
  _appItems = nil;
  [self refreshSummary];
  [self showMode:_mode];
}

// Usage bar, legend and the per-mode totals; recomputed after a scan and after trashing.
- (void)refreshSummary {
  const ScanResult& r = *_model.result;
  const DirNode& root = r.dirs[0];

  std::vector<double> parts;
  for (int b = 0; b < NBUCKETS; ++b) parts.push_back((double)root.bucketSize[b]);
  parts.push_back(0);  // never-opened is a subset of the buckets; shown in legend only
  _bar.parts = parts;
  [_bar setNeedsDisplay:YES];

  NSString* names[] = {@"This week", @"This month", @"< 6 months", @"6–12 months", @"> 1 year"};
  NSColor* colors[] = {NSColor.systemGreenColor, NSColor.systemTealColor, NSColor.systemYellowColor,
                       NSColor.systemOrangeColor, NSColor.systemRedColor};
  for (NSView* v in [_legend.views copy]) [_legend removeView:v];
  for (int b = 0; b < NBUCKETS; ++b) {
    double pct = root.size ? 100.0 * root.bucketSize[b] / root.size : 0;
    [_legend addView:[self legendLabel:colors[b]
                                  text:[NSString stringWithFormat:@"%@ %@ · %.0f%%", names[b],
                                                                  fmtBytes(root.bucketSize[b]), pct]]
          inGravity:NSStackViewGravityLeading];
  }
  [_legend addView:[self legendLabel:NSColor.systemGrayColor
                                text:[NSString stringWithFormat:@"Never opened %@", fmtBytes(root.neverOpenedSize)]]
        inGravity:NSStackViewGravityLeading];

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
  for (const FileRec& f : r.bigFiles)
    if (bucketFor(f.lastUsed, r.now) >= STALE) bigBytes += f.size;

  [_modes setLabel:[NSString stringWithFormat:@"Safe to delete · %@", fmtBytes(reclaimBytes)] forSegment:1];
  [_modes setLabel:[NSString stringWithFormat:@"Forgotten · %@", fmtBytes(forgottenBytes)] forSegment:2];
  [_modes setLabel:[NSString stringWithFormat:@"Big unused files · %@", fmtBytes(bigBytes)] forSegment:3];

  if (!_appItems) [self buildAppItems];
  uint64_t appBytes = 0;
  for (Item* it in _appItems) appBytes += it.size;
  [_modes setLabel:[NSString stringWithFormat:@"Apps · %@", fmtBytes(appBytes)] forSegment:4];
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

- (NSTextField*)legendLabel:(NSColor*)color text:(NSString*)text {
  NSMutableAttributedString* s = [[NSMutableAttributedString alloc]
      initWithString:@"● "
          attributes:@{NSForegroundColorAttributeName : color, NSFontAttributeName : [NSFont systemFontOfSize:12]}];
  [s appendAttributedString:[[NSAttributedString alloc]
                                initWithString:text
                                    attributes:@{
                                      NSForegroundColorAttributeName : NSColor.secondaryLabelColor,
                                      NSFontAttributeName : [NSFont systemFontOfSize:12]
                                    }]];
  NSTextField* l = [NSTextField labelWithAttributedString:s];
  l.maximumNumberOfLines = 1;
  l.lineBreakMode = NSLineBreakByTruncatingTail;
  [l setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
  return l;
}

- (void)openFDA:(id)sender {
  [[NSWorkspace sharedWorkspace]
      openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"]];
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

- (void)showMode:(Mode)m {
  _mode = m;
  _modes.selectedSegment = (NSInteger)m;
  const ScanResult* r = _model.result.get();
  NSMutableArray<Item*>* flat = [NSMutableArray new];
  switch (m) {
    case Mode::Browse:
      _hint.stringValue = @"Everything in this folder, biggest first. Expand a folder to see what's inside. "
                          @"The colour shows how recently something inside was used.";
      break;
    case Mode::Reclaim: {
      _hint.stringValue = @"Folders that tools generate and can regenerate: npm packages, build output, caches, "
                          @"Xcode and Docker data. Deleting them frees space without losing any of your own files.";
      if (r && !r->dirs.empty()) {
        std::vector<int32_t> ids;
        collectUnits(*r, 0, ids, [](const DirNode& d) { return categoryReclaimable(d.category); });
        for (int32_t i : ids) [flat addObject:[self itemForDir:i parent:nil]];
      }
      break;
    }
    case Mode::Forgotten: {
      _hint.stringValue = @"Folders of at least 50 MB where almost nothing has been opened or changed in over 6 months. "
                          @"Have a look — if you don't recognise it, you probably don't need it.";
      if (r && !r->dirs.empty()) {
        std::vector<int32_t> ids;
        collectForgotten(*r, 0, ids, 50ull << 20);
        for (int32_t i : ids) [flat addObject:[self itemForDir:i parent:nil]];
      }
      break;
    }
    case Mode::BigFiles: {
      _hint.stringValue = @"Single files of 100 MB or more that you haven't opened or changed in over 6 months: "
                          @"old downloads, installers, videos, disk images.";
      if (r)
        for (const FileRec& f : r->bigFiles)
          if (bucketFor(f.lastUsed, r->now) >= STALE)
            [flat addObject:[self itemForFile:f.path size:f.size lastUsed:f.lastUsed never:f.neverOpened parent:nil]];
      break;
    }
    case Mode::Apps:
      _hint.stringValue = @"Apps in /Applications and ~/Applications by when you last launched them "
                          @"(from Spotlight). Apps you never open are safe to remove; you can reinstall them later.";
      [flat addObjectsFromArray:_appItems ?: @[]];
      break;
  }
  [self sortItems:flat];
  _flat = flat;
  [_outline reloadData];
  [_outline deselectAll:nil];
  [self selectionChanged];
}

- (void)modeChanged:(NSSegmentedControl*)s { [self showMode:(Mode)s.selectedSegment]; }
- (void)modeFromMenu:(NSMenuItem*)mi { [self showMode:(Mode)mi.tag]; }

// ───── outline data source ─────

- (NSInteger)outlineView:(NSOutlineView*)ov numberOfChildrenOfItem:(Item*)item {
  if (!item) return (NSInteger)[self topItems].count;
  [self loadChildren:item];
  return (NSInteger)item.children.count;
}
- (id)outlineView:(NSOutlineView*)ov child:(NSInteger)i ofItem:(Item*)item {
  if (!item) return [self topItems][(NSUInteger)i];
  [self loadChildren:item];
  return item.children[(NSUInteger)i];
}
- (BOOL)outlineView:(NSOutlineView*)ov isItemExpandable:(Item*)item {
  return item.isDir && !item.isApp && (item.files > 0 || (item.dirId >= 0 && !_model.result->dirs[item.dirId].children.empty()));
}

- (void)outlineView:(NSOutlineView*)ov sortDescriptorsDidChange:(NSArray<NSSortDescriptor*>*)old {
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

- (NSView*)outlineView:(NSOutlineView*)ov viewForTableColumn:(NSTableColumn*)col item:(Item*)item {
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

- (void)outlineViewSelectionDidChange:(NSNotification*)n { [self selectionChanged]; }

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
    [self refreshHeaderTotals];
    [self refreshSummary];
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

- (void)refreshHeaderTotals {
  if (!_model.result || _model.result->dirs.empty()) return;
  const DirNode& root = _model.result->dirs[0];
  _subtitle.stringValue = [NSString stringWithFormat:@"%@  ·  %@  ·  %@", ns_str(_scanPath).stringByAbbreviatingWithTildeInPath,
                                                     fmtBytes(root.size), fmtCount(root.files, @"file")];
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
