import XCTest
import AppKit
@testable import TypeApp

/// The editor is WYSIWYG: Markdown is only the storage format.
@MainActor
final class WysiwygTests: XCTestCase {
    private func attr(_ e: LiveEditor, _ key: NSAttributedString.Key, at i: Int) -> Any? {
        e.tv.textStorage!.attribute(key, at: i, effectiveRange: nil)
    }

    private func isBold(_ e: LiveEditor, at i: Int) -> Bool {
        (attr(e, .font, at: i) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true
    }

    private func isItalic(_ e: LiveEditor, at i: Int) -> Bool {
        (attr(e, .font, at: i) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.italic) == true
    }

    // MARK: Literal typing

    func testTypedPunctuationIsLiteralMidLine() {
        for ch in "#*_~=`[]<>|\\-+" {
            let e = LiveEditor("")
            defer { e.close() }
            e.type("a\(ch)b")
            XCTAssertEqual(e.visible, "a\(ch)b", "mid-line \(ch): \(e.text)")
            let escaped = "*_~=`[]<|\\".contains(ch)
            XCTAssertEqual(e.text, escaped ? "a\\\(ch)b" : "a\(ch)b")
        }
    }

    func testTypedPunctuationIsLiteralAtLineStart() {
        for ch in "#*_~=`[]<>|\\-+" {
            let e = LiveEditor("")
            defer { e.close() }
            e.type("\(ch) x")
            XCTAssertEqual(e.visible, "\(ch) x", "line start \(ch): \(e.text)")
            XCTAssertNil(attr(e, .typeHeading, at: 0))
            XCTAssertNil(attr(e, .typeQuoteBar, at: 0))
            XCTAssertNil(attr(e, .typeGlyph, at: 0))
            XCTAssertNil(attr(e, .typeHiddenPrefix, at: 0))
        }
    }

    func testTypedMarkdownConstructsStayText() {
        for typed in ["# Title", "## Title", "> quote", "- item", "* item", "+ item", "[ ] task", "- [ ] task", "```", "---", "***", "| a | b |", "<!-- c -->", "![x](y.png)", "[l](https://x.y)", "**b**", "~~s~~", "==h==", "`c`"] {
            let e = LiveEditor("")
            defer { e.close() }
            e.type(typed)
            XCTAssertEqual(e.visible, typed, e.text)
            let s = e.tv.textStorage!
            for i in 0..<s.length {
                XCTAssertNil(s.attribute(.typeHeading, at: i, effectiveRange: nil), typed)
                XCTAssertNil(s.attribute(.typeAtomic, at: i, effectiveRange: nil), typed)
                if !typed.contains("http") { XCTAssertNil(s.attribute(.typeLink, at: i, effectiveRange: nil), typed) }
                XCTAssertNil(s.attribute(.typeTaskBox, at: i, effectiveRange: nil), typed)
                XCTAssertNil(s.attribute(.typeCode, at: i, effectiveRange: nil), typed)
                XCTAssertNil(s.attribute(.typeComment, at: i, effectiveRange: nil), typed)
                XCTAssertNil(s.attribute(.strikethroughStyle, at: i, effectiveRange: nil), typed)
                XCTAssertNil(s.attribute(.backgroundColor, at: i, effectiveRange: nil), typed)
            }
        }
    }

    func testNumberFollowedByDotStaysText() {
        for typed in ["7. ", "7) ", "12. x"] {
            let e = LiveEditor("")
            defer { e.close() }
            e.type(typed)
            XCTAssertEqual(e.visible, typed)
            XCTAssertTrue(e.text.contains("\\"), e.text)
            let style = attr(e, .paragraphStyle, at: 0) as? NSParagraphStyle
            XCTAssertEqual(style?.headIndent ?? 0, 0, "not a list: \(e.text)")
            e.type("\nnext")
            XCTAssertEqual(e.visible, typed + "\nnext", "Return does not continue a list")
        }
    }

    func testSlashCreatedListsStillWork() {
        let e = LiveEditor("- one")
        defer { e.close() }
        e.caret(at: 5)
        e.type("\ntwo\n\n")
        XCTAssertEqual(e.text, "- one\n- two\n")
        let n = LiveEditor("1. a\n2. b")
        defer { n.close() }
        n.caret(at: 4)
        n.type("\nnew")
        XCTAssertEqual(n.text, "1. a\n2. new\n3. b")
    }

    func testEscapeInsideCodeIsNotAdded() {
        let e = LiveEditor("`a`")
        defer { e.close() }
        e.caret(at: 2)
        e.type("*_")
        XCTAssertEqual(e.text, "`a*_`")
        let f = LiveEditor("```\ncode\n```")
        defer { f.close() }
        f.caret(at: 8)
        f.type("*")
        XCTAssertEqual(f.text, "```\ncode*\n```")
    }

    func testSmartTypingStillWorksWithEscapes() {
        let e = LiveEditor("") { $0.smartArrows = true; $0.smartDashes = true; $0.autoCapitalize = true }
        defer { e.close() }
        e.type("a -> b")
        XCTAssertEqual(e.text, "A → b")
        let f = LiveEditor("x ") { $0.smartArrows = true }
        defer { f.close() }
        f.caret(at: 2)
        f.type("->")
        XCTAssertEqual(f.text, "x →")
    }

    // MARK: Escapes in the styler

    func testStylerTreatsEscapesAsLiteral() {
        let e = LiveEditor("\\*not italic\\* and \\==x\\== and \\`c\\` and \\[a\\](b)")
        defer { e.close() }
        XCTAssertEqual(e.visible, "*not italic* and ==x== and `c` and [a](b)")
        XCTAssertFalse(isItalic(e, at: 3))
        XCTAssertNil(attr(e, .backgroundColor, at: 20))
        XCTAssertNil(attr(e, .typeLink, at: 40))
    }

    func testEscapedPipeIsNotATableBorder() {
        XCTAssertEqual(MarkdownStyler.pipes(in: "| a \\| b | c |"), [0, 9, 13])
        XCTAssertEqual(MarkdownStyler.pipes(in: "| `a|b` |"), [0, 8])
    }

    func testRealMarkdownStillRenders() {
        let e = LiveEditor("# Title\n\nSome **bold** and *it* and ==hl== and ~~st~~ and `code`.\n\n- item\n")
        defer { e.close() }
        XCTAssertEqual(e.visible, "Title\n\nSome bold and it and hl and st and code.\n\n- item\n".replacingOccurrences(of: "- item", with: "- item"))
        XCTAssertTrue(isBold(e, at: (e.text as NSString).range(of: "bold").location))
    }

    func testBackslashBeforeLetterIsPlain() {
        let e = LiveEditor("C:\\dir and \\n")
        defer { e.close() }
        XCTAssertEqual(e.visible, "C:\\dir and \\n")
    }

    // MARK: Caret, selection, deletion

    func testBackspaceRemovesEscapeWithItsCharacter() {
        let e = LiveEditor("")
        defer { e.close() }
        e.type("a*b")
        XCTAssertEqual(e.text, "a\\*b")
        e.caret(at: 3)
        e.tv.deleteBackward(nil)
        XCTAssertEqual(e.text, "ab")
        e.type("*")
        e.caret(at: 1)
        e.tv.deleteForward(nil)
        XCTAssertEqual(e.text, "ab")
    }

    func testCaretNeverSitsInsideAnEscape() {
        let e = LiveEditor("a\\*b")
        defer { e.close() }
        e.caret(at: 0)
        e.caret(at: 2)
        XCTAssertEqual(e.tv.selectedRange().location, 3, "moving forward hops over the pair")
        e.caret(at: 4)
        e.caret(at: 2)
        XCTAssertEqual(e.tv.selectedRange().location, 1, "moving back hops before it")
        e.tv.setSelectedRange(NSRange(location: 2, length: 1))
        XCTAssertEqual(e.tv.selectedRange(), NSRange(location: 1, length: 2), "selection takes the backslash too")
        e.tv.setSelectedRange(NSRange(location: 0, length: 2))
        XCTAssertEqual(e.tv.selectedRange(), NSRange(location: 0, length: 3))
    }

    func testUndoRemovesEscapedCharacterInOneStep() {
        let e = LiveEditor("")
        defer { e.close() }
        e.tv.allowsUndo = true
        let um = e.tv.undoManager!
        um.groupsByEvent = false
        um.beginUndoGrouping()
        e.type("a")
        um.endUndoGrouping()
        um.beginUndoGrouping()
        e.type("*")
        um.endUndoGrouping()
        XCTAssertEqual(e.text, "a\\*")
        um.undo()
        XCTAssertEqual(e.text, "a")
    }

    // MARK: Typing at the edge of a span

    private func assertEdgeTyping(_ markdown: String, open: String, close: String, check: (LiveEditor, Int) -> Void,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let e = LiveEditor(markdown)
        defer { e.close() }
        e.caret(at: (open as NSString).length + 2)
        e.type(" ")
        XCTAssertEqual(e.text, "\(open)hi\(close) ", "valid after the space: \(e.text)", file: file, line: line)
        XCTAssertEqual(e.visible, "hi ", file: file, line: line)
        e.type("there")
        XCTAssertEqual(e.text, "\(open)hi there\(close)", file: file, line: line)
        XCTAssertEqual(e.visible, "hi there", file: file, line: line)
        check(e, (open as NSString).length + 4)
        e.type(" more")
        XCTAssertEqual(e.text, "\(open)hi there more\(close)", file: file, line: line)
        XCTAssertEqual(e.visible, "hi there more", file: file, line: line)
    }

    func testSpaceAtEndOfHighlightKeepsMarkdownValid() {
        assertEdgeTyping("==hi==", open: "==", close: "==") { e, i in
            for k in 2..<10 { XCTAssertNotNil(self.attr(e, .backgroundColor, at: k), "highlight over \(k)") }
        }
    }

    func testSpaceAtEndOfBoldItalicStrikeCode() {
        assertEdgeTyping("**hi**", open: "**", close: "**") { e, i in
            for k in 2..<10 { XCTAssertTrue(self.isBold(e, at: k)) }
        }
        assertEdgeTyping("*hi*", open: "*", close: "*") { e, i in
            for k in 1..<9 { XCTAssertTrue(self.isItalic(e, at: k)) }
        }
        assertEdgeTyping("~~hi~~", open: "~~", close: "~~") { e, i in
            for k in 2..<10 { XCTAssertNotNil(self.attr(e, .strikethroughStyle, at: k)) }
        }
        assertEdgeTyping("***hi***", open: "***", close: "***") { e, i in
            for k in 3..<11 { XCTAssertTrue(self.isBold(e, at: k) && self.isItalic(e, at: k)) }
        }
    }

    func testSpaceInsideCodeSpanStaysInside() {
        let e = LiveEditor("`hi`")
        defer { e.close() }
        e.caret(at: 3)
        e.type(" there")
        XCTAssertEqual(e.text, "`hi there`")
        XCTAssertEqual(e.visible, "hi there")
        for k in 1..<9 { XCTAssertNotNil(attr(e, .typeCode, at: k)) }
    }

    func testTypingJustAfterClosingMarkersJoinsTheSpan() {
        let e = LiveEditor("==hi== there")
        defer { e.close() }
        e.caret(at: 6)
        e.type("!")
        XCTAssertEqual(e.text, "==hi!== there")
    }

    func testCaretMovedAwayAfterSpaceLeavesSpaceOutside() {
        let e = LiveEditor("==hi== x")
        defer { e.close() }
        e.caret(at: 4)
        e.type(" ")
        XCTAssertEqual(e.text, "==hi==  x")
        e.caret(at: 9)
        e.type("y")
        XCTAssertEqual(e.text, "==hi==  xy")
    }

    func testBoldShortcutWithSpacesInTypedWords() {
        let e = LiveEditor("Hello ")
        defer { e.close() }
        e.caret(at: 6)
        e.controller.bold()
        e.type("big wide world")
        XCTAssertEqual(e.text, "Hello **big wide world**")
        XCTAssertEqual(e.visible, "Hello big wide world")
        e.controller.bold()
        e.type(" plain")
        XCTAssertEqual(e.text, "Hello **big wide world** plain")
    }

    func testBoldShortcutThenSpaceFirst() {
        let e = LiveEditor("")
        defer { e.close() }
        e.controller.bold()
        e.type(" a b")
        XCTAssertEqual(e.text, " **a b**")
    }

    func testReturnAtEndOfSpanLeavesNoDanglingMarkers() {
        for (md, caret) in [("==hi==", 4), ("**hi**", 4), ("*hi*", 3), ("~~hi~~", 4), ("`hi`", 3), ("==hi==", 6)] {
            let e = LiveEditor(md)
            defer { e.close() }
            e.caret(at: caret)
            e.type("\nnext")
            XCTAssertEqual(e.text, md + "\nnext", md)
            XCTAssertEqual(e.visible, "hi\nnext")
        }
    }

    func testReturnInMiddleOfSpanSplitsIt() {
        let e = LiveEditor("==hello==")
        defer { e.close() }
        e.caret(at: 4)
        e.type("\n")
        XCTAssertEqual(e.text, "==he==\n==llo==")
        XCTAssertEqual(e.visible, "he\nllo")
    }

    func testReturnInFormattedListItemKeepsListAndSpan() {
        let e = LiveEditor("- **bold**")
        defer { e.close() }
        e.caret(at: 8)
        e.type("\nx")
        XCTAssertEqual(e.text, "- **bold**\n- x")
    }

    func testBackspacingWholeSpanRemovesMarkers() {
        for (md, caret) in [("==a==", 3), ("**a**", 3), ("*a*", 2), ("~~a~~", 3), ("`a`", 2), ("***a***", 4), ("**==a==**", 5)] {
            let e = LiveEditor("x " + md + " y")
            defer { e.close() }
            e.caret(at: caret + 2)
            e.tv.deleteBackward(nil)
            XCTAssertEqual(e.text, "x  y", md)
        }
        let f = LiveEditor("==abc==")
        defer { f.close() }
        f.tv.setSelectedRange(NSRange(location: 2, length: 3))
        f.tv.deleteBackward(nil)
        XCTAssertEqual(f.text, "")
    }

    func testBackspacingPartOfSpanKeepsIt() {
        let e = LiveEditor("==ab==")
        defer { e.close() }
        e.caret(at: 4)
        e.tv.deleteBackward(nil)
        XCTAssertEqual(e.text, "==a==")
    }

    func testInlineFormatterIgnoresEscapedMarkers() {
        XCTAssertTrue(InlineFormatter.spans(in: "\\*a\\*").isEmpty)
        XCTAssertTrue(InlineFormatter.spans(in: "\\==a\\==").isEmpty)
        XCTAssertEqual(InlineFormatter.spans(in: "**a**").count, 1)
        let e = LiveEditor("a \\*b\\* c")
        defer { e.close() }
        e.select("b")
        e.controller.italic()
        XCTAssertEqual(e.visible, "a *b* c")
        XCTAssertTrue(isItalic(e, at: 4), e.text)
    }

    // MARK: Paste and copy

    private func scratchPasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("com.ajm.type.tests.\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    func testPlainPasteIsLiteral() {
        let e = LiveEditor("")
        defer { e.close() }
        let pb = scratchPasteboard()
        defer { pb.releaseGlobally() }
        pb.setString("**hi** # not heading\n- not list\n7. no\n[a](b)", forType: .string)
        XCTAssertTrue(e.tv.readSelection(from: pb, type: .string))
        XCTAssertEqual(e.visible, "**hi** # not heading\n- not list\n7. no\n[a](b)")
        XCTAssertFalse(isBold(e, at: 3))
        XCTAssertNil(attr(e, .typeGlyph, at: (e.text as NSString).range(of: "not list").location - 3))
    }

    func testCopyPasteRoundTripKeepsFormatting() {
        let source = "# Head\n\n**bold** and ==hl== \\* star\n\n- item"
        let e = LiveEditor(source)
        defer { e.close() }
        e.tv.setSelectedRange(NSRange(location: 0, length: (source as NSString).length))
        let pb = scratchPasteboard()
        defer { pb.releaseGlobally() }
        XCTAssertTrue(e.tv.writeSelection(to: pb, types: e.tv.writablePasteboardTypes))
        XCTAssertEqual(pb.string(forType: TypeTextView.markdownType), source)
        let plain = pb.string(forType: .string) ?? ""
        XCTAssertEqual(plain, "Head\n\nbold and hl * star\n\n• item")
        let f = LiveEditor("")
        defer { f.close() }
        XCTAssertTrue(f.tv.readSelection(from: pb, type: .string))
        XCTAssertEqual(f.text, source)
        XCTAssertTrue(isBold(f, at: (f.text as NSString).range(of: "bold").location))
    }

    func testPasteIntoExistingTextUndoes() {
        let e = LiveEditor("ab")
        defer { e.close() }
        e.caret(at: 1)
        let pb = scratchPasteboard()
        defer { pb.releaseGlobally() }
        pb.setString("*x*", forType: .string)
        _ = e.tv.readSelection(from: pb, type: .string)
        XCTAssertEqual(e.text, "a\\*x\\*b")
    }

    // MARK: Export and counts

    func testExportResolvesEscapes() {
        let html = MarkdownHTML.render("a \\*b\\* \\<i\\> 5\\. x \\# y \\_u\\_ \\| z\n\n\\# not heading\n\n| a \\| b | c |\n|---|---|\n| 1 | 2 |")
        XCTAssertTrue(html.contains("a *b* &lt;i&gt; 5. x # y _u_ | z"), html)
        XCTAssertFalse(html.contains("<em>"), html)
        XCTAssertFalse(html.contains("<h1"), html)
        XCTAssertTrue(html.contains("<th>a | b</th>"), html)
        XCTAssertFalse(html.contains("\\"), html)
        XCTAssertTrue(MarkdownHTML.render("**b** `\\*`").contains("<code>\\*</code>"))
    }

    func testCountsIgnoreEscapeBackslashes() {
        let (stats, _) = DocumentAnalysis.analyze("a \\* b \\# c")
        XCTAssertEqual(stats.words, 3)
        XCTAssertEqual(stats.characters, "a * b # c".count)
        XCTAssertEqual(DocumentAnalysis.plainText("\\*x\\* **y**"), "*x* y")
    }
}

@MainActor
final class LinkLabelTests: XCTestCase {
    func testEmptyLabelLinkShowsAddressWithoutScheme() {
        let e = LiveEditor("see [](https://www.google.com) now")
        defer { e.close() }
        XCTAssertEqual(e.visible, "see www.google.com now")
        let at = (e.text as NSString).range(of: "www").location
        XCTAssertEqual(e.tv.textStorage!.attribute(.typeLink, at: at, effectiveRange: nil) as? String, "https://www.google.com")
        XCTAssertNotNil(e.tv.textStorage!.attribute(.underlineStyle, at: at, effectiveRange: nil))
        e.caret(at: at + 3)
        let target = e.tv.linkTarget()
        XCTAssertTrue(target.isExisting)
        XCTAssertEqual(target.url, "https://www.google.com")
        // Copy shows the address too.
        e.tv.setSelectedRange(NSRange(location: 0, length: (e.text as NSString).length))
        XCTAssertEqual(e.tv.visibleText(in: e.tv.selectedRange()), "see www.google.com now")
    }

