import XCTest
import AppKit
@testable import TypeApp

final class SmartTypingTests: XCTestCase {
    private func makeView(_ configure: (inout EditorConfig) -> Void = { _ in }) -> TypeTextView {
        let tv = TypeTextView(usingTextLayoutManager: false)
        tv.isRichText = false
        tv.allowsUndo = true
        var config = AppSettings.shared.editorConfig
        config.smartQuotes = true; config.smartDashes = true; config.smartEllipses = true
        config.smartArrows = true; config.autoCapitalize = false; config.continueLists = true
        config.typingSounds = false; config.focusMode = false; config.typewriterScrolling = false
        configure(&config)
        tv.config = config
        return tv
    }

    private func type(_ text: String, into tv: TypeTextView) {
        for ch in text {
            if ch == "\n" { tv.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
            else { tv.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        }
    }

    func testSmartQuotes() {
        let tv = makeView()
        type("She said \"it's fine\" and 'ok'", into: tv)
        XCTAssertEqual(tv.string, "She said \u{201C}it\u{2019}s fine\u{201D} and \u{2018}ok\u{2019}")
    }

    func testDashesEllipsesArrows() {
        let tv = makeView()
        type("wait-- then... a -> b => c <- d", into: tv)
        XCTAssertEqual(tv.string, "wait\u{2014} then\u{2026} a \u{2192} b \u{21D2} c \u{2190} d")
    }

    func testHorizontalRuleAndCommentsAreNotMangled() {
        let tv = makeView()
        type("---", into: tv)
        XCTAssertEqual(tv.string, "---")
        let tv2 = makeView()
        type("<!--", into: tv2)
        XCTAssertEqual(tv2.string, "<!--")
    }

    func testSmartTypingDisabled() {
        let tv = makeView { $0.smartQuotes = false; $0.smartDashes = false; $0.smartEllipses = false }
        type("\"a\" -- ...", into: tv)
        XCTAssertEqual(tv.string, "\"a\" -- ...")
    }

    func testAutoCapitalize() {
        let tv = makeView { $0.autoCapitalize = true }
        type("hello. world! ok", into: tv)
        XCTAssertEqual(tv.string, "Hello. World! Ok")
    }

    func testBulletListContinuesAndEnds() {
        let tv = makeView()
        type("- one\ntwo\n\n", into: tv)
        XCTAssertEqual(tv.string, "- one\n- two\n")
    }

    func testChecklistContinues() {
        let tv = makeView()
        type("- [x] done\nnext", into: tv)
        XCTAssertEqual(tv.string, "- [x] done\n- [ ] next")
    }

    func testNumberedListRenumbers() {
        let tv = makeView()
        tv.string = "1. a\n2. b"
        tv.setSelectedRange(NSRange(location: 4, length: 0))
        type("\nnew", into: tv)
        XCTAssertEqual(tv.string, "1. a\n2. new\n3. b")
    }

    func testToggleBoldWrapsAndUnwraps() {
        let tv = makeView()
        tv.string = "make this bold"
        tv.setSelectedRange(NSRange(location: 10, length: 4))
        tv.toggleWrap("**")
        XCTAssertEqual(tv.string, "make this **bold**")
        tv.toggleWrap("**")
        XCTAssertEqual(tv.string, "make this bold")
    }

    func testToggleWrapExpandsToWord() {
        let tv = makeView()
        tv.string = "an emphasis here"
        tv.setSelectedRange(NSRange(location: 6, length: 0))
        tv.toggleWrap("*")
        XCTAssertEqual(tv.string, "an *emphasis* here")
    }

    func testHeadingPrefixToggle() {
        let tv = makeView()
        tv.string = "Title"
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        tv.setLinePrefix("## ", kind: .heading)
        XCTAssertEqual(tv.string, "## Title")
        tv.setLinePrefix("# ", kind: .heading)
        XCTAssertEqual(tv.string, "# Title")
        tv.setLinePrefix("# ", kind: .heading)
        XCTAssertEqual(tv.string, "Title")
    }

    func testNumberedPrefixOnMultipleLines() {
        let tv = makeView()
        tv.string = "a\nb\nc"
        tv.setSelectedRange(NSRange(location: 0, length: 5))
        tv.setLinePrefix("1. ", kind: .numbered)
        XCTAssertEqual(tv.string, "1. a\n2. b\n3. c")
    }
}

final class AnalysisTests: XCTestCase {
    func testWordCountIgnoresSyntaxAndComments() {
        let md = """
        # Hello World

        This is **bold** and *italic* text. <!-- not counted at all -->

        - [ ] one item
        > quoted words
        """
        let (stats, outline) = DocumentAnalysis.analyze(md)
        XCTAssertEqual(stats.words, 12)
        XCTAssertEqual(outline.map(\.title), ["Hello World"])
        XCTAssertEqual(stats.readingMinutes(wordsPerMinute: 270), 1)
    }

    func testHeadingsInsideCodeAreNotOutline() {
        let md = "# Real\n\n```\n# not a heading\n```\n\n## Second"
        let (_, outline) = DocumentAnalysis.analyze(md)
        XCTAssertEqual(outline.map(\.title), ["Real", "Second"])
        XCTAssertEqual(outline.map(\.level), [1, 2])
    }

    func testBlockScan() {
        let ns = "a\n```\ncode\n```\nb <!-- c -->\n```\nunclosed" as NSString
        let blocks = MarkdownStyler.scanBlocks(ns)
        XCTAssertEqual(blocks.code.count, 2)
        XCTAssertEqual(blocks.comments.count, 1)
        XCTAssertEqual(NSMaxRange(blocks.code[1]), ns.length)
    }

    func testEmptyFence() {
        let ns = "```\n```\nafter" as NSString
        let blocks = MarkdownStyler.scanBlocks(ns)
        XCTAssertEqual(blocks.code.count, 1)
        XCTAssertEqual(ns.substring(with: blocks.code[0]), "```\n```")
    }

    func testPlainText() {
        XCTAssertEqual(DocumentAnalysis.plainText("# Title\n- **a** [link](http://x)\n<!-- hide -->"), "Title\n• a link\n")
    }
}

final class HTMLTests: XCTestCase {
    func testBlocks() {
        let html = MarkdownHTML.render("""
        # Title

        Para with **bold**, `code <x>` and [link](https://a.b).

        - one
          - nested
        - [x] done

        1. first

        > quote

        | A | B |
        |---|--:|
        | 1 | 2 |

        ```swift
        let x = 1 < 2
        ```
        """)
        XCTAssertTrue(html.contains("<h1 id=\"title\">Title</h1>"))
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<code>code &lt;x&gt;</code>"))
        XCTAssertTrue(html.contains("<a href=\"https://a.b\">link</a>"))
        XCTAssertTrue(html.contains("<ul>\n<li>one\n<ul>\n<li>nested</li>"))
        XCTAssertTrue(html.contains("<input type=\"checkbox\" disabled checked>"))
        XCTAssertTrue(html.contains("<ol>\n<li>first</li>"))
        XCTAssertTrue(html.contains("<blockquote>\n<p>quote</p>"))
        XCTAssertTrue(html.contains("<th style=\"text-align:right\">B</th>"))
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\">let x = 1 &lt; 2</code></pre>"))
    }

