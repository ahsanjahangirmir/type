import XCTest
import SwiftUI
@testable import TypeApp

/// A live editor (text view + coordinator restyling on every edit) in an off-screen window.
@MainActor
final class LiveEditor {
    let window: NSWindow
    let controller = EditorController()
    var tv: TypeTextView { controller.textView! }
    var text: String { tv.string }

    init(_ markdown: String, baseURL: URL? = nil, configure: (inout EditorConfig) -> Void = { _ in }) {
        var config = AppSettings.shared.editorConfig
        config.fontChoice = .sans
        config.fontSize = 16
        config.focusMode = false
        config.typewriterScrolling = false
        config.smartQuotes = false; config.smartDashes = false; config.smartArrows = false
        config.smartEllipses = false; config.autoCapitalize = false
        config.typingSounds = false
        config.hideCaret = false
        configure(&config)
        let view = EditorTextView(text: .constant(markdown), config: config, controller: controller, baseURL: baseURL)
            .frame(width: 800, height: 900)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.layoutIfNeeded()
        spin()
    }

    func spin(_ seconds: TimeInterval = 0.15) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func type(_ s: String) {
        for ch in s {
            if ch == "\n" { tv.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
            else { tv.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        }
    }

    func select(_ substring: String) {
        let r = (text as NSString).range(of: substring)
        precondition(r.location != NSNotFound, "\(substring) not in \(text)")
        tv.setSelectedRange(r)
    }

    func caret(at location: Int) { tv.setSelectedRange(NSRange(location: location, length: 0)) }

    /// The characters that are drawn (hidden syntax removed).
    var visible: String {
        let s = tv.textStorage!
        var out = ""
        let ns = text as NSString
        for i in 0..<ns.length where s.attribute(.typeHidden, at: i, effectiveRange: nil) == nil {
            out += ns.substring(with: NSRange(location: i, length: 1))
        }
        return out
    }

    func close() { window.close() }
}

@MainActor
final class InlineFormattingTests: XCTestCase {
    func testIntrawordItalicRenders() {
        let e = LiveEditor("Recurring I*ncome/Expe*nses here")
        defer { e.close() }
        XCTAssertEqual(e.visible, "Recurring Income/Expenses here", "markers inside a word are syntax, not text")
        let font = e.tv.textStorage!.attribute(.font, at: 12, effectiveRange: nil) as! NSFont
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.italic))
    }

    func testItalicMidWordFromToolbar() {
        let e = LiveEditor("Recurring Income/Expenses here")
        defer { e.close() }
        e.select("ncome/Expe")
        e.controller.italic()
        XCTAssertEqual(e.text, "Recurring I*ncome/Expe*nses here")
        XCTAssertEqual(e.visible, "Recurring Income/Expenses here")
    }

    func testStackingFormatsNeverExposesMarkdown() {
        let e = LiveEditor("## For example, take a look at this\n")
        defer { e.close() }
        e.tv.setSelectedRange(NSRange(location: 0, length: (e.text as NSString).length))
        for _ in 0..<2 {
            e.controller.bold(); e.controller.italic(); e.controller.strikethrough(); e.controller.highlight()
        }
        // Toggled twice: back to plain.
        XCTAssertEqual(e.text, "## For example, take a look at this\n")
        e.select("For example, take a look at this")
        e.controller.bold(); e.controller.italic(); e.controller.strikethrough(); e.controller.highlight()
        XCTAssertTrue(e.text.hasPrefix("## "), "the heading prefix is never wrapped: \(e.text)")
        XCTAssertEqual(e.visible, "For example, take a look at this\n", e.text)
        // Remove italic only.
        e.controller.italic()
        XCTAssertEqual(e.visible, "For example, take a look at this\n", e.text)
        let font = e.tv.textStorage!.attribute(.font, at: e.text.distance(of: "example")!, effectiveRange: nil) as! NSFont
        XCTAssertFalse(font.fontDescriptor.symbolicTraits.contains(.italic), e.text)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold), e.text)
    }

    func testMultiLineSelectionWrapsEachLine() {
        let e = LiveEditor("- one\n- two\n")
        defer { e.close() }
        e.tv.setSelectedRange(NSRange(location: 0, length: 11))
        e.controller.bold()
        XCTAssertEqual(e.text, "- **one**\n- **two**\n")
        e.controller.bold()
        XCTAssertEqual(e.text, "- one\n- two\n")
    }

    func testPartialRemoveSplitsSpan() {
        let e = LiveEditor("**alpha beta gamma**")
        defer { e.close() }
        e.select("beta")
        e.controller.bold()
        XCTAssertEqual(e.text, "**alpha** beta **gamma**")
    }

    func testBoldAcrossExistingBoldMerges() {
        let e = LiveEditor("abc **def** ghi")
        defer { e.close() }
        e.tv.setSelectedRange(NSRange(location: 0, length: 8))  // "abc **de"
        e.controller.bold()
        XCTAssertEqual(e.text, "**abc def** ghi")
    }

    func testBoldInsideItalicUsesParseableMarkers() {
        let e = LiveEditor("*text more*")
        defer { e.close() }
        e.select("text")
        e.controller.bold()
        XCTAssertEqual(e.visible, "text more")
        let s = e.tv.textStorage!
        let f = s.attribute(.font, at: e.text.distance(of: "text")!, effectiveRange: nil) as! NSFont
        XCTAssertTrue(f.fontDescriptor.symbolicTraits.contains([.bold, .italic]), e.text)
    }

    func testEmptySelectionFormatsNextTypedText() {
        let e = LiveEditor("Hello ")
        defer { e.close() }
        e.caret(at: 6)
        e.controller.bold()
        XCTAssertEqual(e.text, "Hello ", "nothing visible is inserted")
        e.type("world")
        XCTAssertEqual(e.text, "Hello **world**")
        e.controller.bold()
        e.type(" again")
        XCTAssertEqual(e.text, "Hello **world** again")
    }

    func testCaretInsideWordFormatsWord() {
        let e = LiveEditor("one two three")
        defer { e.close() }
        e.caret(at: 5)
        e.controller.italic()
        XCTAssertEqual(e.text, "one *two* three")
    }
}