    func testEmptyLabelLinkExportAndCounts() {
        let html = MarkdownHTML.render("a [](https://www.google.com) b")
        XCTAssertTrue(html.contains("<a href=\"https://www.google.com\">www.google.com</a>"), html)
        XCTAssertFalse(html.contains("[]"), html)
        XCTAssertEqual(DocumentAnalysis.plainText("a [](https://www.google.com) b"), "a www.google.com b")
    }

    func testPopoverLabelIsLiteral() {
        let e = LiveEditor("x")
        defer { e.close() }
        e.select("x")
        let target = e.tv.linkTarget()
        e.tv.applyLink(target, label: "a*b x]y [z]", url: "example.com")
        XCTAssertEqual(e.text, "[a\\*b x\\]y \\[z\\]](https://example.com)")
        XCTAssertEqual(e.visible, "a*b x]y [z]")
        e.caret(at: 3)
        let again = e.tv.linkTarget()
        XCTAssertTrue(again.isExisting)
        XCTAssertEqual(again.label, "a*b x]y [z]")
        e.tv.applyLink(again, label: again.label, url: again.url)
        XCTAssertEqual(e.text, "[a\\*b x\\]y \\[z\\]](https://example.com)")
        e.tv.removeLink(e.tv.linkTarget())
        XCTAssertEqual(e.visible, "a*b x]y [z]")
    }
}

@MainActor
final class SpanReturnTests: XCTestCase {
    func testReturnInsideSpanContinuesListsQuotesTasksAndNumbers() {
        let cases: [(String, Int, String)] = [
            ("- ==hello==", 6, "- ==he==\n- ==llo=="),
            ("> **hello**", 6, "> **he**\n> **llo**"),
            ("- [ ] ==hello==", 10, "- [ ] ==he==\n- [ ] ==llo=="),
            ("1. *hello*\n2. next", 6, "1. *he*\n2. *llo*\n3. next"),
        ]
        for (md, caret, expected) in cases {
            let e = LiveEditor(md)
            defer { e.close() }
            e.caret(at: caret)
            e.type("\n")
            XCTAssertEqual(e.text, expected, md)
            XCTAssertFalse(e.visible.contains("=") || e.visible.contains("*"), e.visible)
        }
    }
}

@MainActor
final class EditedStructureTests: XCTestCase {
    func testDigitBeforeExistingDotStaysText() {
        let e = LiveEditor(". x")
        defer { e.close() }
        e.caret(at: 0)
        e.type("7")
        XCTAssertEqual(e.text, "7\\. x")
        XCTAssertEqual(e.visible, "7. x")
        XCTAssertEqual((e.tv.textStorage!.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? 0, 0)
    }

    func testDeletingTextBeforeMarkerKeepsItLiteral() {
        for (before, marker) in [("a- b", "- b"), ("a# t", "# t"), ("a> q", "> q"), ("a1. x", "1. x"), ("a* x", "* x"), ("a--- ", "--- ")] {
            let e = LiveEditor(before)
            defer { e.close() }
            e.caret(at: 1)
            e.tv.deleteBackward(nil)
            XCTAssertEqual(e.visible, marker, before)
            XCTAssertNil(e.tv.textStorage!.attribute(.typeHeading, at: 0, effectiveRange: nil), before)
            XCTAssertNil(e.tv.textStorage!.attribute(.typeGlyph, at: 0, effectiveRange: nil), before)
            XCTAssertNil(e.tv.textStorage!.attribute(.typeQuoteBar, at: 0, effectiveRange: nil), before)
            XCTAssertNil(e.tv.textStorage!.attribute(.typeAtomic, at: 0, effectiveRange: nil), before)
        }
    }

    func testJoiningLinesNeverMakesStructure() {
        let e = LiveEditor("a\n- b")
        defer { e.close() }
        e.caret(at: 1)
        e.tv.deleteForward(nil)
        XCTAssertEqual(e.visible, "a- b")
        let f = LiveEditor("x\n\n- item")
        defer { f.close() }
        f.caret(at: 2)
        f.tv.deleteBackward(nil)
        XCTAssertEqual(f.text, "x\n- item", "a real list stays a list")
        XCTAssertNotNil(f.tv.textStorage!.attribute(.typeGlyph, at: 2, effectiveRange: nil))
    }

    func testReturnMidTextNeverStartsStructure() {
        let e = LiveEditor("abc - def")
        defer { e.close() }
        e.caret(at: 4)
        e.type("\n")
        XCTAssertEqual(e.visible, "abc \n- def".replacingOccurrences(of: "abc \n", with: "abc \n"))
        XCTAssertNil(e.tv.textStorage!.attribute(.typeGlyph, at: 5, effectiveRange: nil))
    }

    func testExistingStructureStaysStructural() {
        let e = LiveEditor("# Title\n- item\n> quote")
        defer { e.close() }
        e.caret(at: 3)
        e.type("x")
        e.caret(at: (e.text as NSString).range(of: "item").location + 1)
        e.type("y")
        XCTAssertEqual(e.text, "# Txitle\n- iytem\n> quote")
        XCTAssertNotNil(e.tv.textStorage!.attribute(.typeHeading, at: 0, effectiveRange: nil))
        XCTAssertNotNil(e.tv.textStorage!.attribute(.typeGlyph, at: (e.text as NSString).range(of: "- ").location, effectiveRange: nil))
    }

    func testToolbarStillCreatesStructure() {
        let e = LiveEditor("Title")
        defer { e.close() }
        e.caret(at: 2)
        e.tv.setLinePrefix("## ", kind: .heading)
        XCTAssertEqual(e.text, "## Title")
        XCTAssertNotNil(e.tv.textStorage!.attribute(.typeHeading, at: 0, effectiveRange: nil))
    }

    func testHealingNeverCrashesOnSingleBacktick() {
        let e = LiveEditor("x")
        defer { e.close() }
        XCTAssertNoThrow(e.tv.healed("a ` b **c*** `"))
        XCTAssertNoThrow(e.tv.healed("`"))
        XCTAssertEqual(e.tv.healed("**a***c*"), "__a__*c*")
    }
}

@MainActor
final class TablePipeTests: XCTestCase {
    private let table = "| a | b |\n|---|---|\n| 1 | 2 |"

