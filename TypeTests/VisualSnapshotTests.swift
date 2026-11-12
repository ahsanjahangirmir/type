import XCTest
import SwiftUI
@testable import TypeApp

/// Renders the real editor pipeline off-screen to PNGs for visual review.
/// Runs only when TEST_RUNNER_TYPE_SNAPSHOT_DIR is set.
@MainActor
final class VisualSnapshotTests: XCTestCase {
    private var outDir: URL? {
        ProcessInfo.processInfo.environment["TYPE_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    private func render(_ markdown: String, name: String, baseURL: URL?, dark: Bool = false, prepare: ((TypeTextView) -> Void)? = nil, configure: (inout EditorConfig) -> Void) throws {
        guard let outDir else { throw XCTSkip("Set TEST_RUNNER_TYPE_SNAPSHOT_DIR to render snapshots") }
        var config = AppSettings.shared.editorConfig
        config.fontChoice = .serif
        config.fontSize = 17
        config.textWidth = .medium
        config.focusMode = false
        config.typewriterScrolling = false
        configure(&config)
        let controller = EditorController()
        let view = EditorTextView(text: .constant(markdown), config: config, controller: controller, baseURL: baseURL)
            .frame(width: 820, height: 1100)
            .background(Color(nsColor: PaperTheme.paper.nsColor))
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 1100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.layoutIfNeeded()
        for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        guard let tv = controller.textView else { return XCTFail("no text view") }
        tv.layoutImageViews()
        prepare?(tv)
        for _ in 0..<4 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        host.layoutSubtreeIfNeeded()
        let rect = host.bounds
        let rep = host.bitmapImageRepForCachingDisplay(in: rect)!
        host.cacheDisplay(in: rect, to: rep)
        // cacheDisplay skips layer contents of the image overlays; composite them manually.
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        let composed = NSImage(size: rect.size, flipped: true) { _ in
            image.draw(in: rect)
            for case let block as ImageBlockView in tv.subviews {
                let frame = tv.convert(block.frame, to: host)
                let path = NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12)
                NSGraphicsContext.current?.saveGraphicsState()
                path.addClip()
                if let spec = block.spec, let img = tv.image(for: spec.path) { img.draw(in: frame) }
                NSGraphicsContext.current?.restoreGraphicsState()
                NSColor.separatorColor.setStroke()
                path.stroke()
            }
            return true
        }
        let out = NSBitmapImageRep(data: composed.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try out.write(to: outDir.appendingPathComponent("\(name).png"))
        var dump = ""
        for case let block as ImageBlockView in tv.subviews { dump += "image frame=\(block.frame)\n" }
        if let lm = tv.layoutManager {
            var g = 0
            while g < lm.numberOfGlyphs {
                var r = NSRange()
                let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: &r)
                let cr = lm.characterRange(forGlyphRange: r, actualGlyphRange: nil)
                dump += "y=\(Int(frag.minY)) h=\(Int(frag.height)) \((tv.string as NSString).substring(with: cr).replacingOccurrences(of: "\n", with: "⏎").prefix(50))\n"
                g = NSMaxRange(r)
            }
        }
        try dump.write(to: outDir.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        window.close()
    }

    private let sample = """
    # Webhooks

    Webhooks let **external services** notify us. See the *retry* policy and `X-Signature` header, or [the docs](https://example.com).

    ## Delivery

    - Events are queued
    - Retries back off ==exponentially== with jitter, so a long list item wraps onto a second line to show the hanging indent
        - Nested item
    1. First numbered
    2. Second numbered
    - [ ] Add dead-letter queue
    - [x] Verify signatures

    > Never trust an unsigned payload.

    | Event | Retries | Owner |
    | --- | --- | --- |
    | invoice.paid | 5 | **Billing** |
    | customer.deleted | 3 | Accounts |

    Recurring I*ncome/Expe*nses and ***~~==stacked==~~*** formats.

    ```json
    { "event": "invoice.paid" }
    ```

    ---

    <!-- private note: check with ops -->
    Final paragraph.
    """

    func testRenderHiddenSyntax() throws {
        try render(sample, name: "hidden", baseURL: nil) { _ in }
    }

    func testRenderImage() throws {
        guard let outDir else { throw XCTSkip("no snapshot dir") }
        let dir = outDir.appendingPathComponent("imgdoc")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".assets"), withIntermediateDirectories: true)
        let img = NSImage(size: NSSize(width: 900, height: 500), flipped: false) { r in
            NSGradient(colors: [.systemIndigo, .systemTeal])!.draw(in: r, angle: 30)
            ("Webhook delivery dashboard" as NSString).draw(at: NSPoint(x: 60, y: 230), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 44), .foregroundColor: NSColor.white])
            return true
        }
        try ImageStore.pngData(img)!.write(to: dir.appendingPathComponent(".assets/shot.png"))
        let md = "# Screenshot test\n\nA paragraph before the image.\n\n> A quote right above.\n![shot](.assets/shot.png \"width=420\")\nText right after the image.\n"
        try render(md, name: "image", baseURL: dir) { _ in }
    }

    /// Irregular tables and a selected image, with the user's settings (focus mode, low opacity).
    func testRenderTablesAndSelectedImage() throws {
        guard let outDir else { throw XCTSkip("no snapshot dir") }
        let dir = outDir.appendingPathComponent("tabledoc")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".assets"), withIntermediateDirectories: true)
        let img = NSImage(size: NSSize(width: 600, height: 240), flipped: false) { r in
            NSGradient(colors: [.systemPurple, .systemOrange])!.draw(in: r, angle: 20)
            return true
        }
        try ImageStore.pngData(img)!.write(to: dir.appendingPathComponent(".assets/shot.png"))
        let md = """
        | Hello there | What's Up | | Hello there |
        | --- | --- | --- | --- |
        | this is a reminder | what do you mean | | this is also a reminder | | |
        | | | | | | | |

        ![shot](.assets/shot.png "width=360")

        ==what do you mean? So we have to work on our relationship now?==

        | A | B |
        | --- | --- |
        | short |
        | x | y | z |

        """
        for dark in [false, true] {
            try render(md, name: dark ? "tables-dark" : "tables-light", baseURL: dir, dark: dark, prepare: { tv in
                let r = (tv.string as NSString).range(of: "![shot]")
                tv.setSelectedRange(NSRange(location: r.location + 3, length: 0))
                // (A light-mode render with a ranged selection comes out blank in this harness, with or without the fix.)
                if dark { tv.setSelectedRange(NSRange(location: r.location + 3, length: 6)) }
            }) {
                $0.focusMode = true; $0.focusOpacity = 0.19
                $0.fontChoice = .custom; $0.customFontFamily = "Avenir Next"; $0.fontSize = 14; $0.lineHeight = 1.2
            }
        }
    }

    func testExportDocuments() async throws {
        guard let outDir else { throw XCTSkip("no snapshot dir") }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let md = sample + "\n\n" + (1...12).map { "Paragraph \($0): " + String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 4) }.joined(separator: "\n\n")
        for format in [ExportFormat.pdf, .word, .rtf, .html] {
            try await Exporter.write(markdown: md, title: "Webhooks", baseURL: nil, format: format, fontChoice: .serif, customFamily: "", to: outDir.appendingPathComponent("export.\(format.fileExtension)"))
        }
    }
}
