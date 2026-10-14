import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Interim app icon: two cream pages on terracotta, rendered opaque (no alpha) as App Store icons require.
// AppKit cannot create a graphics context for a 3-channel bitmap, which is why an earlier version wrote
// an all-black PNG; CoreGraphics with `noneSkipLast` draws into an opaque RGB buffer directly.
let side = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard
  let context = CGContext(
    data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else { fatalError("Cannot create the icon context.") }
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
  CGColor(colorSpace: space, components: [r, g, b, a])!
}
context.setFillColor(color(0.78, 0.30, 0.15))
context.fill(CGRect(x: 0, y: 0, width: side, height: side))
context.setFillColor(color(1, 0.96, 0.88))
for x in [220, 528] {
  context.addPath(
    CGPath(
      roundedRect: CGRect(x: x, y: 270, width: 276, height: 480), cornerWidth: 32,
      cornerHeight: 32, transform: nil))
  context.fillPath()
}
context.setStrokeColor(color(0.78, 0.30, 0.15, 0.4))
context.setLineWidth(16)
context.setLineCap(.round)
for y in [400, 470, 540, 610] {
  for x in [266, 574] {
    context.move(to: CGPoint(x: x, y: y))
    context.addLine(to: CGPoint(x: x + 180, y: y))
  }
}
context.strokePath()
guard let image = context.makeImage(),
  let destination = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, UTType.png.identifier as CFString, 1,
    nil)
else { fatalError("Cannot write the icon.") }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write the icon.") }
