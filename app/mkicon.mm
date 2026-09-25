// Renders the Stale app icon (a macOS squircle with recency bars) into an .iconset
// directory. Run by the Makefile; the .icns is then produced with iconutil.
//   mkicon <out.iconset>
#import <Cocoa/Cocoa.h>

static NSColor* rgb(int r, int g, int b) {
  return [NSColor colorWithSRGBRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:1];
}

static void draw(CGFloat s) {
  // Apple's template: the squircle fills 824/1024 of the canvas.
  CGFloat inset = s * (100.0 / 1024.0);
  NSRect tile = NSMakeRect(inset, inset, s - 2 * inset, s - 2 * inset);
  CGFloat radius = tile.size.width * 0.2237;

  NSShadow* shadow = [NSShadow new];
  shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.35];
  shadow.shadowBlurRadius = s * 0.02;
  shadow.shadowOffset = NSMakeSize(0, -s * 0.01);

  NSBezierPath* squircle = [NSBezierPath bezierPathWithRoundedRect:tile xRadius:radius yRadius:radius];
  [NSGraphicsContext saveGraphicsState];
  [shadow set];
  [rgb(20, 27, 45) setFill];
  [squircle fill];
  [NSGraphicsContext restoreGraphicsState];

  NSGradient* bg = [[NSGradient alloc] initWithStartingColor:rgb(44, 56, 88) endingColor:rgb(17, 23, 40)];
  [bg drawInBezierPath:squircle angle:-90];

  // Soft top highlight.
  [NSGraphicsContext saveGraphicsState];
  [squircle addClip];
  NSGradient* gloss = [[NSGradient alloc]
      initWithColorsAndLocations:[NSColor colorWithWhite:1 alpha:0.0], 0.0,
                                 [NSColor colorWithWhite:1 alpha:0.0], 0.45,
                                 [NSColor colorWithWhite:1 alpha:0.12], 1.0, nil];
  [gloss drawInRect:tile angle:90];
  [NSGraphicsContext restoreGraphicsState];

  // Four recency bars: longest and greenest on top, shortest and reddest at the bottom.
  struct Bar { CGFloat width; NSColor* color; };
  Bar bars[] = {
      {0.62, rgb(52, 199, 89)},
      {0.50, rgb(90, 200, 250)},
      {0.38, rgb(255, 159, 10)},
      {0.26, rgb(255, 69, 58)},
  };
  CGFloat barH = tile.size.height * 0.105;
  CGFloat gap = tile.size.height * 0.055;
  CGFloat total = 4 * barH + 3 * gap;
  CGFloat x = tile.origin.x + tile.size.width * 0.19;
  CGFloat y = NSMidY(tile) + total / 2 - barH;
  NSShadow* barShadow = [NSShadow new];
  barShadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.30];
  barShadow.shadowBlurRadius = s * 0.012;
  barShadow.shadowOffset = NSMakeSize(0, -s * 0.006);
  for (const Bar& b : bars) {
    NSRect r = NSMakeRect(x, y, tile.size.width * b.width, barH);
    NSBezierPath* p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:barH / 2 yRadius:barH / 2];
    [NSGraphicsContext saveGraphicsState];
    [barShadow set];
    [b.color setFill];
    [p fill];
    [NSGraphicsContext restoreGraphicsState];
    NSGradient* sheen = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithWhite:1 alpha:0.22]
                                                      endingColor:[NSColor colorWithWhite:1 alpha:0.0]];
    [sheen drawInBezierPath:p angle:-90];
    y -= barH + gap;
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
      fprintf(stderr, "usage: mkicon <out.iconset>\n");
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
  }
  return 0;
}
