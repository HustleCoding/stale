// Renders the DMG window background ("drag Stale to Applications") as a 1x + 2x
// PNG pair. The Makefile joins them into a HiDPI TIFF that Finder shows sharp on
// Retina displays.
//   mkdmgbg <out-1x.png> <out-2x.png>
//
// Geometry matches app/dmg.sh: a 660×400 pt window, the app icon centred at
// (165, 200) and the Applications alias at (495, 200), both 128 pt.
#import <Cocoa/Cocoa.h>

static const CGFloat kW = 660, kH = 400;
static const CGFloat kIconY = 200, kAppX = 165, kAppsX = 495, kIcon = 128;

static NSColor* hex(uint32_t v, CGFloat a = 1) {
  return [NSColor colorWithSRGBRed:((v >> 16) & 0xff) / 255.0
                             green:((v >> 8) & 0xff) / 255.0
                              blue:(v & 0xff) / 255.0
                             alpha:a];
}

// Finder's coordinate origin is top-left; AppKit's is bottom-left.
static CGFloat fy(CGFloat yFromTop) { return kH - yFromTop; }

static void draw(CGFloat scale) {
  NSAffineTransform* t = [NSAffineTransform transform];
  [t scaleBy:scale];
  [t concat];
  NSRect all = NSMakeRect(0, 0, kW, kH);

  NSGradient* bg = [[NSGradient alloc] initWithColorsAndLocations:hex(0xF7F8FC), 0.0, hex(0xEEF0F7), 1.0, nil];
  [bg drawInRect:all angle:-90];

  // Faint indigo bloom behind the app icon, rose behind Applications: mirrors the app's palette.
  NSGradient* g1 = [[NSGradient alloc] initWithStartingColor:hex(0x6366F1, 0.16) endingColor:hex(0x6366F1, 0)];
  [g1 drawFromCenter:NSMakePoint(kAppX, fy(kIconY)) radius:0 toCenter:NSMakePoint(kAppX, fy(kIconY)) radius:170 options:0];
  NSGradient* g2 = [[NSGradient alloc] initWithStartingColor:hex(0x22C55E, 0.10) endingColor:hex(0x22C55E, 0)];
  [g2 drawFromCenter:NSMakePoint(kAppsX, fy(kIconY)) radius:0 toCenter:NSMakePoint(kAppsX, fy(kIconY)) radius:170 options:0];

  // Dashed landing pads under both icons.
  const CGFloat pads[] = {kAppX, kAppsX};
  for (CGFloat cx : pads) {
    NSRect pad = NSMakeRect(cx - kIcon / 2 - 14, fy(kIconY) - kIcon / 2 - 14, kIcon + 28, kIcon + 28);
    NSBezierPath* p = [NSBezierPath bezierPathWithRoundedRect:pad xRadius:30 yRadius:30];
    p.lineWidth = 1.5;
    CGFloat dash[] = {6, 6};
    [p setLineDash:dash count:2 phase:0];
    [hex(0x1E1B4B, 0.16) setStroke];
    [p stroke];
  }

  // Arrow.
  CGFloat ax0 = kAppX + kIcon / 2 + 44, ax1 = kAppsX - kIcon / 2 - 44, ay = fy(kIconY);
  NSBezierPath* shaft = [NSBezierPath bezierPath];
  shaft.lineWidth = 6;
  shaft.lineCapStyle = NSLineCapStyleRound;
  [shaft moveToPoint:NSMakePoint(ax0, ay)];
  [shaft lineToPoint:NSMakePoint(ax1 - 14, ay)];
  [hex(0x1E1B4B, 0.55) setStroke];
  [shaft stroke];
  NSBezierPath* head = [NSBezierPath bezierPath];
  [head moveToPoint:NSMakePoint(ax1, ay)];
  [head lineToPoint:NSMakePoint(ax1 - 26, ay + 16)];
  [head lineToPoint:NSMakePoint(ax1 - 26, ay - 16)];
  [head closePath];
  [hex(0x1E1B4B, 0.55) setFill];
  [head fill];

  // Headline + hint.
  NSMutableParagraphStyle* ps = [NSMutableParagraphStyle new];
  ps.alignment = NSTextAlignmentCenter;
  NSFont* title = [NSFont systemFontOfSize:22 weight:NSFontWeightSemibold];
  NSFontDescriptor* fd = [title.fontDescriptor fontDescriptorWithDesign:NSFontDescriptorSystemDesignRounded];
  title = [NSFont fontWithDescriptor:fd size:22] ?: title;
  [@"Drag Stale to Applications" drawInRect:NSMakeRect(0, fy(72), kW, 30)
                             withAttributes:@{
                               NSFontAttributeName : title,
                               NSForegroundColorAttributeName : hex(0x111827),
                               NSParagraphStyleAttributeName : ps
                             }];
  [@"Then eject this disk and open Stale from Launchpad or Applications."
      drawInRect:NSMakeRect(0, fy(96), kW, 20)
      withAttributes:@{
        NSFontAttributeName : [NSFont systemFontOfSize:13 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName : hex(0x6B7280),
        NSParagraphStyleAttributeName : ps
      }];

  // Footer.
  [@"Stale finds what you never use and lets you move it to the Trash — nothing is deleted for good."
      drawInRect:NSMakeRect(0, fy(372), kW, 18)
      withAttributes:@{
        NSFontAttributeName : [NSFont systemFontOfSize:11 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName : hex(0x9CA3AF),
        NSParagraphStyleAttributeName : ps
      }];
}

static BOOL writePNG(CGFloat scale, NSString* path) {
  NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                  pixelsWide:(NSInteger)(kW * scale)
                                                                  pixelsHigh:(NSInteger)(kH * scale)
                                                               bitsPerSample:8
                                                             samplesPerPixel:4
                                                                    hasAlpha:YES
                                                                    isPlanar:NO
                                                              colorSpaceName:NSCalibratedRGBColorSpace
                                                                 bytesPerRow:0
                                                                bitsPerPixel:0];
  rep.size = NSMakeSize(kW, kH);  // sets the DPI so Finder treats the 2x image as 660×400 pt
  NSGraphicsContext* ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
  [NSGraphicsContext saveGraphicsState];
  NSGraphicsContext.currentContext = ctx;
  ctx.shouldAntialias = YES;
  draw(scale);
  [ctx flushGraphics];
  [NSGraphicsContext restoreGraphicsState];
  NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
  return [png writeToFile:path atomically:YES];
}

int main(int argc, const char* argv[]) {
  @autoreleasepool {
    if (argc < 3) {
      fprintf(stderr, "usage: mkdmgbg <out-1x.png> <out-2x.png>\n");
      return 2;
    }
    if (!writePNG(1, [NSString stringWithUTF8String:argv[1]]) ||
        !writePNG(2, [NSString stringWithUTF8String:argv[2]])) {
      fprintf(stderr, "mkdmgbg: failed writing background\n");
      return 1;
    }
  }
  return 0;
}
