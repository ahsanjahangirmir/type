import XCTest
import SwiftUI
@testable import TypeApp

/// Tables (hidden-syntax grid, ragged rows, structural edits) and atomic image lines (selection, deletion).
@MainActor
final class TableAndImageTests: XCTestCase {
    private func focused(_ c: inout EditorConfig) { c.focusMode = true; c.focusOpacity = 0.19 }

    private func imageDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("type-table-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".assets"), withIntermediateDirectories: true)
        let img = NSImage(size: NSSize(width: 200, height: 100), flipped: false) { r in NSColor.systemTeal.setFill(); r.fill(); return true }
        try ImageStore.pngData(img)!.write(to: dir.appendingPathComponent(".assets/shot.png"))
        return dir
    }

    private let irregular = "| A | B | C |\n| --- | --- | --- |\n| one |\n| x | y | z | w |\n|   |   |\n\nafter"

    private func columnCounts(_ e: LiveEditor) -> [Int] {
        guard let table = e.tv.tableContext(at: 2) else { return [] }
        return table.rows.enumerated().filter { $0.offset != 1 }.map { e.tv.tableCells(in: $0.element).count }
    }

    // MARK: Pipes

    func testHiddenPipesAreBlankGlyphsEvenWhenDimmed() {
        let e = LiveEditor("intro\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\nlast line", configure: focused)
        defer { e.close() }
        e.caret(at: (e.text as NSString).range(of: "last").location)
        e.spin()
        let ns = e.text as NSString
        let lm = e.tv.layoutManager!
        let pipeIndex = ns.range(of: "| A").location
        // Focus dimming paints this line with a temporary colour; the pipe must still be a blank glyph.
        XCTAssertNotNil(lm.temporaryAttribute(.foregroundColor, atCharacterIndex: pipeIndex, effectiveRange: nil))
        let font = e.tv.textStorage!.attribute(.font, at: pipeIndex, effectiveRange: nil) as! NSFont
        var space: CGGlyph = 0, bar: CGGlyph = 0
        var sp: UniChar = 32, pi: UniChar = 124
        CTFontGetGlyphsForCharacters(font as CTFont, &sp, &space, 1)
        CTFontGetGlyphsForCharacters(font as CTFont, &pi, &bar, 1)
        let glyph = lm.cgGlyph(at: lm.glyphIndexForCharacter(at: pipeIndex))
        XCTAssertEqual(glyph, space)
        XCTAssertNotEqual(glyph, bar)
        // And the pipe keeps the advance of a real pipe so the grid stays aligned.
        let next = lm.location(forGlyphAt: lm.glyphIndexForCharacter(at: pipeIndex + 1)).x - lm.location(forGlyphAt: lm.glyphIndexForCharacter(at: pipeIndex)).x
        XCTAssertGreaterThan(next, ("|" as NSString).size(withAttributes: [.font: font]).width)
    }

    // MARK: Ragged rows

