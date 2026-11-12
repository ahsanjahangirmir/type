import XCTest
import SwiftUI
@testable import TypeApp

/// `/` over a selection opens the Format menu instead of replacing the text.
@MainActor
final class FormatMenuTests: XCTestCase {
    private func open(_ e: LiveEditor, selecting s: String) {
        e.select(s)
        e.tv.insertText("/", replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func titles(_ e: LiveEditor) -> [String] { e.controller.filteredSlashCommands.map(\.title) }

    private func press(_ e: LiveEditor, _ selector: Selector) { e.tv.doCommand(by: selector) }

    func testSlashOverSelectionOpensFormatMenuAndKeepsText() {
        let e = LiveEditor("Hello brave world\n")
        defer { e.close() }
        open(e, selecting: "brave")
        XCTAssertEqual(e.text, "Hello brave world\n")
        XCTAssertEqual(e.tv.selectedRange(), (e.text as NSString).range(of: "brave"))
        XCTAssertNotNil(e.controller.slash?.format)
        XCTAssertEqual(titles(e), ["Text", "Bold", "Italic", "Strikethrough", "Highlight", "Inline Code", "Link…",
                                   "Heading 1", "Heading 2", "Heading 3", "Quote", "Bulleted List", "Numbered List", "Checklist"])
    }

    func testTypingFiltersWithoutTouchingDocument() {
        let e = LiveEditor("Hello brave world\n")
        defer { e.close() }
        open(e, selecting: "brave")
        e.type("bo")
        XCTAssertEqual(e.text, "Hello brave world\n")
        XCTAssertEqual(titles(e), ["Bold"])
        XCTAssertEqual(e.tv.selectedRange(), (e.text as NSString).range(of: "brave"))
    }

    func testBackspaceEditsFilterThenClosesKeepingSelection() {
        let e = LiveEditor("Hello brave world\n")
        defer { e.close() }
        open(e, selecting: "brave")
        e.type("bo")
        press(e, #selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(e.controller.slash?.query, "b")
        press(e, #selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(e.controller.slash?.query, "")
        XCTAssertNotNil(e.controller.slash)
        press(e, #selector(NSResponder.deleteBackward(_:)))
        XCTAssertNil(e.controller.slash)
        XCTAssertEqual(e.text, "Hello brave world\n")
        XCTAssertEqual(e.tv.selectedRange(), (e.text as NSString).range(of: "brave"))
    }

    func testReturnAppliesBoldAndKeepsSelection() {
        let e = LiveEditor("Hello brave world\n")
        defer { e.close() }
        open(e, selecting: "brave")
        e.type("bo")
        press(e, #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(e.text, "Hello **brave** world\n")
        XCTAssertNil(e.controller.slash)
        XCTAssertEqual((e.text as NSString).substring(with: e.tv.selectedRange()), "brave")
        // Still selected, so another format stacks.
        open(e, selecting: "brave")
        e.type("ita")
        press(e, #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(e.text, "Hello **_brave_** world\n")
    }

    func testArrowsMoveAndEscapeClosesWithoutChange() {
        let e = LiveEditor("Hello brave world\n")
        defer { e.close() }
        open(e, selecting: "brave")
        press(e, #selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(e.controller.slash?.selection, 1)
        press(e, #selector(NSResponder.moveUp(_:)))
        press(e, #selector(NSResponder.moveUp(_:)))
        XCTAssertEqual(e.controller.slash?.selection, Self.count - 1)
        press(e, #selector(NSResponder.cancelOperation(_:)))
        XCTAssertNil(e.controller.slash)
        XCTAssertEqual(e.text, "Hello brave world\n")
        XCTAssertEqual(e.tv.selectedRange(), (e.text as NSString).range(of: "brave"))
    }
    private static var count: Int { EditorController.formatCommands.count }

    func testTextStripsInlineFormatsAndHeading() {
        let e = LiveEditor("## A **bold** and *it* line\nplain\n")
        defer { e.close() }
        e.tv.setSelectedRange(NSRange(location: 0, length: (e.text as NSString).range(of: "line").upperBound))
        e.tv.insertText("/", replacementRange: NSRange(location: NSNotFound, length: 0))
        e.type("text")
        press(e, #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(e.text, "A bold and it line\nplain\n")
    }

    func testTextOnPartlyFormattedSelectionRemovesIt() {
        let e = LiveEditor("> a **b** c\n")
        defer { e.close() }
        e.select("a **b")
        e.tv.insertText("/", replacementRange: NSRange(location: NSNotFound, length: 0))
        e.type("text")
        press(e, #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(e.text, "a b c\n")
    }

    func testActiveStateChecksFormatsTheWholeSelectionHas() {
        let e = LiveEditor("Hello **brave** new world\n")
        defer { e.close() }
        let bold = EditorController.formatCommands.first { $0.id == "bold" }!
        let italic = EditorController.formatCommands.first { $0.id == "italic" }!
        open(e, selecting: "brave")
        XCTAssertTrue(e.controller.isActive(bold))
        XCTAssertFalse(e.controller.isActive(italic))
        e.controller.cancelSlash()
        e.select("brave** new")
        e.tv.insertText("/", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(e.controller.isActive(bold), "only part of the selection is bold")
        // Choosing an active format removes it.
        e.controller.cancelSlash()
        open(e, selecting: "brave")
        e.type("bo")
        press(e, #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(e.text, "Hello brave new world\n")
    }

    func testBlockItemsApplyToSelectedLinesAndKeepThemSelected() {
        let e = LiveEditor("one\ntwo\nthree\n")
        defer { e.close() }
        e.tv.setSelectedRange(NSRange(location: 0, length: 7))
        e.tv.insertText("/", replacementRange: NSRange(location: NSNotFound, length: 0))
        e.type("check")
        press(e, #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(e.text, "- [ ] one\n- [ ] two\nthree\n")
        XCTAssertEqual((e.text as NSString).substring(with: e.tv.selectedRange()), "- [ ] one\n- [ ] two")
    }

    func testClickingAnItemApplies() {
        let e = LiveEditor("Hello brave world\n")
        defer { e.close() }
        open(e, selecting: "brave")
        e.controller.runSlash(e.controller.filteredSlashCommands.first { $0.id == "h2" }!)
        XCTAssertEqual(e.text, "## Hello brave world\n")
        XCTAssertNil(e.controller.slash)
    }

    func testSelectionChangeClosesMenu() {
        let e = LiveEditor("Hello brave world\n")
        defer { e.close() }
        open(e, selecting: "brave")
        e.caret(at: 2)
        e.spin()
        XCTAssertNil(e.controller.slash)
        XCTAssertEqual(e.text, "Hello brave world\n")
    }

    func testNeverOpensInCodeImageOrTableRule() {
        for (md, pick) in [("```\nlet x = 1\n```\n", "let x"), ("![alt](a.png)\n", "alt"), ("| a | b |\n| --- | --- |\n| c | d |\n", "---")] {
            let e = LiveEditor(md)
            open(e, selecting: pick)
            XCTAssertNil(e.controller.slash, md)
            XCTAssertEqual(e.text, md, "the selection is not replaced")
            e.close()
        }
    }

    func testEmptySelectionSlashStillOpensInsertMenu() {
        let e = LiveEditor("\n")
        defer { e.close() }
        e.caret(at: 0)
        e.type("/")
        XCTAssertEqual(e.text, "/\n")
        XCTAssertNil(e.controller.slash?.format)
        XCTAssertEqual(e.controller.slash?.anchor, 0)
        e.type("tab")
        e.spin()
        XCTAssertEqual(titles(e), ["Table"])
        e.type("zzzz")
        e.spin()
        XCTAssertNil(e.controller.slash)
    }

    func testInsertMenuFilterUnchanged() {
        let e = LiveEditor("\n")
        defer { e.close() }
        e.caret(at: 0)
        e.type("/he")
        e.spin()
        XCTAssertEqual(titles(e), ["Heading 1", "Heading 2", "Heading 3", "Checklist"])
        press(e, #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(e.text, "# \n")
    }

    func testUndoRevertsAppliedFormatInOneStep() {
        let e = LiveEditor("Hello **brave** *x* world\n")
        defer { e.close() }
        e.window.makeFirstResponder(e.tv)
        let original = e.text
        e.tv.setSelectedRange(NSRange(location: 0, length: (e.text as NSString).range(of: "world").upperBound))
        e.tv.insertText("/", replacementRange: NSRange(location: NSNotFound, length: 0))
        e.type("text")
        press(e, #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(e.text, "Hello brave x world\n")
        e.tv.undoManager?.undo()
        XCTAssertEqual(e.text, original)
    }

    func testRenderMenuLightAndDark() throws {
        guard let dir = ProcessInfo.processInfo.environment["TYPE_SNAPSHOT_DIR"].map({ URL(fileURLWithPath: $0) }) else { throw XCTSkip("no snapshot dir") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let e = LiveEditor("Hello **brave** new world\n")
        defer { e.close() }
        open(e, selecting: "brave")
        guard let state = e.controller.slash else { return XCTFail("menu closed") }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: SlashMenu(controller: e.controller, state: state).padding(24)
                .background(name == "dark" ? Color(white: 0.12) : Color(white: 0.97)))
            let size = NSSize(width: SlashMenu.width + 48, height: SlashMenu.height(for: 14) + 48)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.layoutIfNeeded()
            e.spin(0.3)
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("format-menu-\(name).png"))
            window.close()
        }
    }
}
