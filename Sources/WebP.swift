import Accelerate
import CoreGraphics
import Foundation

/// WebP encoding through libwebp, since ImageIO can read WebP but not write it.
enum WebP {
    static let maxDimension = 16383

    /// `quality` is 0…1 and ignored when `lossless`. Returns nil if libwebp rejects the image.
    /// Pixels stay in the image's own colour space, with its ICC profile embedded when it isn't sRGB.
    static func encode(_ image: CGImage, quality: Double, lossless: Bool = false) -> Data? {
        let w = image.width, h = image.height
        guard w <= maxDimension, h <= maxDimension else { return nil }

        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        var space = ImageOps.rgbSpace(for: image)
        var icc = space.name == CGColorSpace.sRGB ? nil : space.copyICCData() as Data?
        func context(_ space: CGColorSpace) -> CGContext? {
            CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        // No profile to embed, or a space 8-bit contexts can't use (e.g. extended range): use sRGB.
        if icc == nil || context(space) == nil {
            space = sRGB
            icc = nil
        }
        guard let ctx = context(space), let pixels = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // CoreGraphics only draws premultiplied alpha; libwebp wants straight RGBA.
        var buffer = vImage_Buffer(data: pixels, height: vImagePixelCount(h), width: vImagePixelCount(w),
                                   rowBytes: ctx.bytesPerRow)
        vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags))

        var output: UnsafeMutablePointer<UInt8>?
        let rgba = pixels.assumingMemoryBound(to: UInt8.self)
        let size = lossless
            ? WebPEncodeLosslessRGBA(rgba, Int32(w), Int32(h), Int32(ctx.bytesPerRow), &output)
            : WebPEncodeRGBA(rgba, Int32(w), Int32(h), Int32(ctx.bytesPerRow), Float(quality * 100), &output)
        defer { WebPFree(output) }
        guard size > 0, let output else { return nil }
        guard let icc else { return Data(bytes: output, count: size) }
        return withICC(UnsafePointer(output), size: size, icc: icc)
    }

    /// Wraps a WebP bitstream in a container with an ICCP chunk.
    private static func withICC(_ bitstream: UnsafePointer<UInt8>, size: Int, icc: Data) -> Data? {
        guard let mux = WebPMuxNew() else { return nil }
        defer { WebPMuxDelete(mux) }
        var image = WebPData(bytes: bitstream, size: size)
        guard WebPMuxSetImage(mux, &image, 0) == WEBP_MUX_OK else { return nil }
        let set = icc.withUnsafeBytes { raw -> WebPMuxError in
            var chunk = WebPData(bytes: raw.bindMemory(to: UInt8.self).baseAddress, size: raw.count)
            return WebPMuxSetChunk(mux, "ICCP", &chunk, 1) // copied, so `icc` can go away
        }
        guard set == WEBP_MUX_OK else { return nil }
        var assembled = WebPData()
        guard WebPMuxAssemble(mux, &assembled) == WEBP_MUX_OK else { return nil }
        defer { WebPDataClear(&assembled) }
        return Data(bytes: assembled.bytes, count: assembled.size)
    }
}
