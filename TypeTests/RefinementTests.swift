import XCTest
import AppKit
import SwiftUI
@testable import TypeApp

@MainActor
final class LibraryTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TypeLib-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testFirstLaunchCreatesWelcome() {
        let store = LibraryStore(rootURL: root)
        XCTAssertEqual(store.notebooks.map(\.name), ["Getting Started"])
        XCTAssertEqual(store.pages(in: store.notebooks[0].url, sort: .name).map(\.title), ["Welcome to Type"])
        XCTAssertEqual(store.pages(in: store.notebooks[0].url, sort: .name)[0].heading, "Welcome to Type")
    }

    func testNotebookAndPageLifecycle() throws {
        let store = LibraryStore(rootURL: root)
        let backend = try store.createNotebook(named: "Backend Engineering")
        let page = try store.createPage(in: backend)
        XCTAssertEqual(page.lastPathComponent, "Untitled.md")
        let second = try store.createPage(in: backend)
        XCTAssertEqual(second.lastPathComponent, "Untitled 2.md")

        let webhooks = try store.renamePage(page, to: "Webhooks")
        XCTAssertEqual(webhooks.lastPathComponent, "Webhooks.md")
        XCTAssertEqual(Set(store.pages(in: backend, sort: .name).map(\.title)), ["Webhooks", "Untitled 2"])

        // Unique names and sanitizing
        let dup = try store.duplicatePage(webhooks)
        XCTAssertEqual(dup.lastPathComponent, "Webhooks copy.md")
        let odd = try store.renamePage(second, to: "  .Queues/Retries: v2 ")
        XCTAssertEqual(odd.lastPathComponent, "Queues-Retries- v2.md")

        // Move to another notebook
        let other = try store.createNotebook(named: "Archive")
        let moved = try store.movePage(dup, to: other)
        XCTAssertEqual(moved.deletingLastPathComponent().lastPathComponent, "Archive")
        XCTAssertEqual(store.pages(in: other, sort: .name).map(\.title), ["Webhooks copy"])

        // Rename notebook keeps open page models pointing at the right file
        let model = store.page(for: webhooks)
        let renamed = try store.renameNotebook(backend, to: "Backend")
        XCTAssertEqual(model.url.deletingLastPathComponent().standardizedFileURL, renamed.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.url.path))
    }

    func testMoveBringsImages() throws {
        let store = LibraryStore(rootURL: root)
        let a = try store.createNotebook(named: "A")
        let b = try store.createNotebook(named: "B")
        try FileManager.default.createDirectory(at: a.appendingPathComponent(".assets"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: a.appendingPathComponent(".assets/shot%201.png".removingPercentEncoding!))
        let page = try store.createPage(in: a, title: "P", text: "![x](.assets/shot%201.png \"width=200\")\n")
        _ = try store.movePage(page, to: b)
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.appendingPathComponent(".assets/shot 1.png").path))
    }

    func testPageModelSavesAndReloads() async throws {
        let store = LibraryStore(rootURL: root)
        let nb = try store.createNotebook(named: "N")
        let url = try store.createPage(in: nb, title: "Doc", text: "hello")
        let model = store.page(for: url)
        XCTAssertEqual(model.text, "hello")
        XCTAssertTrue(store.page(for: url) === model, "models are shared per file")
        model.text = "hello world"
        XCTAssertTrue(model.isDirty)
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello world")

        // External edit is picked up when there are no local changes.
        try await Task.sleep(for: .milliseconds(20))
        try Data("from elsewhere".utf8).write(to: url)
        model.reloadIfChangedOnDisk()
        XCTAssertEqual(model.text, "from elsewhere")
    }
}

@MainActor
final class ImageTests: XCTestCase {
    private func samplePNG(width: Int = 64, height: Int = 32) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    func testSavePastedImageNextToLibraryPage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TypeImg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = dir.appendingPathComponent("Webhooks.md")

