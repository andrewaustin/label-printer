import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A file converted into TSPL bytes ready to send to the printer.
struct LabelJob {
    let data: Data
    let pageCount: Int
    /// Black-and-white preview of the first label, nil for raw TSPL files.
    let preview: CGImage?
}

enum LabelRendererError: LocalizedError {
    case unreadable
    case unsupportedType
    case emptyDocument

    var errorDescription: String? {
        switch self {
        case .unreadable: "Couldn't read the file"
        case .unsupportedType: "Unsupported file type (use PDF, an image, or .tspl)"
        case .emptyDocument: "The document has no pages"
        }
    }
}

/// Renders PDFs and images onto a 4x6 in label at 203 dpi and encodes them as TSPL BITMAP commands.
enum LabelRenderer {
    static let widthDots = 812   // 4 in * 203 dpi
    static let heightDots = 1218 // 6 in * 203 dpi
    static let bytesPerRow = (widthDots + 7) / 8

    /// TSPL BITMAP treats a 0 bit as a printed (black) dot. Flip this if labels come out inverted.
    static let invertBits = false

    static let rawExtensions: Set<String> = ["tspl", "prn", "txt"]

    static let allowedTypes: [UTType] = {
        var types: [UTType] = [.pdf, .image, .plainText]
        if let tspl = UTType(filenameExtension: "tspl") { types.append(tspl) }
        if let prn = UTType(filenameExtension: "prn") { types.append(prn) }
        return types
    }()

    static func makeJob(from url: URL) throws -> LabelJob {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())