    func testTypedPipeStaysInsideTheCell() {
        let e = LiveEditor(table)
        defer { e.close() }
        let bordersBefore = MarkdownStyler.pipes(in: "| 1 | 2 |").count
        let ns = e.text as NSString
        e.caret(at: ns.range(of: "1 |").location + 1)
        e.type("|")
        XCTAssertTrue(e.text.hasSuffix("| 1\\| | 2 |"), e.text)
        let row = "| 1\\| | 2 |"
        XCTAssertEqual(MarkdownStyler.pipes(in: row).count, bordersBefore)
        XCTAssertEqual(e.tv.tableCells(in: NSRange(location: ns.range(of: "| 1").location, length: (row as NSString).length)).count, 2)
        XCTAssertTrue(e.visible.contains("1| "), e.visible)
        // The pipe is drawn (not blanked like a border) and Backspace removes it with its backslash.
        let at = (e.text as NSString).range(of: "\\|").location + 1
        XCTAssertNil(e.tv.textStorage!.attribute(.typeGlyph, at: at, effectiveRange: nil))
        e.caret(at: at + 1)
        e.tv.deleteBackward(nil)
        XCTAssertEqual(e.text, table)
    }

    func testPipeInCellExports() {
        let html = MarkdownHTML.render("| a | b |\n|---|---|\n| 1\\| x | 2 |")
        XCTAssertTrue(html.contains("<td>1| x</td><td>2</td>"), html)
    }
}
