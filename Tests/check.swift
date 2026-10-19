// Prints one fact about an output file, for run.sh to compare. Usage: check <fact> <file> [file2]
//   size        WxH in pixels
//   depth       bits per component
//   alpha       yes/no: the file has an alpha channel
//   transparent yes/no: some pixel isn't opaque
//   space       colour space name
//   bytes       file size
//   upright     yes/no: top is red and bottom is blue (the rotated.jpg fixture, displayed upright)
//   same        yes/no: the two files decode to identical pixels
//   pdf         page count, then the first page's width×height in points
//   pdfmatch    yes/no: the PDF's first page shows the image (file2) upright, judged by the
//               colours just around the centre of each quadrant
import CoreGraphics
import Foundation
import ImageIO
import PDFKit

let args = CommandLine.arguments
let url = URL(fileURLWithPath: args[2])

func image(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { print("unreadable"); exit(1) }
    return image
}

func rgba(_ image: CGImage) -> [UInt8] {
    let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                        bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self),
                                     count: image.width * image.height * 4))
}

func yesNo(_ b: Bool) -> String { b ? "yes" : "no" }

switch args[1] {
case "size":
    let i = image(url); print("\(i.width)x\(i.height)")
case "depth":
    print(image(url).bitsPerComponent)
case "alpha":
    switch image(url).alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast: print("no")
    default: print("yes")
    }
case "transparent":
    let i = image(url), px = rgba(i)
    print(yesNo(stride(from: 3, to: px.count, by: 4).contains { px[$0] < 255 }))
case "space":
    print(image(url).colorSpace?.name.map { $0 as String } ?? "none")
case "upright":
    let i = image(url), px = rgba(i)
    let top = px[0..<3], bottom = px[(i.width * (i.height - 1)) * 4..<(i.width * (i.height - 1)) * 4 + 3]
    print(yesNo(top[top.startIndex] > 200 && top[top.startIndex + 2] < 60
                && bottom[bottom.startIndex] < 60 && bottom[bottom.startIndex + 2] > 200))
case "same":
    print(yesNo(rgba(image(url)) == rgba(image(URL(fileURLWithPath: args[3])))))
case "pdfmatch":
    guard let page = PDFDocument(url: url)?.page(at: 0)?.pageRef else { print("unreadable"); exit(1) }
    let box = page.getBoxRect(.mediaBox)
    let ctx = CGContext(data: nil, width: Int(box.width), height: Int(box.height), bitsPerComponent: 8,
                        bytesPerRow: Int(box.width) * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.drawPDFPage(page)
    let rendered = ctx.makeImage()!
    // The image as ImageIO shows it upright.
    let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[3]) as CFURL, nil)!
    let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 400] as CFDictionary)!
    func colour(_ image: CGImage, _ px: [UInt8], _ x: Int, _ y: Int) -> [Int] {
        let i = (y * image.width + x) * 4
        return [Int(px[i]), Int(px[i + 1]), Int(px[i + 2])]
    }
    let a = rgba(rendered), b = rgba(upright)
    let (cx, cy) = (rendered.width / 2, rendered.height / 2), (ux, uy) = (upright.width / 2, upright.height / 2)
    let matches = [(-1, -1), (1, -1), (-1, 1), (1, 1)].allSatisfy { dx, dy in
        let p = colour(rendered, a, cx + dx * 20, cy + dy * 20)
        let q = colour(upright, b, ux + dx * upright.width / 4, uy + dy * upright.height / 4)
        return zip(p, q).allSatisfy { abs($0 - $1) < 60 }
    }
    print(yesNo(matches))
case "bytes":
    print((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
case "pdf":
    guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { print("unreadable"); exit(1) }
    let box = page.bounds(for: .mediaBox)
    print("\(doc.pageCount) \(Int(box.width.rounded()))x\(Int(box.height.rounded()))")
default:
    print("unknown fact \(args[1])"); exit(2)
}