        if type?.conforms(to: .pdf) == true {
            return try pdfJob(url: url)
        }
        if type?.conforms(to: .image) == true {
            return try imageJob(url: url)
        }
        if rawExtensions.contains(url.pathExtension.lowercased()) || type?.conforms(to: .plainText) == true {
            return try rawJob(url: url)
        }
        throw LabelRendererError.unsupportedType
    }

    // MARK: - Sources

    private static func rawJob(url: URL) throws -> LabelJob {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw LabelRendererError.unreadable
        }
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .joined(separator: "\r\n")
        let payload = normalized.hasSuffix("\r\n") ? normalized : normalized + "\r\n"
        return LabelJob(data: Data(payload.utf8), pageCount: 1, preview: nil)
    }

    private static func pdfJob(url: URL) throws -> LabelJob {
        guard let document = CGPDFDocument(url as CFURL) else {
            throw LabelRendererError.unreadable
        }
        guard document.numberOfPages > 0 else { throw LabelRendererError.emptyDocument }

        var data = Data()
        var preview: CGImage?
        for index in 1...document.numberOfPages {
            guard let page = document.page(at: index) else { continue }
            let gray = renderPDFPage(page)
            let mono = threshold(gray)
            if preview == nil { preview = previewImage(mono) }
            data.append(tsplLabel(mono))
        }
        return LabelJob(data: data, pageCount: document.numberOfPages, preview: preview)
    }

    private static func imageJob(url: URL) throws -> LabelJob {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true, // apply EXIF orientation
                  kCGImageSourceThumbnailMaxPixelSize: 4096,
              ] as CFDictionary) else {
            throw LabelRendererError.unreadable
        }

        let size = CGSize(width: image.width, height: image.height)
        let gray = renderFitted(contentSize: size) { context in
            context.draw(image, in: CGRect(origin: .zero, size: size))
        }
        let mono = dither(gray)
        return LabelJob(data: tsplLabel(mono), pageCount: 1, preview: previewImage(mono))
    }

    // MARK: - Rendering

    private static func renderPDFPage(_ page: CGPDFPage) -> [UInt8] {
        let box = page.getBoxRect(.cropBox)
        // A portrait page already fits the label, so print it as-is even if the PDF asks for it
        // to be displayed rotated (common with shipping labels). Otherwise honor /Rotate.
        let rotation = box.width > box.height ? ((Int(page.rotationAngle) % 360) + 360) % 360 : 0
        let size = (rotation == 90 || rotation == 270)
            ? CGSize(width: box.height, height: box.width)
            : box.size

        return renderFitted(contentSize: size) { context in
            // Map the unrotated page into the displayed (rotated) content space.
            switch rotation {
            case 90:
                context.translateBy(x: 0, y: size.height)
                context.rotate(by: -.pi / 2)
            case 180:
                context.translateBy(x: size.width, y: size.height)
                context.rotate(by: .pi)
            case 270:
                context.translateBy(x: size.width, y: 0)
                context.rotate(by: .pi / 2)
            default:
                break
            }
            context.translateBy(x: -box.minX, y: -box.minY)
            context.clip(to: box)
            context.drawPDFPage(page)
        }
    }

    /// Draws content of the given size onto a white label, rotated to portrait if needed and
    /// scaled to fit. Returns 8-bit grayscale pixels, top row first.
    private static func renderFitted(contentSize: CGSize, draw: (CGContext) -> Void) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: widthDots * heightDots)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: widthDots,
                height: heightDots,
                bitsPerComponent: 8,
                bytesPerRow: widthDots,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }

            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: widthDots, height: heightDots))
            context.interpolationQuality = .high

            guard contentSize.width > 0, contentSize.height > 0 else { return }
            let rotate = contentSize.width > contentSize.height
            let fitWidth = rotate ? contentSize.height : contentSize.width
            let fitHeight = rotate ? contentSize.width : contentSize.height
            let scale = min(CGFloat(widthDots) / fitWidth, CGFloat(heightDots) / fitHeight)

            context.translateBy(x: CGFloat(widthDots) / 2, y: CGFloat(heightDots) / 2)
            if rotate { context.rotate(by: -.pi / 2) }
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -contentSize.width / 2, y: -contentSize.height / 2)
            draw(context)
        }
        return pixels
    }

    // MARK: - 1-bit conversion (true = black)

    private static func threshold(_ gray: [UInt8]) -> [Bool] {
        gray.map { $0 < 128 }
    }

    private static func dither(_ gray: [UInt8]) -> [Bool] {
        var values = gray.map { Float($0) }
        var result = [Bool](repeating: false, count: values.count)
        let w = widthDots, h = heightDots

        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let old = values[i]
                let black = old < 128
                result[i] = black
                let error = old - (black ? 0 : 255)
                if x + 1 < w { values[i + 1] += error * 7 / 16 }
                if y + 1 < h {
                    if x > 0 { values[i + w - 1] += error * 3 / 16 }
                    values[i + w] += error * 5 / 16
                    if x + 1 < w { values[i + w + 1] += error * 1 / 16 }
                }
            }
        }
        return result
    }

    // MARK: - Output

    private static func tsplLabel(_ mono: [Bool]) -> Data {
        var bitmap = Data(count: bytesPerRow * heightDots)
        bitmap.withUnsafeMutableBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            for y in 0..<heightDots {
                for byteIndex in 0..<bytesPerRow {
                    var byte: UInt8 = 0
                    for bit in 0..<8 {
                        let x = byteIndex * 8 + bit
                        let black = x < widthDots && mono[y * widthDots + x]
                        if black == invertBits { byte |= 0x80 >> UInt8(bit) }
                    }
                    bytes[y * bytesPerRow + byteIndex] = byte
                }
            }
        }

        var data = Data()
        let header = [
            "SIZE 101.6 mm,152.4 mm",
            "GAP 2 mm,0",
            "DENSITY 8",
            "SPEED 5",
            "DIRECTION 0",
            "REFERENCE 0,0",
            "CLS",
        ].joined(separator: "\r\n") + "\r\n"
        data.append(Data(header.utf8))
        appendBitmapBands(bitmap, to: &data)
        data.append(Data("PRINT 1,1\r\n".utf8))
        return data
    }

    /// Bluetooth is the bottleneck, so instead of one full-label BITMAP, send one BITMAP per run of
    /// non-blank rows, cropped to the columns that have ink. CLS already cleared the rest to white.
    private static func appendBitmapBands(_ bitmap: Data, to data: inout Data) {
        let white: UInt8 = invertBits ? 0x00 : 0xFF
        let maxBandRows = 64

        // Per row: first and last byte column containing ink, or nil when blank.
        let extents: [(Int, Int)?] = (0..<heightDots).map { y in
            let row = bitmap[(y * bytesPerRow)..<((y + 1) * bytesPerRow)]
            guard let first = row.firstIndex(where: { $0 != white }),
                  let last = row.lastIndex(where: { $0 != white }) else { return nil }
            return (first - y * bytesPerRow, last - y * bytesPerRow)
        }

        var y = 0
        while y < heightDots {
            guard let (rowFirst, rowLast) = extents[y] else { y += 1; continue }

            let top = y
            var first = rowFirst, last = rowLast
            y += 1
            while y < heightDots, y - top < maxBandRows, let (f, l) = extents[y] {
                first = min(first, f)
                last = max(last, l)
                y += 1
            }

            let widthBytes = last - first + 1
            data.append(Data("BITMAP \(first * 8),\(top),\(widthBytes),\(y - top),0,".utf8))
            for row in top..<y {
                let start = row * bytesPerRow + first
                data.append(bitmap[start..<(start + widthBytes)])
            }
            data.append(Data("\r\n".utf8))
        }
    }

    private static func previewImage(_ mono: [Bool]) -> CGImage? {
        let pixels = mono.map { $0 ? UInt8(0) : UInt8(255) }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: widthDots,
            height: heightDots,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: widthDots,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
