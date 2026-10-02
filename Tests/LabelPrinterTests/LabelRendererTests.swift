import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import LabelPrinter

struct LabelRendererTests {
    // MARK: - Raw TSPL

    @Test func rawTSPLIsSentWithCRLFLineEndings() throws {
        let url = try tempFile("label.tspl", contents: Data("CLS\nTEXT 1,1,\"3\",0,1,1,\"HI\"\r\nPRINT 1,1".utf8))

        let job = try LabelRenderer.makeJob(from: url)

        #expect(String(decoding: job.data, as: UTF8.self) == "CLS\r\nTEXT 1,1,\"3\",0,1,1,\"HI\"\r\nPRINT 1,1\r\n")
        #expect(job.preview == nil)
    }

    @Test func unsupportedFileTypeThrows() throws {
        let url = try tempFile("archive.zip", contents: Data([0x50, 0x4B]))

        #expect(throws: LabelRendererError.self) { try LabelRenderer.makeJob(from: url) }
    }

    @Test func uppercaseExtensionIsRecognized() throws {
        let pdf = try makePDF { _, _ in }
        let url = pdf.deletingLastPathComponent().appendingPathComponent("LABEL.PDF")
        try FileManager.default.moveItem(at: pdf, to: url)

        let job = try LabelRenderer.makeJob(from: url)

        #expect(job.preview != nil)
    }

    // MARK: - PDF

    @Test func eachPDFPagePrintsOneLabel() throws {
        let url = try makePDF(pages: 3) { context, size in
            context.fill(CGRect(x: 20, y: 20, width: size.width - 40, height: 40))
        }

        let job = try LabelRenderer.makeJob(from: url)

        #expect(job.pageCount == 3)
        #expect(occurrences(of: "PRINT 1,1\r\n", in: job.data) == 3)
        #expect(job.preview?.width == LabelRenderer.widthDots)
        #expect(job.preview?.height == LabelRenderer.heightDots)
    }

    @Test func blankPageSendsNoBitmapData() throws {
        let url = try makePDF { _, _ in }

        let job = try LabelRenderer.makeJob(from: url)

        #expect(occurrences(of: "BITMAP", in: job.data) == 0)
        #expect(occurrences(of: "CLS\r\n", in: job.data) == 1)
        #expect(occurrences(of: "PRINT 1,1\r\n", in: job.data) == 1)
    }

    @Test func croppedBandsReproduceTheFullLabel() throws {
        let url = try makePDF { context, size in
            context.fill(CGRect(x: 30, y: size.height - 60, width: 100, height: 30))
            for i in 0..<40 {
                context.fill(CGRect(x: 40 + CGFloat(i) * 5, y: 80, width: CGFloat(1 + i % 3), height: 60))
            }
        }

        let job = try LabelRenderer.makeJob(from: url)
        let preview = try #require(job.preview)

        #expect(decodeBitmaps(job.data).canvas == packedBits(of: preview))
        // Mostly-white label should be much smaller than a full-frame bitmap.
        #expect(job.data.count < LabelRenderer.bytesPerRow * LabelRenderer.heightDots / 4)
    }

    @Test func portraitPageKeepsItsOrientation() throws {
        // Black block in the page's top-left corner.
        let url = try makePDF { context, size in
            context.fill(CGRect(x: 0, y: size.height - 72, width: 72, height: 72))
        }

        let preview = try #require(LabelRenderer.makeJob(from: url).preview)

        #expect(isBlack(preview, x: 50, y: 50))
        #expect(!isBlack(preview, x: 760, y: 50))
        #expect(!isBlack(preview, x: 50, y: 1160))
    }

    @Test func solidLabelIsSplitIntoBandsOfAtMost64Rows() throws {
        let url = try makePDF { context, size in
            context.fill(CGRect(origin: .zero, size: size))
        }

        let job = try LabelRenderer.makeJob(from: url)
        let preview = try #require(job.preview)
        let decoded = decodeBitmaps(job.data)

        #expect(decoded.canvas == packedBits(of: preview))
        #expect(decoded.bandHeights.count > 1)
        #expect(decoded.bandHeights.allSatisfy { $0 <= 64 })
        #expect(decoded.bandHeights.reduce(0, +) == LabelRenderer.heightDots)
    }

    @Test func portraitPageMarkedAsRotatedPrintsUnrotated() throws {
        // Shipping-label PDFs are often 4x6 portrait with /Rotate set for on-screen viewing.
        let url = try makePDF { context, size in
            context.fill(CGRect(x: 0, y: size.height - 72, width: 72, height: 72))
        }
        let document = try #require(PDFDocument(url: url))
        document.page(at: 0)?.rotation = 90
        #expect(document.write(to: url))

        let preview = try #require(LabelRenderer.makeJob(from: url).preview)

        #expect(isBlack(preview, x: 50, y: 50))
        #expect(!isBlack(preview, x: 760, y: 1160))
    }