@MainActor
final class LinkTests: XCTestCase {
    func testRepeatedLinkNeverNests() {
        let e = LiveEditor("see docs here")
        defer { e.close() }
        e.select("docs")
        var target = e.tv.linkTarget()
        XCTAssertFalse(target.isExisting)
        e.tv.applyLink(target, label: target.label, url: "example.com")
        XCTAssertEqual(e.text, "see [docs](https://example.com) here")
        // ⌘K again with the caret inside the link edits it.
        e.caret(at: 8)
        target = e.tv.linkTarget()
        XCTAssertTrue(target.isExisting)
        XCTAssertEqual(target.url, "https://example.com")
        e.tv.applyLink(target, label: target.label, url: "https://apple.com")
        XCTAssertEqual(e.text, "see [docs](https://apple.com) here")
        e.caret(at: 6)
        e.tv.removeLink(e.tv.linkTarget())
        XCTAssertEqual(e.text, "see docs here")
    }

    func testURLNormalization() {
        XCTAssertEqual(TypeTextView.normalizedURL("example.com/a b"), "https://example.com/a%20b")
        XCTAssertEqual(TypeTextView.normalizedURL("me@x.com"), "mailto:me@x.com")
        XCTAssertEqual(TypeTextView.normalizedURL("https://x.com/(1)"), "https://x.com/%281%29")
    }
}

@MainActor
final class AtomicLineTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("TypeAtomic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".assets"), withIntermediateDirectories: true)
        let img = NSImage(size: NSSize(width: 200, height: 100), flipped: false) { r in NSColor.systemTeal.setFill(); r.fill(); return true }
        try ImageStore.pngData(img)!.write(to: dir.appendingPathComponent(".assets/a.png"))
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    func testBackspaceAfterImageSelectsThenDeletes() {
        let e = LiveEditor("Intro\n![a](.assets/a.png)\nAfter", baseURL: dir)
        defer { e.close() }
        let after = e.text.distance(of: "After")!
        e.caret(at: after)
        e.tv.deleteBackward(nil)
        XCTAssertEqual(e.text, "Intro\n![a](.assets/a.png)\nAfter", "first Backspace only selects the image")
        XCTAssertEqual(e.tv.selectedRange(), NSRange(location: 6, length: 19))
        e.tv.deleteBackward(nil)
        XCTAssertEqual(e.text, "Intro\nAfter")
    }

    func testCaretNeverRestsOnImageLine() {
        let e = LiveEditor("Intro\n![a](.assets/a.png)\nAfter", baseURL: dir)
        defer { e.close() }
        e.caret(at: 5)
        e.caret(at: 12)  // moving forward into the image line
        XCTAssertEqual(e.tv.selectedRange().location, 26)
        e.caret(at: 10)  // moving back into it
        XCTAssertEqual(e.tv.selectedRange().location, 5)
    }

    func testTypingWithImageSelectedAddsLineBelow() {
        let e = LiveEditor("![a](.assets/a.png)", baseURL: dir)
        defer { e.close() }
        e.tv.setSelectedRange(NSRange(location: 0, length: 19))
        e.type("x")
        XCTAssertEqual(e.text, "![a](.assets/a.png)\nx")
    }

    func testHiddenCodeFenceIsNotTypedInto() {
        let e = LiveEditor("```\ncode\n```\nnext")
        defer { e.close() }
        e.caret(at: 8)       // end of "code"
        e.caret(at: 11)      // the closing fence → next line
        XCTAssertEqual(e.tv.selectedRange().location, 13)
        e.tv.deleteBackward(nil)   // steps back over the fence, doesn't merge
        XCTAssertEqual(e.text, "```\ncode\n```\nnext")
        XCTAssertEqual(e.tv.selectedRange().location, 8)
    }
}

