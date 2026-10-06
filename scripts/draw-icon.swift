import AppKit
let size=NSSize(width:1024,height:1024)
let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1024,pixelsHigh:1024,bitsPerSample:8,samplesPerPixel:3,hasAlpha:false,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
NSColor(calibratedRed:0.78,green:0.30,blue:0.15,alpha:1).setFill()
NSBezierPath(rect:NSRect(origin:.zero,size:size)).fill()
NSColor(calibratedRed:1,green:0.96,blue:0.88,alpha:1).setFill()
for x in [220,528] {NSBezierPath(roundedRect:NSRect(x:x,y:270,width:276,height:480),xRadius:32,yRadius:32).fill()}
NSColor(calibratedRed:0.78,green:0.30,blue:0.15,alpha:0.4).setStroke()
for y in [400,470,540,610] {for x in [266,574]{let p=NSBezierPath();p.lineWidth=16;p.move(to:NSPoint(x:x,y:y));p.line(to:NSPoint(x:x+180,y:y));p.stroke()}}
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
