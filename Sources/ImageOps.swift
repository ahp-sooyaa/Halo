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
}

enum ImageOpsError: LocalizedError {
    case unreadable(String)
    case writeFailed(String)
    case noImages

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "Can't read \(name)"
        case .writeFailed(let name): return "Can't write \(name)"
        case .noImages: return "No images"
        }
    }
}

enum ImageOps {
    static let writableTypes: Set<String> = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    static func canWrite(_ type: UTType) -> Bool { writableTypes.contains(type.identifier) }

    /// Output formats offered on the Convert wheel, limited to what this Mac's ImageIO can encode.
    static let formats: [(name: String, type: UTType)] = {
        let all: [(String, UTType?)] = [
            ("PNG", .png), ("JPG", .jpeg), ("HEIC", .heic), ("WebP", .webP),
            ("AVIF", UTType("public.avif")), ("TIFF", .tiff), ("GIF", .gif), ("BMP", .bmp),
        ]
        return all.compactMap { name, type in
            guard let type, canWrite(type) else { return nil }
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

    static func run(_ action: ImageAction, on urls: [URL]) throws -> [URL] {
        let images = urls.filter(isImage)
        guard !images.isEmpty else { throw ImageOpsError.noImages }
        if action == .pdf { return [try makePDF(images)] }
        return try images.map { try run(action, on: $0) }
    }

    static func run(_ action: ImageAction, on url: URL) throws -> URL {
        let sourceType = type(of: url) ?? .png
        let sameType = canWrite(sourceType) ? sourceType : .png

        switch action {
        case .convert(let target):
            let (image, props) = try load(url, oriented: false)
            return try save(image, props: props, from: url, as: target)

        case .scale(let factor):
            let (image, props) = try load(url, oriented: true)
            let resized = scaled(image, by: factor)
            return try save(resized, props: props, from: url, as: sameType, suffix: "\(Int(factor * 100))%")

        case .fit(let maxSide):
            let (image, props) = try load(url, oriented: true)
            let factor = min(1, Double(maxSide) / Double(max(image.width, image.height)))
            return try save(scaled(image, by: factor), props: props, from: url, as: sameType, suffix: "\(maxSide)px")

        case .compress:
            let lossy: [UTType] = [.jpeg, .heic, .webP, UTType("public.avif")].compactMap { $0 }.filter(canWrite)
            let target = lossy.contains(sourceType) ? sourceType : .jpeg
            let (image, props) = try load(url, oriented: false)
            return try save(image, props: props, from: url, as: target,
                            quality: target == sourceType ? 0.6 : 0.7, suffix: "compressed")

        case .strip:
            let (image, _) = try load(url, oriented: true)
            return try save(image, props: [:], from: url, as: sameType, suffix: "clean")

        case .pdf:
            return try makePDF([url])
        }
    }

    // MARK: - Loading

    /// Loads the first frame. `oriented` bakes the EXIF rotation into the pixels (needed before
    /// resizing or dropping metadata) and resets the orientation tag to match.
    private static func load(_ url: URL, oriented: Bool) throws -> (CGImage, [CFString: Any]) {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 {
            var props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            if oriented {
                let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
                let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
                ]
                if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                    props[kCGImagePropertyOrientation] = 1
                    if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                        tiff[kCGImagePropertyTIFFOrientation] = 1
                        props[kCGImagePropertyTIFFDictionary] = tiff
                    }
                    props.removeValue(forKey: kCGImagePropertyPixelWidth)
                    props.removeValue(forKey: kCGImagePropertyPixelHeight)
                    return (image, props)
                }
            } else if let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
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

    private static func rgbSpace(for image: CGImage) -> CGColorSpace {
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

    // MARK: - Writing

    private static func save(_ image: CGImage, props: [CFString: Any], from source: URL, as type: UTType,
                             quality: Double? = nil, suffix: String? = nil) throws -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        let name = suffix.map { "\(base) \($0)" } ?? base
        let ext = type == .jpeg ? "jpg" : (type.preferredFilenameExtension ?? "img")
        let out = uniqueURL(in: source.deletingLastPathComponent(), name: name, ext: ext)

        let pixels = (type == .jpeg || type == .bmp) ? flattened(image) : image
        var options = props
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }

        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else {
            throw ImageOpsError.writeFailed(out.lastPathComponent)
        }
        CGImageDestinationAddImage(dest, pixels, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: out)
            throw ImageOpsError.writeFailed(out.lastPathComponent)
        }
        return out
    }

    private static func makePDF(_ urls: [URL]) throws -> URL {
        let doc = PDFDocument()
        for url in urls {
            guard let image = NSImage(contentsOf: url), let page = PDFPage(image: image) else {
                throw ImageOpsError.unreadable(url.lastPathComponent)
            }
            doc.insert(page, at: doc.pageCount)
        }
        let first = urls[0]
        let out = uniqueURL(in: first.deletingLastPathComponent(),
                            name: first.deletingPathExtension().lastPathComponent, ext: "pdf")
        guard doc.write(to: out) else { throw ImageOpsError.writeFailed(out.lastPathComponent) }
        return out
    }

    /// "photo.png", then "photo 2.png", "photo 3.png"… never overwrites anything.
    static func uniqueURL(in dir: URL, name: String, ext: String) -> URL {
        var candidate = dir.appendingPathComponent(name).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(name) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }
}