        let pb = NSPasteboard(name: .init("TypeTest-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setData(samplePNG(), forType: .png)
        XCTAssertTrue(ImageStore.hasImage(pb))

        let saved = try ImageStore.saveImages(from: pb, documentURL: page, inLibrary: true)
        XCTAssertEqual(saved.count, 1)
        XCTAssertTrue(saved[0].markdownPath.hasPrefix(".assets/Screenshot-"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved[0].fileURL.path))
        XCTAssertEqual(ImageStore.resolve(saved[0].markdownPath, baseURL: dir)?.standardizedFileURL, saved[0].fileURL.standardizedFileURL)
    }

    func testTextOnPasteboardWins() {
        let pb = NSPasteboard(name: .init("TypeTest-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("hello", forType: .string)
        pb.setData(samplePNG(), forType: .png)
        XCTAssertFalse(ImageStore.hasImage(pb))
    }

    func testImageMarkdownAndHTML() {
        XCTAssertEqual(ImageSpec.markdown(alt: "a", path: ".assets/x.png", width: 320), "![a](.assets/x.png \"width=320\")")
        XCTAssertEqual(ImageSpec.width(fromTitle: "width=320"), 320)
        let html = MarkdownHTML.render("![shot](.assets/my_shot.png \"width=320\")")
        XCTAssertTrue(html.contains("<img src=\".assets/my_shot.png\" alt=\"shot\" width=\"320\">"), html)
    }

    func testHTMLExportEmbedsImages() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TypeEmbed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".assets"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try samplePNG().write(to: dir.appendingPathComponent(".assets/a.png"))
        let html = Exporter.embedImages(#"<p><img src=".assets/a.png" alt=""></p>"#, baseURL: dir)
        XCTAssertTrue(html.contains("src=\"data:image/png;base64,"), html)
    }

    func testBlockImageStyledAndHidden() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TypeStyle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try samplePNG(width: 400, height: 200).write(to: dir.appendingPathComponent("a.png"))

        let config = AppSettings.shared.editorConfig
        let styler = MarkdownStyler(config: config)
        styler.columnWidth = 300
        styler.imageProvider = { ImageStore.resolve($0, baseURL: dir).flatMap { NSImage(contentsOf: $0) } }
        let storage = NSTextStorage(string: "Intro\n![a](a.png)\nAfter")
        styler.style(storage, blocks: MarkdownStyler.scanBlocks(storage.string as NSString))
        let spec = storage.attribute(.typeImage, at: 7, effectiveRange: nil) as? ImageSpec
        XCTAssertNotNil(spec)
        XCTAssertEqual(spec?.displaySize.width, 300, "capped to the column")
        XCTAssertEqual(spec?.displaySize.height, 150)
        XCTAssertNotNil(storage.attribute(.typeHidden, at: 7, effectiveRange: nil), "image syntax is hidden even with syntax visible")
    }
}

final class HiddenSyntaxTests: XCTestCase {
    private func makeView(_ text: String) -> TypeTextView {
        let tv = TypeTextView(usingTextLayoutManager: false)
        tv.isRichText = false
        tv.allowsUndo = true
        var config = AppSettings.shared.editorConfig
        config.smartQuotes = false
        tv.config = config
        tv.installLayoutDelegate()
        tv.string = text
        let styler = MarkdownStyler(config: config)
        styler.style(tv.textStorage!, blocks: MarkdownStyler.scanBlocks(text as NSString))
        return tv
    }

    private func hidden(_ tv: TypeTextView) -> String {
        let s = tv.textStorage!
        return String((0..<s.length).map { s.attribute(.typeHidden, at: $0, effectiveRange: nil) != nil ? "^" : "." })
    }

    func testMarkersAreHidden() {
        XCTAssertEqual(hidden(makeView("## Head")), "^^^....")
        XCTAssertEqual(hidden(makeView("a **b** c")), "..^^.^^..")
        XCTAssertEqual(hidden(makeView("[l](u)")), "^.^^^^")
        XCTAssertEqual(hidden(makeView("> q")), "^^.")
        XCTAssertEqual(hidden(makeView("`c`")), "^.^")
    }

    func testBulletsAndTasks() {
        let tv = makeView("- item")
        XCTAssertEqual(tv.textStorage?.attribute(.typeGlyph, at: 0, effectiveRange: nil) as? String, "•")
        let task = makeView("- [x] done")
        XCTAssertEqual(task.textStorage?.attribute(.typeTaskBox, at: 3, effectiveRange: nil) as? Bool, true)
        XCTAssertEqual(hidden(task), "^^^.^.....")
    }

    func testBackspaceSkipsHiddenMarkers() {
        let tv = makeView("**bold**")
        tv.setSelectedRange(NSRange(location: 8, length: 0))
        tv.deleteBackward(nil)
        XCTAssertEqual(tv.string, "**bol**")
    }

    func testBackspaceRemovesHeadingPrefix() {
        let tv = makeView("## Title")
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        tv.deleteBackward(nil)
        XCTAssertEqual(tv.string, "Title")
    }

    func testCaretSnapsOutOfHiddenRuns() {
        let tv = makeView("## Title")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertEqual(tv.selectedRange().location, 3, "caret never sits before a hidden heading prefix")
        let tv2 = makeView("a **b**")
        tv2.setSelectedRange(NSRange(location: 1, length: 0))
        tv2.setSelectedRange(NSRange(location: 3, length: 0)) // inside "**" moving right
        XCTAssertEqual(tv2.selectedRange().location, 4)
        tv2.setSelectedRange(NSRange(location: 6, length: 0))
        tv2.setSelectedRange(NSRange(location: 5, length: 0)) // at boundary: allowed
        XCTAssertEqual(tv2.selectedRange().location, 5)
    }

    func testGlyphsAreSuppressedInLayout() {
        let tv = makeView("**bold**")
        tv.textContainer?.containerSize = NSSize(width: 500, height: 1000)
        let lm = tv.layoutManager!
        lm.ensureLayout(for: tv.textContainer!)
        XCTAssertTrue(lm.propertyForGlyph(at: 0).contains(.controlCharacter))
        XCTAssertFalse(lm.propertyForGlyph(at: 2).contains(.controlCharacter))
        // Hidden markers take no horizontal space.
        XCTAssertEqual(lm.location(forGlyphAt: 2).x, tv.textContainer!.lineFragmentPadding, accuracy: 0.5)
    }
}

@MainActor
final class PageTitleTests: XCTestCase {
    func testFirstHeadingNamesThePage() {
        XCTAssertEqual(LibraryStore.firstHeading(in: "Intro text\n\n## **Webhooks** guide ##\n# Later"), "Webhooks guide")
        XCTAssertEqual(LibraryStore.firstHeading(in: "```\n# not a heading\n```\n# Real"), "Real")
        XCTAssertNil(LibraryStore.firstHeading(in: "# \n\nNo title yet"))
        XCTAssertNil(LibraryStore.firstHeading(in: "#hashtag only"))
    }

    func testRenameRewritesHeadingAndSyncsFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TypeLib-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let nb = try store.createNotebook(named: "Backend")
        let url = try store.createPage(in: nb)
        let model = store.page(for: url)
        XCTAssertEqual(model.text, "# ")
        model.setHeading("Webhooks")
        XCTAssertEqual(model.text, "# Webhooks")
        model.text += "\n\nBody"
        model.setHeading("Webhook Retries")
        XCTAssertEqual(model.text, "# Webhook Retries\n\nBody")
        model.saveNow()
        let renamed = try store.renamePage(url, to: model.heading!)
        XCTAssertEqual(renamed.lastPathComponent, "Webhook Retries.md")
        XCTAssertEqual(try store.renamePage(renamed, to: "Webhook Retries"), renamed, "no-op rename")

        let plain = store.page(for: try store.createPage(in: nb, text: "Some text"))
        plain.setHeading("Added")
        XCTAssertEqual(plain.text, "# Added\n\nSome text")
    }
}

@MainActor
final class EditorFixTests: XCTestCase {
    private func makeView(_ text: String) -> TypeTextView {
        let tv = TypeTextView(usingTextLayoutManager: false)
        tv.isRichText = false
        tv.allowsUndo = true
        var config = AppSettings.shared.editorConfig
        config.smartQuotes = false
        tv.config = config
        tv.installLayoutDelegate()
        tv.string = text
        MarkdownStyler(config: config).style(tv.textStorage!, blocks: MarkdownStyler.scanBlocks(text as NSString))
        return tv
    }

