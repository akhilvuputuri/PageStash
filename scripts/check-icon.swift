import CoreGraphics
import Foundation
import ImageIO

// Fails when an app icon is not a 1024×1024 opaque image with real artwork (at least a few distinct
// colours). Guards against regressions such as the solid-black icon shipped before 0.3.2.
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else { fatalError("Cannot read \(url.path)") }
precondition(image.width == 1024 && image.height == 1024, "Icon must be 1024×1024")
let alpha = image.alphaInfo
precondition(
  [.none, .noneSkipLast, .noneSkipFirst].contains(alpha), "Icon must not have an alpha channel")
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(
  data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4, space: space,
  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
let pixels = context.data!.bindMemory(to: UInt32.self, capacity: 64 * 64)
let colours = Set((0..<64 * 64).map { pixels[$0] & 0x00ff_ffff })
precondition(colours.count >= 3, "Icon has \(colours.count) colour(s); it looks blank")
print("Icon OK: 1024×1024, opaque, \(colours.count) distinct colours in a 64×64 sample")
