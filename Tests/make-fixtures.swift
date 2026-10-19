// Writes the test images into the directory given as the only argument. Used by run.sh.
import CoreGraphics
import Foundation
import ImageIO

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let p3 = CGColorSpace(name: CGColorSpace.displayP3)!

func context(_ w: Int, _ h: Int, space: CGColorSpace = sRGB, alpha: Bool = true, bits: Int = 8) -> CGContext {
    var info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    if bits == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
    return CGContext(data: nil, width: w, height: h, bitsPerComponent: bits, bytesPerRow: 0, space: space,
                     bitmapInfo: info)!
}

func write(_ ctx: CGContext, _ name: String, _ type: String, _ props: [CFString: Any] = [:]) {
    let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL, type as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fatalError("couldn't write \(name)") }
}

func noise(_ ctx: CGContext, cell: Int) {
    var rng = SystemRandomNumberGenerator()
    for y in stride(from: 0, to: ctx.height, by: cell) {
        for x in stride(from: 0, to: ctx.width, by: cell) {
            ctx.setFillColor(CGColor(red: .random(in: 0...1, using: &rng), green: .random(in: 0...1, using: &rng),
                                     blue: 0.5, alpha: 1))
            ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
        }
    }
}

// 400×200 stored sideways: left half red, right half blue, tagged orientation 6 (rotate 90° CW).
// Upright it's 200×400 with red on top.
var c = context(400, 200)
c.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
c.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); c.fill(CGRect(x: 200, y: 0, width: 200, height: 200))
write(c, "rotated.jpg", "public.jpeg", [kCGImagePropertyOrientation: 6])

// Four coloured quadrants, saved with each EXIF orientation 1…8, for checking PDF pages.
c = context(400, 200)
for (i, colour) in [(0, (1.0, 0.0, 0.0)), (1, (0.0, 1.0, 0.0)), (2, (0.0, 0.0, 1.0)), (3, (1.0, 1.0, 0.0))] {
    c.setFillColor(CGColor(red: colour.0, green: colour.1, blue: colour.2, alpha: 1))
    c.fill(CGRect(x: (i % 2) * 200, y: (i / 2) * 100, width: 200, height: 100))
}
for orientation in 1...8 {
    write(c, "quad-\(orientation).jpg", "public.jpeg", [kCGImagePropertyOrientation: orientation])
}

// Fine vertical lines, so lossy encoding would change pixels.
c = context(300, 200)
for x in stride(from: 0, to: 300, by: 2) {
    c.setFillColor(CGColor(gray: CGFloat(x % 7) / 7, alpha: 1)); c.fill(CGRect(x: x, y: 0, width: 1, height: 200))
}
write(c, "opaque.png", "public.png")

c = context(300, 200)
c.setFillColor(CGColor(red: 0, green: 0.6, blue: 0.2, alpha: 1)); c.fillEllipse(in: CGRect(x: 50, y: 20, width: 200, height: 160))
write(c, "transparent.png", "public.png")

c = context(200, 200, space: p3)
c.setFillColor(CGColor(colorSpace: p3, components: [1, 0, 0, 1])!); c.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
write(c, "p3.png", "public.png")

c = context(400, 300, alpha: false)
c.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
write(c, "noalpha.png", "public.png")

c = context(400, 300, alpha: false, bits: 16)
c.drawLinearGradient(CGGradient(colorsSpace: sRGB, colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 1, alpha: 1)] as CFArray,
                                locations: nil)!, start: .zero, end: CGPoint(x: 400, y: 0), options: [])
write(c, "deep16.png", "public.png")

c = context(800, 600)
noise(c, cell: 4)
write(c, "lowq.jpg", "public.jpeg", [kCGImageDestinationLossyCompressionQuality: 0.3])
write(c, "small.jpg", "public.jpeg", [kCGImageDestinationLossyCompressionQuality: 0.9])

c = context(3000, 2000)
noise(c, cell: 50)
write(c, "big72.jpg", "public.jpeg", [kCGImagePropertyDPIWidth: 72, kCGImagePropertyDPIHeight: 72])

// Big and incompressible, so writing a PNG of it takes a few seconds (the crash test kills it mid-write).
c = context(6000, 6000, alpha: false)
var seed: UInt32 = 1
let words = c.data!.assumingMemoryBound(to: UInt32.self)
for i in 0..<(c.bytesPerRow / 4 * c.height) { seed = seed &* 1664525 &+ 1013904223; words[i] = seed }
write(c, "huge.tiff", "public.tiff")

try Data("not an image".utf8).write(to: dir.appendingPathComponent("broken.png"))