    func testHighlightMidSentenceTrimsSelection() {
        let tv = makeView("The quick brown fox jumps")
        tv.setSelectedRange(NSRange(location: 4, length: 12)) // "quick brown " (drag caught the space)
        tv.toggleWrap("==")
        XCTAssertEqual(tv.string, "The ==quick brown== fox jumps")
        var config = AppSettings.shared.editorConfig
        MarkdownStyler(config: config).style(tv.textStorage!, blocks: BlockRanges())
        XCTAssertNotNil(tv.textStorage?.attribute(.backgroundColor, at: 8, effectiveRange: nil), "highlighted")
        XCTAssertNotNil(tv.textStorage?.attribute(.typeHidden, at: 4, effectiveRange: nil), "markers hidden")
        // Toggling again unwraps.
        tv.setSelectedRange(NSRange(location: 6, length: 11))
        tv.toggleWrap("==")
        XCTAssertEqual(tv.string, "The quick brown fox jumps")
    }

    func testListsAreIndented() {
        do {
            let tv = makeView("Para\n- item\n    - nested\n1. first\n- [ ] task")
            let s = tv.textStorage!
            func style(_ i: Int) -> NSParagraphStyle { s.attribute(.paragraphStyle, at: i, effectiveRange: nil) as! NSParagraphStyle }
            let ns = tv.string as NSString
            let item = style(ns.range(of: "- item").location)
            let nested = style(ns.range(of: "nested").location)
            let numbered = style(ns.range(of: "first").location)
            let task = style(ns.range(of: "task").location)
            XCTAssertGreaterThan(item.firstLineHeadIndent, 10)
            XCTAssertGreaterThan(item.headIndent, item.firstLineHeadIndent, "wrapped lines align after the bullet")
            XCTAssertEqual(numbered.firstLineHeadIndent, item.firstLineHeadIndent)
            XCTAssertEqual(task.firstLineHeadIndent, item.firstLineHeadIndent)
            XCTAssertGreaterThan(nested.headIndent - item.headIndent, 20, "nested level steps in")
            XCTAssertEqual(style(0).firstLineHeadIndent, 0, "paragraphs stay flush")
        }
    }

