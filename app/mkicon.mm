// Renders the Stale app icon into an .iconset directory. Run by the Makefile; the
// .icns is then produced with iconutil.
//   mkicon <out.iconset> [preview.png]
//
// Design: a stack of glass cards on an indigo squircle: a fresh mint card with a
// clock in front of a recent blue one and a faded, dusty one at the back.
#import <Cocoa/Cocoa.h>

static NSColor* hex(uint32_t v, CGFloat a = 1) {
  return [NSColor colorWithSRGBRed:((v >> 16) & 0xff) / 255.0
                             green:((v >> 8) & 0xff) / 255.0
                              blue:(v & 0xff) / 255.0
                             alpha:a];
}

static NSShadow* makeShadow(CGFloat alpha, CGFloat blur, CGFloat dy) {
  NSShadow* sh = [NSShadow new];
  sh.shadowColor = [NSColor colorWithWhite:0 alpha:alpha];
  sh.shadowBlurRadius = blur;
  sh.shadowOffset = NSMakeSize(0, dy);
  return sh;
}

static void radialGlow(NSRect tile, CGFloat fx, CGFloat fy, CGFloat r, NSColor* color) {
  NSPoint p = NSMakePoint(NSMinX(tile) + tile.size.width * fx, NSMinY(tile) + tile.size.height * fy);
  NSGradient* g = [[NSGradient alloc] initWithStartingColor:color endingColor:[color colorWithAlphaComponent:0]];
  [g drawFromCenter:p radius:0 toCenter:p radius:tile.size.width * r options:0];
}

static void draw(CGFloat s) {
  // Apple's template: the squircle fills 824/1024 of the canvas.
  CGFloat inset = s * (100.0 / 1024.0);
  NSRect tile = NSMakeRect(inset, inset, s - 2 * inset, s - 2 * inset);
  CGFloat W = tile.size.width;
  CGFloat radius = W * 0.2237;
  NSBezierPath* squircle = [NSBezierPath bezierPathWithRoundedRect:tile xRadius:radius yRadius:radius];

  [NSGraphicsContext saveGraphicsState];
  [makeShadow(0.30, s * 0.022, -s * 0.012) set];
  [hex(0x1E1B4B) setFill];
  [squircle fill];
  [NSGraphicsContext restoreGraphicsState];

  [NSGraphicsContext saveGraphicsState];
  [squircle addClip];
  NSGradient* bg = [[NSGradient alloc] initWithColorsAndLocations:hex(0x5B54F0), 0.0, hex(0x3730A3), 0.5,
                                                                  hex(0x1A1745), 1.0, nil];
  [bg drawInRect:tile angle:-90];
  radialGlow(tile, 0.20, 0.88, 0.70, hex(0xA5B4FC, 0.45));
  radialGlow(tile, 0.85, 0.10, 0.60, hex(0x2DD4BF, 0.20));
  NSBezierPath* rim = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(tile, s * 0.004, s * 0.004)
                                                      xRadius:radius - s * 0.004
                                                      yRadius:radius - s * 0.004];
  rim.lineWidth = s * 0.006;
  [[NSColor colorWithWhite:1 alpha:0.18] setStroke];
  [rim stroke];
  [NSGraphicsContext restoreGraphicsState];

  // Three cards, back to front: the old, dusty layer; the recent blue one; the fresh
  // card you are using now, with a clock.
  struct Card { CGFloat dy, scale, alpha; uint32_t top, bottom; };
  const Card cards[] = {
      {0.215, 0.76, 0.55, 0xA8A3C7, 0x6E6A96},
      {0.110, 0.88, 0.85, 0x93C5FD, 0x4F7FF0},
      {-0.030, 1.00, 1.00, 0x7CF0C5, 0x14B8A6},
  };
  NSPoint c = NSMakePoint(NSMidX(tile), NSMidY(tile) - W * 0.035);
  for (const Card& k : cards) {
    CGFloat cw = W * 0.62 * k.scale, ch = W * 0.42 * k.scale, cr = W * 0.075 * k.scale;
    NSRect r = NSMakeRect(c.x - cw / 2, c.y - ch / 2 + W * k.dy, cw, ch);
    NSBezierPath* p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:cr yRadius:cr];

    [NSGraphicsContext saveGraphicsState];
    [makeShadow(0.38, s * 0.035, -s * 0.016) set];
    [hex(k.bottom) setFill];
    [p fill];
    [NSGraphicsContext restoreGraphicsState];

    [NSGraphicsContext saveGraphicsState];
    [p addClip];
    NSGradient* g = [[NSGradient alloc] initWithStartingColor:hex(k.top) endingColor:hex(k.bottom)];
    [g drawInRect:r angle:-90];
    // Frosted veil on the back cards so they recede.
    [[NSColor colorWithSRGBRed:0.16 green:0.14 blue:0.40 alpha:1 - k.alpha] setFill];
    NSRectFillUsingOperation(r, NSCompositingOperationSourceOver);
    // Glass sheen across the top of every card.
    NSGradient* sheen = [[NSGradient alloc] initWithColorsAndLocations:[NSColor colorWithWhite:1 alpha:0.38], 0.0,
                                                                       [NSColor colorWithWhite:1 alpha:0.06], 0.45,
                                                                       [NSColor colorWithWhite:1 alpha:0], 1.0, nil];
    [sheen drawInRect:r angle:-90];
    [NSGraphicsContext restoreGraphicsState];

    NSBezierPath* edge = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, s * 0.002, s * 0.002)
                                                         xRadius:cr
                                                         yRadius:cr];
    edge.lineWidth = s * 0.004;
    [[NSColor colorWithWhite:1 alpha:0.45 * k.alpha] setStroke];
    [edge stroke];

    if (k.alpha < 1) continue;
    CGFloat d = ch * 0.50;
    NSPoint cc = NSMakePoint(NSMinX(r) + ch * 0.44, NSMidY(r));
    [NSGraphicsContext saveGraphicsState];
    [makeShadow(0.18, s * 0.012, -s * 0.004) set];
    [[NSColor colorWithWhite:1 alpha:0.97] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(cc.x - d / 2, cc.y - d / 2, d, d)] fill];
    [NSGraphicsContext restoreGraphicsState];
    NSBezierPath* hands = [NSBezierPath bezierPath];
    [hands moveToPoint:NSMakePoint(cc.x, cc.y + d * 0.27)];
    [hands lineToPoint:cc];
    [hands lineToPoint:NSMakePoint(cc.x + d * 0.20, cc.y - d * 0.10)];
    hands.lineWidth = d * 0.10;
    hands.lineCapStyle = NSLineCapStyleRound;
    hands.lineJoinStyle = NSLineJoinStyleRound;
    [hex(0x0F766E) setStroke];
    [hands stroke];

    CGFloat barH = d * 0.20, barX = cc.x + d * 0.78;
    CGFloat lengths[] = {NSMaxX(r) - barX - ch * 0.22, (NSMaxX(r) - barX - ch * 0.22) * 0.62};
    CGFloat ys[] = {NSMidY(r) + d * 0.06, NSMidY(r) - d * 0.30};
    CGFloat alphas[] = {0.95, 0.60};
    for (int i = 0; i < 2; i++) {
      NSRect bar = NSMakeRect(barX, ys[i], lengths[i], barH);
      [[NSColor colorWithWhite:1 alpha:alphas[i]] setFill];
      [[NSBezierPath bezierPathWithRoundedRect:bar xRadius:barH / 2 yRadius:barH / 2] fill];
    }
  }
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
