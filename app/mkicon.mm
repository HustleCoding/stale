// Renders the Stale app icon into an .iconset directory. Run by the Makefile; the
// .icns is then produced with iconutil.
//   mkicon <out.iconset> [preview.png]
//
// Design: a "sediment core" — a glossy disk whose five strata are the recency
// buckets (fresh mint on top, sinking through teal, blue and amber to a thin rose
// layer at the bottom), set into a deep indigo squircle.
#import <Cocoa/Cocoa.h>

static NSColor* hex(uint32_t v, CGFloat a = 1) {
  return [NSColor colorWithSRGBRed:((v >> 16) & 0xff) / 255.0
                             green:((v >> 8) & 0xff) / 255.0
                              blue:(v & 0xff) / 255.0
                             alpha:a];
}

static void draw(CGFloat s) {
  // Apple's template: the squircle fills 824/1024 of the canvas.
  CGFloat inset = s * (100.0 / 1024.0);
  NSRect tile = NSMakeRect(inset, inset, s - 2 * inset, s - 2 * inset);
  CGFloat radius = tile.size.width * 0.2237;
  NSBezierPath* squircle = [NSBezierPath bezierPathWithRoundedRect:tile xRadius:radius yRadius:radius];

  // Drop shadow + base fill.
  NSShadow* shadow = [NSShadow new];
  shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.30];
  shadow.shadowBlurRadius = s * 0.022;
  shadow.shadowOffset = NSMakeSize(0, -s * 0.012);
  [NSGraphicsContext saveGraphicsState];
  [shadow set];
  [hex(0x12142E) setFill];
  [squircle fill];
  [NSGraphicsContext restoreGraphicsState];

  [NSGraphicsContext saveGraphicsState];
  [squircle addClip];
  NSGradient* bg = [[NSGradient alloc] initWithColorsAndLocations:hex(0x3A3F8F), 0.0, hex(0x1E2158), 0.55,
                                                                  hex(0x0B0D22), 1.0, nil];
  [bg drawInRect:tile angle:-90];

  // Cool radial glow in the upper left, warm one bottom right: gives the slab depth.
  NSGradient* glow1 = [[NSGradient alloc] initWithStartingColor:hex(0x7C83FF, 0.55) endingColor:hex(0x7C83FF, 0)];
  [glow1 drawFromCenter:NSMakePoint(NSMinX(tile) + tile.size.width * 0.22, NSMaxY(tile) - tile.size.height * 0.18)
                 radius:0
               toCenter:NSMakePoint(NSMinX(tile) + tile.size.width * 0.22, NSMaxY(tile) - tile.size.height * 0.18)
                 radius:tile.size.width * 0.75
                options:0];
  NSGradient* glow2 = [[NSGradient alloc] initWithStartingColor:hex(0xF43F5E, 0.22) endingColor:hex(0xF43F5E, 0)];
  [glow2 drawFromCenter:NSMakePoint(NSMaxX(tile) - tile.size.width * 0.15, NSMinY(tile) + tile.size.height * 0.12)
                 radius:0
               toCenter:NSMakePoint(NSMaxX(tile) - tile.size.width * 0.15, NSMinY(tile) + tile.size.height * 0.12)
                 radius:tile.size.width * 0.6
                options:0];

  // Hairline rim so the slab reads as an object on light and dark docks.
  NSBezierPath* rim = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(tile, s * 0.004, s * 0.004)
                                                      xRadius:radius - s * 0.004
                                                      yRadius:radius - s * 0.004];
  rim.lineWidth = s * 0.006;
  [[NSColor colorWithWhite:1 alpha:0.14] setStroke];
  [rim stroke];
  [NSGraphicsContext restoreGraphicsState];

  // The disk.
  CGFloat R = tile.size.width * 0.36;
  NSPoint c = NSMakePoint(NSMidX(tile), NSMidY(tile) + tile.size.height * 0.01);
  NSRect diskRect = NSMakeRect(c.x - R, c.y - R, 2 * R, 2 * R);
  NSBezierPath* disk = [NSBezierPath bezierPathWithOvalInRect:diskRect];

  NSShadow* diskShadow = [NSShadow new];
  diskShadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.45];
  diskShadow.shadowBlurRadius = s * 0.035;
  diskShadow.shadowOffset = NSMakeSize(0, -s * 0.02);
  [NSGraphicsContext saveGraphicsState];
  [diskShadow set];
  [hex(0x0B0D22) setFill];
  [disk fill];
  [NSGraphicsContext restoreGraphicsState];

  // Strata: thick fresh layers on top, thinning towards the old rose at the bottom.
  struct Stratum { CGFloat share; uint32_t top, bottom; };
  const Stratum strata[] = {
      {0.30, 0x6EE7B7, 0x22C55E},  // this week
      {0.25, 0x5EEAD4, 0x14B8A6},  // this month
      {0.20, 0x93C5FD, 0x3B82F6},  // 6 months
      {0.15, 0xFCD34D, 0xF59E0B},  // a year
      {0.10, 0xFDA4AF, 0xF43F5E},  // older
  };
  [NSGraphicsContext saveGraphicsState];
  [disk addClip];
  CGFloat y = NSMaxY(diskRect);
  for (const Stratum& st : strata) {
    CGFloat h = diskRect.size.height * st.share;
    NSRect r = NSMakeRect(diskRect.origin.x, y - h, diskRect.size.width, h);
    NSGradient* g = [[NSGradient alloc] initWithStartingColor:hex(st.top) endingColor:hex(st.bottom)];
    [g drawInRect:r angle:-90];
    // Thin dark seam between layers.
    NSRect seam = NSMakeRect(r.origin.x, r.origin.y - s * 0.002, r.size.width, s * 0.004);
    [[NSColor colorWithWhite:0 alpha:0.22] setFill];
    NSRectFillUsingOperation(seam, NSCompositingOperationSourceOver);
    y -= h;
  }

  // Curvature: darken the disk edges and the bottom, lighten the top.
  NSGradient* shade = [[NSGradient alloc] initWithColorsAndLocations:[NSColor colorWithWhite:0 alpha:0], 0.0,
                                                                     [NSColor colorWithWhite:0 alpha:0], 0.62,
                                                                     [NSColor colorWithWhite:0 alpha:0.42], 1.0, nil];
  [shade drawFromCenter:c radius:0 toCenter:c radius:R options:NSGradientDrawsAfterEndingLocation];
  NSGradient* bottomShade = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithWhite:0 alpha:0.30]
                                                          endingColor:[NSColor colorWithWhite:0 alpha:0]];
  [bottomShade drawInRect:NSMakeRect(diskRect.origin.x, diskRect.origin.y, diskRect.size.width, R * 0.7) angle:90];

  // Gloss: a soft elliptical highlight across the upper half.
  NSRect glossRect = NSMakeRect(c.x - R * 0.86, c.y + R * 0.06, R * 1.72, R * 0.86);
  NSBezierPath* gloss = [NSBezierPath bezierPathWithOvalInRect:glossRect];
  NSGradient* glossG = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithWhite:1 alpha:0.34]
                                                     endingColor:[NSColor colorWithWhite:1 alpha:0.02]];
  [glossG drawInBezierPath:gloss angle:90];
  [NSGraphicsContext restoreGraphicsState];

  // Bevel ring on the disk edge.
  NSBezierPath* edge = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(diskRect, s * 0.003, s * 0.003)];
  edge.lineWidth = s * 0.006;
  [[NSColor colorWithWhite:1 alpha:0.30] setStroke];
  [edge stroke];

  // A small "now" tick at 12 o'clock — a nod to the clock in the app.
  CGFloat tickW = R * 0.11, tickH = R * 0.26;
  NSRect tick = NSMakeRect(c.x - tickW / 2, c.y + R - tickH - R * 0.10, tickW, tickH);
  NSBezierPath* tickP = [NSBezierPath bezierPathWithRoundedRect:tick xRadius:tickW / 2 yRadius:tickW / 2];
  [NSGraphicsContext saveGraphicsState];
  NSShadow* ts = [NSShadow new];
  ts.shadowColor = [NSColor colorWithWhite:0 alpha:0.35];
  ts.shadowBlurRadius = s * 0.008;
  ts.shadowOffset = NSMakeSize(0, -s * 0.003);
  [ts set];
  [[NSColor colorWithWhite:1 alpha:0.92] setFill];
  [tickP fill];
  [NSGraphicsContext restoreGraphicsState];
}