    // MARK: - Images

    @Test func midGrayImageIsDitheredToAboutHalfBlack() throws {
        let url = try makePNG(gray: 0.5)

        let job = try LabelRenderer.makeJob(from: url)
        let preview = try #require(job.preview)

        let pixels = grayPixels(preview)
        let blackFraction = Double(pixels.filter { $0 < 128 }.count) / Double(pixels.count)
        #expect(abs(blackFraction - 0.5) < 0.05)
        #expect(decodeBitmaps(job.data).canvas == packedBits(of: preview))
    }

    @Test func blackImageFillsTheLabel() throws {
        let url = try makePNG(gray: 0)

        let preview = try #require(LabelRenderer.makeJob(from: url).preview)

        #expect(grayPixels(preview).allSatisfy { $0 < 128 })
    }

    @Test func landscapePageIsRotatedOntoThePortraitLabel() throws {
        // Black block in the top-left corner of a landscape page ends up top-right after rotating clockwise.
        let url = try makePDF(size: CGSize(width: 432, height: 288)) { context, size in
            context.fill(CGRect(x: 0, y: size.height - 72, width: 72, height: 72))
        }

        let preview = try #require(LabelRenderer.makeJob(from: url).preview)

        #expect(isBlack(preview, x: 760, y: 50))
        #expect(!isBlack(preview, x: 50, y: 50))
    }

    // MARK: - Helpers

    private func tempFile(_ name: String, contents: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    /// Writes a PDF (4x6 in by default) where `draw` gets a context in page points, origin bottom-left.
    private func makePDF(
        size: CGSize = CGSize(width: 288, height: 432),
        pages: Int = 1,
        draw: (CGContext, CGSize) -> Void
    ) throws -> URL {
        let url = try tempFile("label.pdf", contents: Data())
        var box = CGRect(origin: .zero, size: size)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            draw(context, size)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    /// Writes a solid-gray PNG with the label's 2:3 aspect ratio, so it fills the label exactly.
    private func makePNG(gray: CGFloat) throws -> URL {
        let context = try #require(CGContext(
            data: nil, width: 400, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.setFillColor(gray: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
        let image = try #require(context.makeImage())

        let url = try tempFile("image.png", contents: Data())
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func occurrences(of needle: String, in data: Data) -> Int {
        let needle = Data(needle.utf8)
        var count = 0
        var start = data.startIndex
        while let range = data.range(of: needle, in: start..<data.endIndex) {
            count += 1
            start = range.upperBound
        }
        return count
    }

    private func grayPixels(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: image.width * image.height)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    /// x, y in label dots, origin top-left.
    private func isBlack(_ image: CGImage, x: Int, y: Int) -> Bool {
        grayPixels(image)[y * image.width + x] < 128
    }

    /// The preview packed the way TSPL expects: MSB first, 0 = black, 1 = white.
    private func packedBits(of image: CGImage) -> [UInt8] {
        let pixels = grayPixels(image)
        var bits = [UInt8](repeating: 0xFF, count: LabelRenderer.bytesPerRow * LabelRenderer.heightDots)
        for y in 0..<LabelRenderer.heightDots {
            for x in 0..<LabelRenderer.widthDots where pixels[y * LabelRenderer.widthDots + x] < 128 {
                bits[y * LabelRenderer.bytesPerRow + x / 8] &= ~(0x80 >> UInt8(x % 8))
            }
        }
        return bits
    }

    /// Replays every `BITMAP x,y,w,h,0,<data>` command onto a white canvas, like the printer would.
    private func decodeBitmaps(_ data: Data) -> (canvas: [UInt8], bandHeights: [Int]) {
        var bandHeights: [Int] = []
        var canvas = [UInt8](repeating: 0xFF, count: LabelRenderer.bytesPerRow * LabelRenderer.heightDots)
        let bytes = [UInt8](data)
        let tag = Array("BITMAP ".utf8)
        var i = 0
        while i < bytes.count {
            guard bytes[i...].starts(with: tag) else { i += 1; continue }
            i += tag.count

            var fields: [Int] = []
            var current = ""
            while fields.count < 5 {
                let c = Character(UnicodeScalar(bytes[i]))
                i += 1
                if c == "," { fields.append(Int(current)!); current = "" } else { current.append(c) }
            }

            let (x, y, width, height) = (fields[0], fields[1], fields[2], fields[3])
            bandHeights.append(height)
            for row in 0..<height {
                for col in 0..<width {
                    canvas[(y + row) * LabelRenderer.bytesPerRow + x / 8 + col] = bytes[i + row * width + col]
                }
            }
            i += width * height
        }
        return (canvas, bandHeights)
    }
}
