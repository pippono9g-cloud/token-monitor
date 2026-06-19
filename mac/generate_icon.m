// Compile: clang -fobjc-arc generate_icon.m -framework Cocoa -o generate_icon
// Run:     ./generate_icon output.png
#import <Cocoa/Cocoa.h>

int main(int argc, char *argv[]) {
  @autoreleasepool {
    NSString *outPath = argc > 1 ? @(argv[1]) : @"icon_1024.png";
    CGFloat size = 1024;

    NSImage *icon = [[NSImage alloc] initWithSize:NSMakeSize(size, size)];
    [icon lockFocus];

    // Dark rounded background
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, 0, size, size)
                                                       xRadius:size * 0.22
                                                       yRadius:size * 0.22];
    [[NSColor colorWithRed:0.10 green:0.10 blue:0.12 alpha:1.0] setFill];
    [bg fill];

    // Claude logo: 4 elongated petals at 0°, 45°, 90°, 135°
    CGFloat cx = size / 2;
    CGFloat cy = size / 2;
    CGFloat petalLen = size * 0.30;
    CGFloat petalW = size * 0.07;
    [[NSColor whiteColor] setFill];
    for (int i = 0; i < 4; i++) {
      CGFloat angle = i * M_PI / 4.0;
      NSBezierPath *petal = [NSBezierPath bezierPath];
      [petal moveToPoint:NSMakePoint(0, petalLen)];
      [petal curveToPoint:NSMakePoint(0, -petalLen)
           controlPoint1:NSMakePoint(petalW, petalLen * 0.4)
           controlPoint2:NSMakePoint(petalW, -petalLen * 0.4)];
      [petal curveToPoint:NSMakePoint(0, petalLen)
           controlPoint1:NSMakePoint(-petalW, -petalLen * 0.4)
           controlPoint2:NSMakePoint(-petalW, petalLen * 0.4)];
      [petal closePath];
      NSAffineTransform *t = [NSAffineTransform transform];
      [t translateXBy:cx yBy:cy];
      [t rotateByRadians:angle];
      NSBezierPath *final = [t transformBezierPath:petal];
      [final fill];
    }

    [icon unlockFocus];

    NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:[icon TIFFRepresentation]];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [png writeToFile:outPath atomically:YES];
    NSLog(@"Icon written to %@", outPath);
  }
  return 0;
}
