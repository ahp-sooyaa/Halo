import Accelerate
import CoreGraphics
import Foundation

/// WebP encoding through libwebp, since ImageIO can read WebP but not write it.
enum WebP {
    static let maxDimension = 16383

    /// `quality` is 0…1. Returns nil if libwebp rejects the image.
    static func encode(_ image: CGImage, quality: Double) -> Data? {
        let w = image.width, h = image.height
        guard w <= maxDimension, h <= maxDimension,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // CoreGraphics only draws premultiplied alpha; libwebp wants straight RGBA.
        var buffer = vImage_Buffer(data: pixels, height: vImagePixelCount(h), width: vImagePixelCount(w),
                                   rowBytes: ctx.bytesPerRow)
        vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags))

        var output: UnsafeMutablePointer<UInt8>?
        let size = WebPEncodeRGBA(pixels.assumingMemoryBound(to: UInt8.self), Int32(w), Int32(h),
                                  Int32(ctx.bytesPerRow), Float(quality * 100), &output)
        defer { WebPFree(output) }
        guard size > 0, let output else { return nil }
        return Data(bytes: output, count: size)
    }
}
