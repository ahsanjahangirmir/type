import XCTest
import AppKit
import PDFKit
@testable import TypeApp

/// Exports a long document to PDF on a given paper size and checks pagination
/// and page margins by rendering each page and measuring the ink.
@MainActor
final class PDFExportTests: XCTestCase {
    static let longMarkdown: String = {
        var s = "# A long document\n\n"
        for i in 1...6 {
            s += "## Section \(i)\n\nPara\(i)start intro.\n\n"
            s += String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. ", count: 6) + "\n\n"
            s += "> A quote that should keep its bar.\n\n- [x] done item\n- [ ] open item\n\n```\nlet x = \(i)\nprint(x)\n```\n\n| a | b |\n|---|---|\n| R\(i)A | x |\n| R\(i)B | y |\n| R\(i)C | z |\n\n---\n\n"
        }
        return s
    }()

    /// Renders a page to a bitmap and returns the ink bounding box margins in points.
    static func inkMargins(of page: PDFPage) -> (left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat)? {
        let box = page.bounds(for: .mediaBox)
        let scale: CGFloat = 1
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        guard let data = ctx.data else { return nil }
        let px = data.assumingMemoryBound(to: UInt8.self)
        let rowBytes = ctx.bytesPerRow
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h { for x in 0..<w {
            let o = y * rowBytes + x * 4
            if px[o] < 240 || px[o + 1] < 240 || px[o + 2] < 240 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        } }
        guard maxX >= 0 else { return nil }
        return (CGFloat(minX) / scale, CGFloat(w - 1 - maxX) / scale, CGFloat(minY) / scale, CGFloat(h - 1 - maxY) / scale)
    }

