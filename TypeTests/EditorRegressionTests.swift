import XCTest
@testable import TypeApp

@MainActor
final class ListSpacingTests: XCTestCase {
    private func spacing(_ e: LiveEditor, line: String) -> CGFloat {
        let loc = (e.text as NSString).range(of: line).location
        return (e.tv.textStorage!.attribute(.paragraphStyle, at: loc, effectiveRange: nil) as! NSParagraphStyle).paragraphSpacing
    }

    func testItemsOfOneListSitTogether() {
        let e = LiveEditor("- one\n- two\n\nAfter", configure: { $0.paragraphSpacing = true })
        defer { e.close() }
        XCTAssertLessThan(spacing(e, line: "- one"), spacing(e, line: "- two"), "gap only after the last item")
        XCTAssertEqual(spacing(e, line: "- two"), 8)
    }

    func testReturnInListTightensThePreviousItem() {
        let e = LiveEditor("- one", configure: { $0.paragraphSpacing = true; $0.continueLists = true })
        defer { e.close() }
        e.caret(at: 5)
        e.type("\ntwo")
        XCTAssertEqual(e.text, "- one\n- two")
        XCTAssertLessThan(spacing(e, line: "- one"), spacing(e, line: "- two"))
    }
}

@MainActor
final class ComposedCharacterTests: XCTestCase {
    /// NSString and Swift disagree on clusters around a ZWJ; typing after one used to crash.
    func testTypingAfterZeroWidthJoinerDoesNotCrash() {
        let e = LiveEditor("a\u{200D}x", configure: { $0.smartQuotes = true; $0.autoCapitalize = true; $0.smartDashes = true })
        defer { e.close() }
        e.caret(at: (e.text as NSString).length)
        e.type("y")
        e.caret(at: 2)
        e.type("z")
        XCTAssertTrue(e.text.contains("y"))
    }
}
