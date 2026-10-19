import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum ImageAction: Equatable {
    case convert(UTType)
    case pdf
    case scale(Double)
    case fit(Int)
    case compress
    case strip
    case trim
    case crop(CGRect)    // normalised, origin top-left
    case cropInteractive // opens the crop window; handled by WheelController
}

enum ImageOpsError: LocalizedError {
    case unreadable(String)
    case writeFailed(String)
    case noImages
    case nothingToTrim
    case webPTooLarge
    case noResizeNeeded(Int)
    case alreadyCompressed
    case unsupported

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "Can't read \(name)"
        case .writeFailed(let name): return "Can't write \(name)"
        case .noImages: return "No images"
        case .nothingToTrim: return "No border to trim"
        case .webPTooLarge: return "WebP max is \(WebP.maxDimension)px"
        case .noResizeNeeded(let side): return "Already \(side)px or smaller"
        case .alreadyCompressed: return "Already well compressed"
        case .unsupported: return "Not supported"
        }
    }
}

enum ImageOps {
    static let writableTypes: Set<String> = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    static func canWrite(_ type: UTType) -> Bool { writableTypes.contains(type.identifier) }

    /// ImageIO encoders plus WebP through libwebp.
    static func canEncode(_ type: UTType) -> Bool { type == .webP || canWrite(type) }

    /// Output formats offered on the Convert wheel, limited to what this Mac's ImageIO can encode.
    static let formats: [(name: String, type: UTType)] = {
        let all: [(String, UTType?)] = [
            ("PNG", .png), ("JPG", .jpeg), ("HEIC", .heic), ("WebP", .webP),
            ("AVIF", UTType("public.avif")), ("TIFF", .tiff), ("GIF", .gif), ("BMP", .bmp),
        ]
        return all.compactMap { name, type in
            guard let type, canEncode(type) else { return nil }
            return (name, type)
        }
    }()

    static func type(of url: URL) -> UTType? {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
    }

    static func isImage(_ url: URL) -> Bool {
        type(of: url)?.conforms(to: .image) ?? false
    }

    // MARK: - Running actions

    /// `outputFolder` nil saves next to each original.
    static func run(_ action: ImageAction, on urls: [URL], outputFolder: URL? = nil) throws -> [URL] {
        let images = urls.filter(isImage)
        guard !images.isEmpty else { throw ImageOpsError.noImages }
        if action == .pdf { return [try makePDF(images, outputFolder: outputFolder)] }
        return try images.map { try run(action, on: $0, outputFolder: outputFolder) }
    }

    static func run(_ action: ImageAction, on url: URL, outputFolder: URL? = nil) throws -> URL {
        let sourceType = type(of: url) ?? .png
        let sameType = canEncode(sourceType) ? sourceType : .png
        func save(_ image: CGImage, props: [CFString: Any], as type: UTType,
                  quality: Double? = nil, suffix: String? = nil) throws -> URL {
            try ImageOps.save(image, props: props, from: url, as: type, quality: quality, suffix: suffix,
                              outputFolder: outputFolder)
        }

        switch action {
        case .convert(let target):
            let (image, props) = try load(url)
            return try save(image, props: props, as: target)

        case .scale(let factor):
            let (image, props) = try load(url)
            let resized = scaled(image, by: factor)
            return try save(resized, props: props, as: sameType, suffix: "\(Int(factor * 100))%")

        case .fit(let maxSide):
            let (image, props) = try load(url)
            let factor = Double(maxSide) / Double(max(image.width, image.height))
            guard factor < 1 else { throw ImageOpsError.noResizeNeeded(maxSide) }
            return try save(scaled(image, by: factor), props: props, as: sameType, suffix: "\(maxSide)px")

        case .compress:
            let (image, props) = try load(url)
            let lossy: [UTType] = [.jpeg, .heic, .webP, UTType("public.avif")].compactMap { $0 }.filter(canEncode)
            // WebP rather than JPEG when there's real transparency, so it isn't flattened onto white.
            let target = lossy.contains(sourceType) ? sourceType : hasTransparency(image) ? .webP : .jpeg
            let out = try save(image, props: props, as: target,
                               quality: target == sourceType ? 0.6 : 0.7, suffix: "compressed")
            let before = fileSize(url), after = fileSize(out)
            if before > 0, after >= before {
                try? FileManager.default.removeItem(at: out)
                throw ImageOpsError.alreadyCompressed
            }
            return out

        case .strip:
            let (image, _) = try load(url)
            return try save(image, props: [:], as: sameType, suffix: "clean")

        case .trim:
            let (image, props) = try load(url)
            guard let box = trimRect(image),
                  box.size != CGSize(width: image.width, height: image.height),
                  let trimmed = image.cropping(to: box) else { throw ImageOpsError.nothingToTrim }
            return try save(trimmed, props: props, as: sameType, suffix: "trimmed")

        case .crop(let normalized):
            let (image, props) = try load(url)
            let W = CGFloat(image.width), H = CGFloat(image.height)
            let box = CGRect(x: normalized.minX * W, y: normalized.minY * H,
                             width: normalized.width * W, height: normalized.height * H)
                .integral.intersection(CGRect(x: 0, y: 0, width: W, height: H))
            guard !box.isEmpty, let cropped = image.cropping(to: box) else { throw ImageOpsError.unsupported }
            return try save(cropped, props: props, as: sameType, suffix: "cropped")

        case .pdf:
            return try makePDF([url], outputFolder: outputFolder)

        case .cropInteractive:
            throw ImageOpsError.unsupported
        }
    }