    private func export(paper: NSSize, markdown: String = longMarkdown) async throws -> PDFDocument {
        let shared = NSPrintInfo.shared
        let saved = shared.paperSize
        shared.paperSize = paper
        defer { shared.paperSize = saved }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try await Exporter.write(markdown: markdown, title: "Long", baseURL: nil, format: .pdf, fontChoice: .serif, customFamily: "", to: url)
        if let dir = ProcessInfo.processInfo.environment["TYPE_PDF_OUT"] {
            try? FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: dir).appendingPathComponent("\(Int(paper.width))x\(Int(paper.height)).pdf"))
        }
        return try XCTUnwrap(PDFDocument(url: url))
    }

    private func check(paper: NSSize, file: StaticString = #filePath, line: UInt = #line) async throws {
        let doc = try await export(paper: paper)
        XCTAssertGreaterThan(doc.pageCount, 1, "long content must paginate", file: file, line: line)
        for i in 0..<doc.pageCount {
            let page = try XCTUnwrap(doc.page(at: i))
            let box = page.bounds(for: .mediaBox)
            XCTAssertEqual(box.width, paper.width, accuracy: 1, "page \(i) width", file: file, line: line)
            XCTAssertEqual(box.height, paper.height, accuracy: 1, "page \(i) height", file: file, line: line)
            let m = try XCTUnwrap(Self.inkMargins(of: page), file: file, line: line)
            // Rounded corners / antialiasing may eat a point; require margin to be nearly the full 54pt.
            let want = Exporter.pageMargin - 3
            XCTAssertGreaterThanOrEqual(m.left, want, "page \(i) left margin", file: file, line: line)
            XCTAssertGreaterThanOrEqual(m.right, want, "page \(i) right margin", file: file, line: line)
            XCTAssertGreaterThanOrEqual(m.top, want, "page \(i) top margin", file: file, line: line)
            XCTAssertGreaterThanOrEqual(m.bottom, want, "page \(i) bottom margin", file: file, line: line)
        }
    }

    /// Tables stay whole and a heading stays with the text after it.
    func testBlocksNotSplit() async throws {
        var md = ""
        for i in 1...14 {
            md += "## Heading\(i)\n\nPara\(i)start " + String(repeating: "word ", count: 40 + i * 7) + "\n\n| h | h |\n|---|---|\n| R\(i)A | x |\n| R\(i)B | y |\n| R\(i)C | z |\n\n"
        }
        let doc = try await export(paper: NSSize(width: 595, height: 842), markdown: md)
        let pages = (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" }
        for i in 1...14 {
            let tableTokens = ["R\(i)A", "R\(i)B", "R\(i)C"].map { t in pages.firstIndex { $0.contains(t) } }
            XCTAssertEqual(Set(tableTokens).count, 1, "table \(i) split across pages \(tableTokens)")
            XCTAssertEqual(pages.firstIndex { $0.contains("Heading\(i)") }, pages.firstIndex { $0.contains("Para\(i)start") }, "heading \(i) separated from its text")
        }
    }

    private func solidPNG(width: Int, height: Int) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// Images wider or taller than the text area scale down to fit inside the margins.
    func testOversizedImagesFitInsideMargins() async throws {
        for paper in [NSSize(width: 595, height: 842), NSSize(width: 612, height: 792)] { try await oversizedImages(paper: paper) }
    }

    private func oversizedImages(paper: NSSize) async throws {
        let shared = NSPrintInfo.shared
        let saved = shared.paperSize
        shared.paperSize = paper
        defer { shared.paperSize = saved }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TypePDF-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try solidPNG(width: 3000, height: 1000).write(to: dir.appendingPathComponent("wide.png"))
        try solidPNG(width: 600, height: 3000).write(to: dir.appendingPathComponent("tall.png"))
        let url = dir.appendingPathComponent("out.pdf")
        let md = "# Images\n\n![wide](wide.png \"width=2000\")\n\nBetween.\n\n![tall](tall.png)\n\nAfter.\n"
        try await Exporter.write(markdown: md, title: "Img", baseURL: dir, format: .pdf, fontChoice: .serif, customFamily: "", to: url)
        if let out = ProcessInfo.processInfo.environment["TYPE_PDF_OUT"] { try? FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: out).appendingPathComponent("images-\(Int(paper.width)).pdf")) }
        let doc = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertGreaterThanOrEqual(doc.pageCount, 2)
        for i in 0..<doc.pageCount {
            let m = try XCTUnwrap(Self.inkMargins(of: try XCTUnwrap(doc.page(at: i))))
            let want = Exporter.pageMargin - 3
            XCTAssertGreaterThanOrEqual(min(m.left, m.right, m.top, m.bottom), want, "page \(i) margins \(m)")
        }
    }

    func testA4() async throws { try await check(paper: NSSize(width: 595, height: 842)) }
    func testLetter() async throws { try await check(paper: NSSize(width: 612, height: 792)) }

    /// Word and RTF files carry the user's paper size and the same 0.75 in margins.
    func testWordAndRTFPaperAndMargins() async throws {
        let shared = NSPrintInfo.shared
        let saved = shared.paperSize
        shared.paperSize = NSSize(width: 595, height: 842)
        defer { shared.paperSize = saved }
        for format in [ExportFormat.word, .rtf] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(format.fileExtension)
            try await Exporter.write(markdown: Self.longMarkdown, title: "Doc", baseURL: nil, format: format, fontChoice: .serif, customFamily: "", to: url)
            var attrs: NSDictionary?
            _ = try NSAttributedString(url: url, options: [:], documentAttributes: &attrs)
            let a = try XCTUnwrap(attrs as? [NSAttributedString.DocumentAttributeKey: Any])
            let size = try XCTUnwrap(a[.paperSize] as? NSSize, "\(format) paper size")
            XCTAssertEqual(size.width, 595, accuracy: 1, "\(format)")
            XCTAssertEqual(size.height, 842, accuracy: 1, "\(format)")
            for key in [NSAttributedString.DocumentAttributeKey.leftMargin, .rightMargin, .topMargin, .bottomMargin] {
                XCTAssertEqual(a[key] as? CGFloat ?? -1, Exporter.pageMargin, accuracy: 1, "\(format) \(key.rawValue)")
            }
        }
    }
}
