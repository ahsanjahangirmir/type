import XCTest
import SwiftUI
@testable import TypeApp

/// Scrolling and typing benchmarks on a long, realistic document (tables,
/// images, highlights, lists) with the settings the app is used with.
@MainActor
final class ScrollPerformanceTests: XCTestCase {
    private var dir: URL!
    private var window: NSWindow!
    private var controller: EditorController!
    private var tv: TypeTextView { controller.textView! }

    /// Timing assertions only mean something in an optimized build.
    private func requireRelease() throws {
        #if DEBUG
        throw XCTSkip("timing thresholds apply to Release builds")
        #endif
    }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("type-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".assets"), withIntermediateDirectories: true)
        for i in 0..<12 { try Self.png(width: 1600, height: 900, seed: i).write(to: dir.appendingPathComponent(".assets/img\(i).png")) }
    }

    override func tearDown() async throws {
        window?.close()
        try? FileManager.default.removeItem(at: dir)
    }

    private static func png(width: Int, height: Int, seed: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(starting: NSColor(hue: CGFloat(seed) / 12, saturation: 0.5, brightness: 0.9, alpha: 1), ending: .darkGray)!
            .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 45)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    static func document(sections: Int) -> String {
        var out = ""
        for s in 0..<sections {
            out += "# Section \(s)\n\n"
            for p in 0..<4 {
                out += "Paragraph \(s).\(p) has **bold**, *italic*, ==highlighted text==, `code`, and a [link](https://example.com) so styling has real work to do. "
                out += "It runs long enough to wrap across several lines of the editor column, which is what real prose does.\n\n"
            }
            out += "- first item with ==mark==\n- second item\n  - nested item\n- [ ] a task\n- [x] done task\n\n"
            if s % 6 == 0 { out += "![shot](.assets/img\((s / 6) % 12).png)\n\n" }
            if s % 8 == 1 {
                out += "| Name | Qty | Notes |\n|---|---:|---|\n"
                for r in 0..<5 { out += "| Item \(r) | \(r * 7) | some note \(r) |\n" }
                out += "\n"
            }
            out += "> a quoted line\n\n---\n\n"
        }
        return out
    }

    private func host(_ markdown: String, focus: Bool = true) {
        controller = EditorController()
        var config = AppSettings.shared.editorConfig
        config.fontChoice = .sans
        config.fontSize = 14
        config.focusMode = focus
        config.focusOpacity = 0.19
        config.smoothTyping = true
        config.typewriterScrolling = false
        config.typingSounds = false
        let view = EditorTextView(text: .constant(markdown), config: config, controller: controller, baseURL: dir)
            .frame(width: 1200, height: 900)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        spin(0.5)
    }