@MainActor
final class TableTests: XCTestCase {
    func testColumnsLineUp() {
        let e = LiveEditor("| a | longer cell |\n| --- | --- |\n| wider text | b |\n")
        defer { e.close() }
        let tv = e.tv
        let lm = tv.layoutManager!
        func pipeX(_ row: Int, _ n: Int) -> CGFloat {
            let ns = e.text as NSString
            var line = 0, idx = 0, count = 0
            for i in 0..<ns.length {
                if line == row, ns.character(at: i) == 124 { if count == n { idx = i; break }; count += 1 }
                if ns.character(at: i) == 10 { line += 1 }
            }
            let g = lm.glyphIndexForCharacter(at: idx)
            return lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil).minX + lm.location(forGlyphAt: g).x
        }
        for n in 0..<3 { XCTAssertEqual(pipeX(0, n), pipeX(2, n), accuracy: 0.5, "pipe \(n)") }
    }

    func testTabAndReturnNavigate() {
        let e = LiveEditor(EditorController.tableSnippet)
        defer { e.close() }
        e.caret(at: 2)
        e.type("Name")
        e.tv.doCommand(by: #selector(NSResponder.insertTab(_:)))
        e.type("Age")
        e.tv.doCommand(by: #selector(NSResponder.insertTab(_:)))
        e.tv.doCommand(by: #selector(NSResponder.insertTab(_:)))
        e.type("Ada")
        XCTAssertEqual(e.text, "| Name | Age |  |\n| --- | --- | --- |\n| Ada |  |  |")
        // Return adds a row; Return in that empty last row ends the table.
        e.tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(e.text, "| Name | Age |  |\n| --- | --- | --- |\n| Ada |  |  |\n|   |   |   |")
        e.tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(e.text, "| Name | Age |  |\n| --- | --- | --- |\n| Ada |  |  |\n")
        e.type("Done")
        XCTAssertEqual(e.text, "| Name | Age |  |\n| --- | --- | --- |\n| Ada |  |  |\nDone")
    }

    func testStructuralEdits() {
        let e = LiveEditor("| a | b |\n| --- | --- |\n| 1 | 2 |")
        defer { e.close() }
        e.tv.editTable(.columnRight, at: 3)
        XCTAssertEqual(e.text, "| a   |     | b   |\n| --- | --- | --- |\n| 1   |     | 2   |")
        e.tv.editTable(.rowBelow, at: e.text.distance(of: "1")!)
        XCTAssertEqual(e.text.components(separatedBy: "\n").count, 4)
        e.tv.editTable(.deleteColumn, at: 2)
        XCTAssertTrue(e.text.hasPrefix("|     | b   |"), e.text)
    }

    func testBackspaceStepsOverPipes() {
        let e = LiveEditor("| a | b |\n| --- | --- |\n| 1 | 2 |")
        defer { e.close() }
        e.caret(at: 5)  // just after the middle pipe
        e.tv.deleteBackward(nil)
        XCTAssertEqual(e.text, "| a | b |\n| --- | --- |\n| 1 | 2 |")
        XCTAssertEqual(e.tv.selectedRange().location, 4)
    }
}

@MainActor
final class CaretTests: XCTestCase {
    func testCaretHeightIsTheTextHeightEverywhere() {
        let e = LiveEditor("Body line\n\nAnother\n\n```\ncode\n```\n")
        defer { e.close() }
        var heights: [CGFloat] = []
        for loc in [3, 10, 13, 26] {
            e.caret(at: loc)
            guard let f = e.tv.caretFrame() else { return XCTFail("no caret at \(loc)") }
            heights.append(f.height)
        }
        let body = heights[0]
        XCTAssertEqual(heights[1], body, accuracy: 0.5, "blank line")
        XCTAssertEqual(heights[2], body, accuracy: 0.5, "text line")
        XCTAssertLessThan(abs(heights[3] - body), body * 0.25, "code line")
    }

    func testOverlayCaretFollowsSelectionInKeyWindow() {
        let e = LiveEditor("First line\n\nThird")
        defer { e.close() }
        e.window.makeKeyAndOrderFront(nil)
        e.window.makeFirstResponder(e.tv)
        e.caret(at: 11)
        e.spin()
        XCTAssertEqual(e.tv.caretOverlay.target, e.tv.caretFrame().map { e.tv.caretOverlay.backingAlignedRect($0, options: .alignAllEdgesNearest) })
        e.tv.setSelectedRange(NSRange(location: 0, length: 5))
        e.spin()
        XCTAssertFalse(e.tv.caretOverlay.isCaretVisible, "no caret over a selection")
    }

    func testInlinePredictionsAreOff() {
        let e = LiveEditor("x")
        defer { e.close() }
        XCTAssertEqual(e.tv.inlinePredictionType, .no)
    }
}

private extension String {
    func distance(of s: String) -> Int? {
        let r = (self as NSString).range(of: s)
        return r.location == NSNotFound ? nil : r.location
    }
}
