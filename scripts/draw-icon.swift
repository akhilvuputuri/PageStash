import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// PageStash icon: two pages tucked into a sleeve. Usage:
//   swift scripts/draw-icon.swift <output-dir>
// Writes the flattened, opaque App Store icon (AppIcon.png), dark and tinted variants, the
// transparent foreground layers for Icon Composer, and the sign-in mark (BrandMark.png).
// CoreGraphics draws straight into an RGB(A) buffer; an earlier AppKit version produced an
// all-black icon because AppKit cannot draw into a 3-channel bitmap.
let side = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
  CGColor(
    colorSpace: space,
    components: [
      CGFloat(hex >> 16 & 0xff) / 255, CGFloat(hex >> 8 & 0xff) / 255, CGFloat(hex & 0xff) / 255,
      alpha,
    ])!
}
struct Palette {
  let background: UInt32?
  let page: UInt32
  let line: UInt32
  let sleeve: UInt32
  let sleeveEdge: UInt32
}
let light = Palette(
  background: 0xC74D26, page: 0xFFF5E1, line: 0xE3B79A, sleeve: 0x8E2F14, sleeveEdge: 0xA83C1C)
let dark = Palette(
  background: 0x1E1512, page: 0xF4E6CF, line: 0xC9A88F, sleeve: 0xC74D26, sleeveEdge: 0xE0763F)
// Tinted icons keep only luminance, so the shapes are separated by lightness alone.
let tinted = Palette(
  background: 0x000000, page: 0xFFFFFF, line: 0x9A9A9A, sleeve: 0x5C5C5C, sleeveEdge: 0x7A7A7A)

func context(opaque: Bool) -> CGContext {
  CGContext(
    data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast)
      .rawValue)!
}
func page(_ c: CGContext, _ p: Palette, center: CGPoint, angle: CGFloat) {
  c.saveGState()
  c.translateBy(x: center.x, y: center.y)
  c.rotate(by: angle * .pi / 180)
  let rect = CGRect(x: -170, y: -230, width: 340, height: 460)
  c.addPath(CGPath(roundedRect: rect, cornerWidth: 34, cornerHeight: 34, transform: nil))
  c.setFillColor(color(p.page))
  c.fillPath()
  c.setStrokeColor(color(p.line))
  c.setLineWidth(18)
  c.setLineCap(.round)
  for (i, y) in [150, 92, 34].enumerated() {
    c.move(to: CGPoint(x: -110, y: CGFloat(y)))
    c.addLine(to: CGPoint(x: i == 2 ? 50 : 110, y: CGFloat(y)))
  }
  c.strokePath()
  c.restoreGState()
}
func pages(_ c: CGContext, _ p: Palette) {
  page(c, p, center: CGPoint(x: 452, y: 560), angle: 9)
  page(c, p, center: CGPoint(x: 572, y: 590), angle: -6)
}
func sleeve(_ c: CGContext, _ p: Palette) {
  // A pocket across the lower half; its top edge has a shallow dip like a sleeve opening.
  let path = CGMutablePath()
  path.move(to: CGPoint(x: 232, y: 540))
  path.addQuadCurve(to: CGPoint(x: 792, y: 540), control: CGPoint(x: 512, y: 470))
  path.addLine(to: CGPoint(x: 792, y: 262))
  path.addArc(tangent1End: CGPoint(x: 792, y: 212), tangent2End: CGPoint(x: 742, y: 212), radius: 50)
  path.addLine(to: CGPoint(x: 282, y: 212))
  path.addArc(tangent1End: CGPoint(x: 232, y: 212), tangent2End: CGPoint(x: 232, y: 262), radius: 50)
  path.closeSubpath()
  c.addPath(path)
  c.setFillColor(color(p.sleeve))
  c.fillPath()
  c.setStrokeColor(color(p.sleeveEdge))
  c.setLineWidth(14)
  c.move(to: CGPoint(x: 248, y: 532))
  c.addQuadCurve(to: CGPoint(x: 776, y: 532), control: CGPoint(x: 512, y: 466))
  c.strokePath()
}
func write(_ c: CGContext, _ name: String) {
  let destination = CGImageDestinationCreateWithURL(
    out.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, c.makeImage()!, nil)
  precondition(CGImageDestinationFinalize(destination), "Cannot write \(name)")
}
func icon(_ p: Palette, _ name: String) {
  let c = context(opaque: true)
  c.setFillColor(color(p.background!))
  c.fill(CGRect(x: 0, y: 0, width: side, height: side))
  pages(c, p)
  sleeve(c, p)
  write(c, name)
}
icon(light, "AppIcon.png")
icon(dark, "AppIcon-Dark.png")
icon(tinted, "AppIcon-Tinted.png")
let back = context(opaque: false)
pages(back, light)
write(back, "Layer-Pages.png")
let front = context(opaque: false)
sleeve(front, light)
write(front, "Layer-Sleeve.png")
// The in-app mark: the icon as a rounded tile, so the cream pages stay visible on white screens.
let mark = context(opaque: false)
mark.addPath(
  CGPath(
    roundedRect: CGRect(x: 0, y: 0, width: side, height: side), cornerWidth: 230,
    cornerHeight: 230, transform: nil))
mark.clip()
mark.setFillColor(color(light.background!))
mark.fill(CGRect(x: 0, y: 0, width: side, height: side))
pages(mark, light)
sleeve(mark, light)
write(mark, "BrandMark.png")