    func testSwitchingDocumentsReusesTextView() {
        let controller = EditorController()
        let config = AppSettings.shared.editorConfig
        func view(_ text: String, _ id: Int) -> some View {
            EditorTextView(text: .constant(text), config: config, controller: controller, documentID: id).frame(width: 700, height: 500)
        }
        let a = "# Page A\n\n" + String(repeating: "Some **bold** words and a [link](https://x.y).\n\n", count: 300)
        let b = "# Page B\n\n- one\n- two"
        let host = NSHostingView(rootView: AnyView(view(a, 1)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let tv = controller.textView else { return XCTFail("no text view") }
        tv.setSelectedRange(NSRange(location: 40, length: 0))

        let start = Date()
        host.rootView = AnyView(view(b, 2)); host.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.textView === tv, "same text view")
        XCTAssertEqual(tv.string, b)
        XCTAssertNotNil(tv.textStorage?.attribute(.typeHeading, at: 2, effectiveRange: nil), "restyled")
        host.rootView = AnyView(view(a, 1)); host.layoutSubtreeIfNeeded()
        XCTAssertEqual(tv.selectedRange().location, 40, "caret remembered per page")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.25, "two switches (one long page) took \(elapsed)s")
        window.close()
    }

    func testSelectionColorApplied() {
        let tv = makeView("x")
        var config = tv.config!
        config.selectionColor = .custom
        config.selectionCustomHex = "#FF000080"
        tv.config = config
        let color = (tv.selectedTextAttributes[.backgroundColor] as? NSColor)?.usingColorSpace(.sRGB)
        XCTAssertEqual(color?.redComponent ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(color?.alphaComponent ?? 0, 0.5, accuracy: 0.01)
        XCTAssertEqual(NSColor(hex: "#336699")?.hexString, "#336699FF")
    }
}

final class SoundTests: XCTestCase {
    func testEveryProfileSynthesizes() {
        for profile in SoundProfile.allCases {
            let set = TypingSounds.shared.buffers(for: profile)
            for kind in TypingSounds.Kind.allCases {
                let buffers = set[kind] ?? []
                XCTAssertEqual(buffers.count, 4, "\(profile) \(kind)")
                for b in buffers {
                    XCTAssertGreaterThan(b.frameLength, 100)
                    let samples = UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength))
                    let peak = samples.map { abs($0) }.max() ?? 0
                    XCTAssertGreaterThan(peak, 0.01, "\(profile) \(kind) is silent")
                    XCTAssertLessThanOrEqual(peak, 1.0, "\(profile) \(kind) clips")
                }
            }
        }
    }
}