    // MARK: - Loading

    /// Loads the first frame with the EXIF rotation baked into the pixels, and resets the
    /// orientation tag to match. Many writers (WebP, AVIF, GIF, BMP) drop the tag, so the
    /// pixels have to be upright.
    static func load(_ url: URL) throws -> (CGImage, [CFString: Any]) {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 {
            var props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            var side = max(props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0)
            if side == 0, let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                // No size in the properties: decode once to find it, rather than ask for a 1px thumbnail.
                side = max(image.width, image.height)
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
            ]
            if side > 0, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                props[kCGImagePropertyOrientation] = 1
                if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                    tiff[kCGImagePropertyTIFFOrientation] = 1
                    props[kCGImagePropertyTIFFDictionary] = tiff
                }
                props.removeValue(forKey: kCGImagePropertyPixelWidth)
                props.removeValue(forKey: kCGImagePropertyPixelHeight)
                return (image, props)
            }
        }
        // Fallback for formats ImageIO can't decode (e.g. SVG): rasterise through NSImage at 2x.
        if let ns = NSImage(contentsOf: url) {
            var rect = CGRect(origin: .zero, size: CGSize(width: ns.size.width * 2, height: ns.size.height * 2))
            if let image = ns.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                return (image, [:])
            }
        }
        throw ImageOpsError.unreadable(url.lastPathComponent)
    }

    // MARK: - Pixel helpers

    static func rgbSpace(for image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb { return space }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    private static func scaled(_ image: CGImage, by factor: Double) -> CGImage {
        guard factor < 1 else { return image }
        let w = max(1, Int((Double(image.width) * factor).rounded()))
        let h = max(1, Int((Double(image.height) * factor).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: rgbSpace(for: image),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    /// JPEG has no alpha; without this transparent areas turn black.
    private static func flattened(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: break
        }
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: rgbSpace(for: image),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(.white)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    /// 8-bit sRGB RGBA copy of the image, for reading pixels. Rows are top first.
    private static func rgbaContext(_ image: CGImage) -> CGContext? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              ctx.data != nil else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx
    }

    /// True when some pixel isn't fully opaque (an alpha channel alone doesn't count).
    static func hasTransparency(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        guard let ctx = rgbaContext(image), let data = ctx.data else { return true }
        let px = data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<image.height {
            let row = y * ctx.bytesPerRow
            for x in 0..<image.width where px[row + x * 4 + 3] < 255 { return true }
        }
        return false
    }

    // MARK: - Writing

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// The chosen folder, or the source's own; ~/Downloads when that one isn't writable.
    static func outputDir(for source: URL, preferred: URL?) -> URL {
        let dir = preferred ?? source.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: dir.path) { return dir }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? dir
    }

    private static func save(_ image: CGImage, props: [CFString: Any], from source: URL, as type: UTType,
                             quality: Double?, suffix: String?, outputFolder: URL?) throws -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        let name = suffix.map { "\(base) \($0)" } ?? base
        let ext = type == .jpeg ? "jpg" : (type.preferredFilenameExtension ?? "img")
        let out = try reserveURL(in: outputDir(for: source, preferred: outputFolder), name: name, ext: ext)
        do {
            try write(image, props: props, as: type, from: ImageOps.type(of: source), quality: quality, to: out)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return out
    }

    private static func write(_ image: CGImage, props: [CFString: Any], as type: UTType, from sourceType: UTType?,
                              quality: Double?, to out: URL) throws {
        if type == .webP && !canWrite(.webP) {
            guard max(image.width, image.height) <= WebP.maxDimension else { throw ImageOpsError.webPTooLarge }
            // Lossless when converting from a lossless format, so screenshots and graphics stay sharp.
            let lossless = quality == nil && [.png, .tiff, .gif, .bmp].contains { sourceType == $0 }
            guard let data = WebP.encode(image, quality: quality ?? 0.85, lossless: lossless) else {
                throw ImageOpsError.writeFailed(out.lastPathComponent)
            }
            do { try data.write(to: out) } catch { throw ImageOpsError.writeFailed(out.lastPathComponent) }
            return
        }

        let pixels = (type == .jpeg || type == .bmp) ? flattened(image) : image
        var options = props
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }

        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else {
            throw ImageOpsError.writeFailed(out.lastPathComponent)
        }
        CGImageDestinationAddImage(dest, pixels, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ImageOpsError.writeFailed(out.lastPathComponent) }
    }

    /// Bounding box (top-left origin, pixels) of everything that differs from the top-left
    /// pixel's colour, i.e. the image without its uniform or transparent border.
    static func trimRect(_ image: CGImage) -> CGRect? {
        let w = image.width, h = image.height
        guard let ctx = rgbaContext(image), let data = ctx.data else { return nil }
        let px = data.assumingMemoryBound(to: UInt8.self)
        let stride = ctx.bytesPerRow
        let ref = (px[0], px[1], px[2], px[3])
        let tolerance = 12

        func differs(_ x: Int, _ y: Int) -> Bool {
            let i = y * stride + x * 4
            return abs(Int(px[i]) - Int(ref.0)) > tolerance || abs(Int(px[i + 1]) - Int(ref.1)) > tolerance
                || abs(Int(px[i + 2]) - Int(ref.2)) > tolerance || abs(Int(px[i + 3]) - Int(ref.3)) > tolerance
        }
        func rowDiffers(_ y: Int) -> Bool { (0..<w).contains { differs($0, y) } }

        guard let top = (0..<h).first(where: rowDiffers),
              let bottom = (0..<h).reversed().first(where: rowDiffers) else { return nil }
        func columnDiffers(_ x: Int) -> Bool { (top...bottom).contains { differs(x, $0) } }
        let left = (0..<w).first(where: columnDiffers) ?? 0
        let right = (0..<w).reversed().first(where: columnDiffers) ?? w - 1
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }

    private static func makePDF(_ urls: [URL], outputFolder: URL?) throws -> URL {
        let doc = PDFDocument()
        for url in urls {
            guard let image = NSImage(contentsOf: url), let page = PDFPage(image: image) else {
                throw ImageOpsError.unreadable(url.lastPathComponent)
            }
            doc.insert(page, at: doc.pageCount)
        }
        let first = urls[0]
        let out = try reserveURL(in: outputDir(for: first, preferred: outputFolder),
                                 name: first.deletingPathExtension().lastPathComponent, ext: "pdf")
        guard doc.write(to: out) else {
            try? FileManager.default.removeItem(at: out)
            throw ImageOpsError.writeFailed(out.lastPathComponent)
        }
        return out
    }

    /// Claims "photo.png", then "photo 2.png", "photo 3.png"… by creating an empty file with
    /// O_EXCL, so files converted in parallel can't pick the same name. Never overwrites anything.
    static func reserveURL(in dir: URL, name: String, ext: String) throws -> URL {
        for n in 1...10_000 {
            let candidate = dir.appendingPathComponent(n == 1 ? name : "\(name) \(n)").appendingPathExtension(ext)
            let fd = open(candidate.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if fd >= 0 {
                close(fd)
                return candidate
            }
            if errno != EEXIST { break }
        }
        throw ImageOpsError.writeFailed("\(name).\(ext)")
    }
}