static BOOL writePNG(CGFloat px, NSString* path) {
  NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                  pixelsWide:(NSInteger)px
                                                                  pixelsHigh:(NSInteger)px
                                                               bitsPerSample:8
                                                             samplesPerPixel:4
                                                                    hasAlpha:YES
                                                                    isPlanar:NO
                                                              colorSpaceName:NSCalibratedRGBColorSpace
                                                                 bytesPerRow:0
                                                                bitsPerPixel:0];
  NSGraphicsContext* ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
  [NSGraphicsContext saveGraphicsState];
  NSGraphicsContext.currentContext = ctx;
  ctx.shouldAntialias = YES;
  ctx.imageInterpolation = NSImageInterpolationHigh;
  draw(px);
  [ctx flushGraphics];
  [NSGraphicsContext restoreGraphicsState];
  NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
  return [png writeToFile:path atomically:YES];
}

int main(int argc, const char* argv[]) {
  @autoreleasepool {
    if (argc < 2) {
      fprintf(stderr, "usage: mkicon <out.iconset> [preview.png]\n");
      return 2;
    }
    NSString* dir = [NSString stringWithUTF8String:argv[1]];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    int sizes[] = {16, 32, 128, 256, 512};
    for (int base : sizes) {
      NSString* p1 = [dir stringByAppendingFormat:@"/icon_%dx%d.png", base, base];
      NSString* p2 = [dir stringByAppendingFormat:@"/icon_%dx%d@2x.png", base, base];
      if (!writePNG(base, p1) || !writePNG(base * 2, p2)) {
        fprintf(stderr, "mkicon: failed writing %s\n", dir.UTF8String);
        return 1;
      }
    }
    if (argc > 2 && !writePNG(1024, [NSString stringWithUTF8String:argv[2]])) return 1;
  }
  return 0;
}