    func testRaggedRowsShareColumnPositions() {
        let e = LiveEditor(irregular, configure: focused)
        defer { e.close() }
        let ns = e.text as NSString
        let lm = e.tv.layoutManager!
        func pipeXs(_ rowStart: String) -> [CGFloat] {
            let line = e.tv.contentLineRange(at: ns.range(of: rowStart).location)
            return MarkdownStyler.pipes(in: ns.substring(with: line)).map {
                let g = lm.glyphIndexForCharacter(at: line.location + $0)
                return lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil).minX + lm.location(forGlyphAt: g).x
            }
        }
        let wide = pipeXs("| x | y")
        XCTAssertEqual(wide.count, 5)
        // Every row's borders sit on the widest row's columns, as far as it has them.
        XCTAssertEqual(pipeXs("| A |"), Array(wide.prefix(4)))
        XCTAssertEqual(Array(pipeXs("| one |").prefix(2)), Array(wide.prefix(2)))
        XCTAssertEqual(pipeXs("|   |   |"), Array(wide.prefix(3)))
    }

    func testRaggedTableGridSpansWidestRow() throws {
        let e = LiveEditor(irregular, configure: focused)
        defer { e.close() }
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 400, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        e.tv.cacheDisplay(in: NSRect(x: 0, y: 0, width: 800, height: 400), to: image)
        // No crash and the table block is found as one block with every row.
        XCTAssertEqual(e.tv.tableContext(at: 2)?.rows.count, 5)
    }

    // MARK: Edits

    func testEveryTableEditYieldsConsistentColumns() {
        let edits: [TypeTextView.TableEdit] = [.rowAbove, .rowBelow, .columnLeft, .columnRight, .deleteRow, .deleteColumn]
        for edit in edits {
            for probe in ["| one |", "| x | y", "| A |"] {
                let e = LiveEditor(irregular, configure: focused)
                defer { e.close() }
                let original = e.text
                let loc = (e.text as NSString).range(of: probe).location + 3
                e.tv.editTable(edit, at: loc)
                if e.text == original { XCTAssertTrue(edit == .deleteRow && probe == "| A |", "\(edit) at \(probe) did nothing"); continue }
                let counts = columnCounts(e)
                XCTAssertEqual(Set(counts).count, 1, "\(edit) at \(probe): \(counts)\n\(e.text)")
                e.tv.undoManager?.undo()
                XCTAssertEqual(e.text, original, "undo of \(edit) at \(probe)")
            }
        }
    }

    func testTabAndReturnAppendFullWidthRows() {
        let e = LiveEditor(irregular, configure: focused)
        defer { e.close() }
        let ns = e.text as NSString
        e.caret(at: ns.range(of: "|   |   |").location + 7)
        XCTAssertTrue(e.tv.moveToTableCell(forward: true))
        let rows = e.tv.tableContext(at: 2)!.rows
        let last = e.tv.tableCells(in: rows.last!).count
        XCTAssertGreaterThanOrEqual(last, 4, "a new row is as wide as the widest row")
    }

    // MARK: Atomic selection

    private func imageEditor() throws -> LiveEditor {
        let e = LiveEditor("intro line\n![shot](.assets/shot.png)\nafter the image", baseURL: try imageDir(), configure: focused)
        e.spin()
        return e
    }

    func testShiftUpFromBelowSelectsWholeImageAndDeleteLeavesNoSyntax() throws {
        let e = try imageEditor()
        defer { e.close() }
        let ns = e.text as NSString
        e.caret(at: ns.range(of: "after").location + 3)
        e.tv.doCommand(by: #selector(NSResponder.moveUpAndModifySelection(_:)))
        e.tv.doCommand(by: #selector(NSResponder.moveUpAndModifySelection(_:)))
        let image = ns.range(of: "![shot](.assets/shot.png)")
        XCTAssertLessThanOrEqual(e.tv.selectedRange().location, image.location, "selection reaches the image line start")
        XCTAssertGreaterThanOrEqual(NSMaxRange(e.tv.selectedRange()), NSMaxRange(image))
        e.tv.deleteBackward(nil)
        XCTAssertFalse(e.text.contains("!["), e.text)
        XCTAssertFalse(e.text.contains(".assets"), e.text)
        XCTAssertFalse(e.text.contains("shot"), e.text)
        XCTAssertTrue(e.text.hasPrefix("int"))
        XCTAssertTrue(e.text.hasSuffix("the image"))
    }

    func testPartialSelectionsAreExpandedOverAtomicLines() throws {
        let e = try imageEditor()
        defer { e.close() }
        let ns = e.text as NSString
        let image = ns.range(of: "![shot](.assets/shot.png)")
        e.tv.setSelectedRange(NSRange(location: image.location + 5, length: 6))
        XCTAssertEqual(e.tv.selectedRange(), image, "inside the line")
        e.tv.setSelectedRange(NSRange(location: 2, length: image.location + 4 - 2))
        XCTAssertEqual(e.tv.selectedRange(), NSRange(location: 2, length: NSMaxRange(image) - 2), "ending inside the line")
        // Touching the boundaries only is left alone.
        let before = NSRange(location: 0, length: image.location)
        e.tv.setSelectedRange(before)
        XCTAssertEqual(e.tv.selectedRange(), before)
        let after = NSRange(location: NSMaxRange(image) + 1, length: 5)
        e.tv.setSelectedRange(after)
        XCTAssertEqual(e.tv.selectedRange(), after)
    }

    func testShiftDownAndShiftLeftIntoImage() throws {
        let e = try imageEditor()
        defer { e.close() }
        let ns = e.text as NSString
        let image = ns.range(of: "![shot](.assets/shot.png)")
        e.caret(at: 4)
        e.tv.doCommand(by: #selector(NSResponder.moveDownAndModifySelection(_:)))
        XCTAssertGreaterThanOrEqual(NSMaxRange(e.tv.selectedRange()), NSMaxRange(image))
        e.tv.deleteBackward(nil)
        XCTAssertFalse(e.text.contains("!["), e.text)
        // Shift-left from the start of the line below, twice (over the newline, into the line).
        let f = try imageEditor()
        defer { f.close() }
        f.caret(at: (f.text as NSString).range(of: "after").location)
        f.tv.doCommand(by: #selector(NSResponder.moveLeftAndModifySelection(_:)))
        f.tv.doCommand(by: #selector(NSResponder.moveLeftAndModifySelection(_:)))
        f.tv.deleteBackward(nil)
        XCTAssertFalse(f.text.contains("!["), f.text)
        XCTAssertFalse(f.text.contains(")"), f.text)
    }

    func testSelectAllDeleteAndEdgeImages() throws {
        let dir = try imageDir()
        let e = LiveEditor("![shot](.assets/shot.png)\n![shot](.assets/shot.png)", baseURL: dir, configure: focused)
        defer { e.close() }
        e.spin()
        e.tv.selectAll(nil)
        e.tv.deleteBackward(nil)
        XCTAssertEqual(e.text, "")
        let f = LiveEditor("![shot](.assets/shot.png)\ntext", baseURL: dir, configure: focused)
        defer { f.close() }
        f.spin()
        f.tv.setSelectedRange(NSRange(location: 0, length: 27))
        f.tv.deleteBackward(nil)
        XCTAssertEqual(f.text, "ext", "selection reaching into the next line only expands over the image line")
    }

    // MARK: Selection highlight

    func testNoSelectionHighlightBehindSelectedImage() throws {
        let dir = try imageDir()
        let e = LiveEditor("intro\n![shot](.assets/shot.png \"width=100\")\nafter", baseURL: dir, configure: focused)
        defer { e.close() }
        e.spin()
        e.tv.layoutImageViews()
        let ns = e.text as NSString
        e.tv.setSelectedRange(NSRange(location: ns.range(of: "![shot]").location + 3, length: 0))
        e.tv.setSelectedRange(ns.range(of: "![shot](.assets/shot.png \"width=100\")"))
        let lm = e.tv.layoutManager!
        let frag = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: ns.range(of: "![shot]").location), effectiveRange: nil)
        let bounds = e.tv.bounds
        let rep = e.tv.bitmapImageRepForCachingDisplay(in: bounds)!
        e.tv.cacheDisplay(in: bounds, to: rep)
        let x = Int(bounds.width - 40) , y = Int(frag.midY + e.tv.textContainerOrigin.y)
        let inside = rep.colorAt(x: x, y: y)!
        let blank = rep.colorAt(x: x, y: Int(bounds.height - 4))!
        XCTAssertEqual(inside.alphaComponent, blank.alphaComponent, accuracy: 0.01, "selection highlight painted beside the image")
    }
}