    func testCommentsRemoved() {
        XCTAssertFalse(MarkdownHTML.render("a <!-- secret --> b").contains("secret"))
    }
}

@MainActor
final class ExportTests: XCTestCase {
    private let md = "# Heading\n\nSome **bold** and *italic* words.\n\n- item one\n- item two\n"

    private func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }

    func testAllFormatsWrite() throws {
        for format in ExportFormat.allCases {
            let url = tempURL(format.fileExtension)
            try Exporter.write(markdown: md, title: "Test", baseURL: nil, format: format, fontChoice: .serif, customFamily: "", to: url)
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            XCTAssertGreaterThan(size, 20, "\(format) export is empty")
        }
    }

    func testWordRoundTrip() throws {
        let url = tempURL("docx")
        try Exporter.write(markdown: md, title: "Test", baseURL: nil, format: .word, fontChoice: .serif, customFamily: "", to: url)
        let back = try RichTextImporter.markdown(from: Data(contentsOf: url), type: .officeOpenXML)
        XCTAssertTrue(back.contains("# Heading"), back)
        XCTAssertTrue(back.contains("**bold**"), back)
        XCTAssertTrue(back.contains("*italic*"), back)
        XCTAssertTrue(back.contains("- item one"), back)
    }

    func testRTFRoundTrip() throws {
        let url = tempURL("rtf")
        try Exporter.write(markdown: md, title: "Test", baseURL: nil, format: .rtf, fontChoice: .sans, customFamily: "", to: url)
        let back = try RichTextImporter.markdown(from: Data(contentsOf: url), type: .rtf)
        XCTAssertTrue(back.contains("**bold**"), back)
        XCTAssertTrue(back.contains("item two"), back)
    }
}