    private func spin(_ s: TimeInterval = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func report(_ name: String, _ ms: [Double]) {
        let sorted = ms.sorted()
        let mean = ms.reduce(0, +) / Double(ms.count)
        let line = String(format: "PERF %@: n=%d mean=%.2fms p50=%.2fms p95=%.2fms max=%.2fms", name, ms.count, mean,
                          sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95)], sorted.last!)
        print(line)
    }

    /// Time of each programmatic scroll step, including the display pass and the run-loop turn
    /// that follows it (where deferred layout / caret / image work lands).
    private func scrollSteps(step: CGFloat, count: Int) -> [Double] {
        let clip = tv.enclosingScrollView!.contentView
        var times: [Double] = []
        var y: CGFloat = 0
        for _ in 0..<count {
            y += step
            let t0 = CACurrentMediaTime()
            clip.scroll(to: NSPoint(x: 0, y: y))
            tv.enclosingScrollView!.reflectScrolledClipView(clip)
            window.displayIfNeeded()
            spin(0.001)
            times.append((CACurrentMediaTime() - t0) * 1000)
        }
        return times
    }

    func testScrollThroughLongDocument() throws {
        try requireRelease()
        let md = Self.document(sections: 300)
        host(md)
        print("PERF doc: \((md as NSString).length) chars, \(md.split(separator: "\n", omittingEmptySubsequences: false).count) lines, height \(tv.frame.height)")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        spin(0.3)
        let times = scrollSteps(step: 40, count: Int(ProcessInfo.processInfo.environment["TYPE_PERF_STEPS"] ?? "") ?? 200)
        report("scroll 40pt steps", times)
        let fast = scrollSteps(step: 400, count: 100)
        report("scroll 400pt steps", fast)
        XCTAssertLessThan(times.sorted()[Int(Double(times.count) * 0.95)], 8, "p95 scroll step")
    }

    func testTypingInLargeDocument() throws {
        try requireRelease()
        let md = Self.document(sections: 300)
        host(md)
        let mid = (md as NSString).length / 2
        let line = (md as NSString).lineRange(for: NSRange(location: mid, length: 0))
        tv.setSelectedRange(NSRange(location: line.location, length: 0))
        spin(0.3)
        var times: [Double] = []
        for i in 0..<(Int(ProcessInfo.processInfo.environment["TYPE_PERF_KEYS"] ?? "") ?? 200) {
            let t0 = CACurrentMediaTime()
            tv.insertText(i % 9 == 8 ? " " : "x", replacementRange: NSRange(location: NSNotFound, length: 0))
            window.displayIfNeeded()
            spin(0.001)
            times.append((CACurrentMediaTime() - t0) * 1000)
        }
        report("typing", times)
        XCTAssertLessThan(times.sorted()[Int(Double(times.count) * 0.5)], 8, "median keystroke (330k-character document)")
    }

    /// Repositioning the image views (run after every layout pass and scroll-driven resize)
    /// must not rescan the document or touch the disk when the text hasn't changed.
    func testImageRepositionIsCheapWhenTextUnchanged() throws {
        try requireRelease()
        host(Self.document(sections: 300))
        tv.layoutImageViews()
        let t0 = CACurrentMediaTime()
        for _ in 0..<20 { tv.layoutImageViews() }
        let each = (CACurrentMediaTime() - t0) * 1000 / 20
        print(String(format: "PERF layoutImageViews steady: %.3fms", each))
        XCTAssertLessThan(each, 0.5)
    }

    func testImageViewsFollowTextEdits() {
        host("![a](.assets/img0.png)\n\ntext\n\n![b](.assets/img1.png)\n")
        func imageViewCount() -> Int { tv.subviews.filter { $0 is ImageBlockView }.count }
        XCTAssertEqual(imageViewCount(), 2)
        // Raw Markdown edits (typed text is literal now, so it couldn't make an image).
        tv.replace(NSRange(location: 0, length: 0), with: "![c](.assets/img2.png)\n", caret: nil)
        spin(0.2)
        XCTAssertEqual(imageViewCount(), 3)
        tv.replace(NSRange(location: 0, length: 23), with: "", caret: nil)
        spin(0.2)
        XCTAssertEqual(imageViewCount(), 2)
    }

    func testScanBlocksFindsFencesCommentsAndTables() {
        let md = "intro\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```\n| not | table |\n|--|--|\n```\n\n<!-- note -->\n  | x |\n  |---|\n\n| lone |\n"
        let b = MarkdownStyler.scanBlocks(md as NSString)
        let ns = md as NSString
        XCTAssertEqual(b.tables.map { ns.substring(with: $0) }, ["| a | b |\n|---|---|\n| 1 | 2 |", "  | x |\n  |---|"])
        XCTAssertEqual(b.code.count, 1)
        XCTAssertEqual(b.comments.map { ns.substring(with: $0) }, ["<!-- note -->"])
        XCTAssertTrue(MarkdownStyler.scanBlocks("plain text\n" as NSString).tables.isEmpty)
    }

    func testTypingAtTopOfLargeDocument() {
        host(Self.document(sections: 300))
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        spin(0.3)
        var times: [Double] = []
        for _ in 0..<(Int(ProcessInfo.processInfo.environment["TYPE_PERF_KEYS"] ?? "") ?? 60) {
            let t0 = CACurrentMediaTime()
            tv.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
            window.displayIfNeeded()
            spin(0.001)
            times.append((CACurrentMediaTime() - t0) * 1000)
        }
        report("typing at top", times)
    }
}
