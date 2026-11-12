import AppKit

/// Table editing: Tab / ⇧Tab move between cells, Return adds a row (or ends
/// the table from an empty last row), and the context menu adds or removes
/// rows and columns. The Markdown stays a plain pipe table.
extension TypeTextView {
    struct TableContext {
        /// The table's lines, without the final newline.
        var block: NSRange
        /// Every line (no newlines); index 1 is the `---` divider.
        var rows: [NSRange]
        static let divider = 1
    }

    enum TableEdit {
        case rowAbove, rowBelow, columnLeft, columnRight, deleteRow, deleteColumn, deleteTable
    }

    /// The table containing `location`, if any.
    func tableContext(at location: Int) -> TableContext? {
        guard let s = textStorage, s.length > 0 else { return nil }
        let ns = string as NSString
        var value: NSValue?
        for i in [location, location - 1] where i >= 0 && i < s.length {
            if let v = s.attribute(.typeTable, at: i, effectiveRange: nil) as? NSValue { value = v; break }
        }
        guard let block = value?.rangeValue, NSMaxRange(block) <= ns.length,
              location >= block.location, location <= NSMaxRange(block) else { return nil }
        var rows: [NSRange] = []
        var loc = block.location
        while loc <= NSMaxRange(block) {
            let line = contentLineRange(at: loc)
            rows.append(line)
            let next = NSMaxRange(ns.lineRange(for: NSRange(location: loc, length: 0)))
            if NSMaxRange(line) >= NSMaxRange(block) || next <= loc { break }
            loc = next
        }
        guard rows.count >= 2 else { return nil }
        return TableContext(block: block, rows: rows)
    }

    /// Each cell of a row: the space between two pipes, and its trimmed text
    /// (an empty cell's text is a caret position inside it).
    func tableCells(in row: NSRange) -> [(segment: NSRange, content: NSRange)] {
        let ns = string as NSString
        let text = ns.substring(with: row) as NSString
        let pipes = MarkdownStyler.pipes(in: text as String)
        var cells: [(NSRange, NSRange)] = []
        for (n, p) in pipes.enumerated() {
            let end = n + 1 < pipes.count ? pipes[n + 1] : text.length
            guard end > p + 1 || n + 1 < pipes.count else { continue }
            var a = p + 1, b = end
            while a < b, text.character(at: a) == 32 || text.character(at: a) == 9 { a += 1 }
            while b > a, text.character(at: b - 1) == 32 || text.character(at: b - 1) == 9 { b -= 1 }
            let segment = NSRange(location: row.location + p + 1, length: end - p - 1)
            let content = a == b
                ? NSRange(location: segment.location + min(1, segment.length), length: 0)
                : NSRange(location: row.location + a, length: b - a)
            cells.append((segment, content))
        }
        return cells
    }

    private func rowIndex(in table: TableContext, at location: Int) -> Int? {
        table.rows.firstIndex { location >= $0.location && location <= NSMaxRange($0) }
    }

    /// Tab / ⇧Tab: select the next or previous cell; Tab past the last cell adds a row.
    func moveToTableCell(forward: Bool) -> Bool {
        let sel = selectedRange()
        guard let table = tableContext(at: sel.location) else { return false }
        var cells: [NSRange] = []
        var current: Int?
        for (i, row) in table.rows.enumerated() where i != TableContext.divider {
            for cell in tableCells(in: row) {
                if current == nil, sel.location >= cell.segment.location, sel.location <= NSMaxRange(cell.segment) { current = cells.count }
                cells.append(cell.content)
            }
        }
        guard let current else { return false }
        let next = current + (forward ? 1 : -1)
        if next < 0 { return true }
        if next >= cells.count {
            appendTableRow(after: table.rows.count - 1, in: table)
            return true
        }
        let target = cells[next]
        setSelectedRange(target.length > 0 ? target : NSRange(location: target.location, length: 0))
        return true
    }

    /// Return in a table adds an empty row below; Return in an empty last row ends the table.
    func insertTableRowOnNewline() -> Bool {
        let sel = selectedRange()
        guard sel.length == 0, let table = tableContext(at: sel.location), let index = rowIndex(in: table, at: sel.location) else { return false }
        let row = table.rows[index]
        let empty = tableCells(in: row).allSatisfy { $0.content.length == 0 }
        if empty, index == table.rows.count - 1, index > TableContext.divider {
            replace(row, with: "", caret: row.location)
            return true
        }
        appendTableRow(after: max(index, TableContext.divider), in: table)
        return true
    }

    private func appendTableRow(after index: Int, in table: TableContext) {
        let columns = max(1, tableCells(in: table.rows[0]).count)
        let row = "|" + String(repeating: "   |", count: columns)
        let at = NSMaxRange(table.rows[index])
        replace(NSRange(location: at, length: 0), with: "\n" + row, caret: at + 3)
    }

    /// Backspace / Delete next to a cell border moves over it instead of
    /// deleting it (which would merge two cells and break the columns).
    func stepOverTablePipe(backward: Bool, at location: Int) -> Bool {
        let ns = string as NSString
        let i = backward ? location - 1 : location
        guard i >= 0, i < ns.length, ns.character(at: i) == 124, let table = tableContext(at: location) else { return false }
        guard table.rows.contains(where: { NSLocationInRange(i, $0) }) else { return false }
        setSelectedRange(NSRange(location: backward ? i : i + 1, length: 0))
        return true
    }

    // MARK: Structure

    /// Adds or removes rows and columns, rewriting the table with tidy, aligned source.
    func editTable(_ edit: TableEdit, at location: Int) {
        guard let table = tableContext(at: location), let index = rowIndex(in: table, at: location) else { return }
        let ns = string as NSString
        var matrix = table.rows.enumerated().filter { $0.offset != TableContext.divider }.map { _, row in
            tableCells(in: row).map { ns.substring(with: $0.content) }
        }
        let alignments = tableCells(in: table.rows[TableContext.divider]).map { cell -> String in
            let t = ns.substring(with: cell.content)
            return t.hasPrefix(":") && t.hasSuffix(":") ? "c" : t.hasSuffix(":") ? "r" : t.hasPrefix(":") ? "l" : ""
        }
        var aligns = alignments
        let columns = max(matrix.map(\.count).max() ?? 1, 1)
        matrix = matrix.map { $0 + Array(repeating: "", count: columns - $0.count) }
        aligns += Array(repeating: "", count: max(0, columns - aligns.count))
        var r = index == 0 ? 0 : max(0, index - 1)
        var c = tableCells(in: table.rows[index]).firstIndex { location >= $0.segment.location && location <= NSMaxRange($0.segment) } ?? 0
        c = min(c, columns - 1)

        switch edit {
        case .rowAbove:
            r = max(1, r)
            matrix.insert(Array(repeating: "", count: columns), at: r)
        case .rowBelow:
            r += 1
            matrix.insert(Array(repeating: "", count: columns), at: r)
        case .columnLeft, .columnRight:
            if edit == .columnRight { c += 1 }
            for i in matrix.indices { matrix[i].insert("", at: c) }
            aligns.insert("", at: c)
        case .deleteRow:
            guard r > 0 else { NSSound.beep(); return }
            matrix.remove(at: r)
            r = min(r, matrix.count - 1)
        case .deleteColumn:
            guard columns > 1 else { return editTable(.deleteTable, at: location) }
            for i in matrix.indices { matrix[i].remove(at: c) }
            aligns.remove(at: c)
            c = min(c, columns - 2)
        case .deleteTable:
            deleteLine(containing: table.block)
            return
        }
        let (text, cellStarts) = Self.serializeTable(matrix, aligns: aligns)
        replace(table.block, with: text, caret: table.block.location + cellStarts[r][c])
    }

    /// Pipe-table source with columns padded to equal width, and the offset
    /// of each cell's text (row-major, divider excluded).
    static func serializeTable(_ matrix: [[String]], aligns: [String]) -> (String, [[Int]]) {
        let columns = matrix.map(\.count).max() ?? 0
        var widths = [Int](repeating: 3, count: columns)
        for row in matrix { for (i, cell) in row.enumerated() { widths[i] = max(widths[i], cell.count) } }
        var lines: [String] = []
        var starts: [[Int]] = []
        var offset = 0
        func line(_ cells: [String]) -> (String, [Int]) {
            var text = "|"
            var cellStarts: [Int] = []
            for (i, cell) in cells.enumerated() {
                text += " "
                cellStarts.append(offset + (text as NSString).length)
                text += cell + String(repeating: " ", count: max(0, widths[i] - cell.count)) + " |"
            }
            return (text, cellStarts)
        }
        for (n, row) in matrix.enumerated() {
            let (text, s) = line(row)
            lines.append(text); starts.append(s)
            offset += (text as NSString).length + 1
            if n == 0 {
                let divider = "|" + widths.enumerated().map { i, w in
                    let a = i < aligns.count ? aligns[i] : ""
                    let dashes = String(repeating: "-", count: max(3, w) - (a == "c" ? 2 : a.isEmpty ? 0 : 1))
                    return " " + (a == "c" || a == "l" ? ":" : "") + dashes + (a == "c" || a == "r" ? ":" : "") + " |"
                }.joined()
                lines.append(divider)
                offset += (divider as NSString).length + 1
            }
        }
        return (lines.joined(separator: "\n"), starts)
    }

    // MARK: Drawing

    /// Draws a hidden-syntax table as a grid: rounded outline, a tinted header
    /// and hairlines between rows and columns (at the invisible pipes).
    func drawTableGrid(_ table: NSRange) {
        guard let lm = layoutManager, let s = textStorage, NSMaxRange(table) <= s.length else { return }
        let ns = string as NSString
        var rows: [NSRect] = []
        var columns: [CGFloat] = []
        var loc = table.location
        while loc < NSMaxRange(table) {
            let line = contentLineRange(at: loc)
            let next = NSMaxRange(ns.lineRange(for: NSRange(location: loc, length: 0)))
            defer { loc = next > loc ? next : NSMaxRange(table) }
            guard line.length > 0, s.attribute(.typeAtomic, at: line.location, effectiveRange: nil) == nil else { continue }
            let g = lm.glyphIndexForCharacter(at: line.location)
            let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            rows.append(frag.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y))
            if rows.count == 1 {
                for p in MarkdownStyler.pipes(in: ns.substring(with: line)) {
                    let pg = lm.glyphIndexForCharacter(at: line.location + p)
                    let font = (s.attribute(.font, at: line.location + p, effectiveRange: nil) as? NSFont) ?? .systemFont(ofSize: 14)
                    let pipeWidth = ("|" as NSString).size(withAttributes: [.font: font]).width
                    columns.append((frag.minX + lm.location(forGlyphAt: pg).x + pipeWidth / 2 + textContainerOrigin.x).rounded())
                }
            }
        }
        guard let first = rows.first, let last = rows.last, columns.count >= 2 else { return }
        let rect = NSRect(x: columns.first!, y: first.minY.rounded(), width: columns.last! - columns.first!, height: (last.maxY - first.minY).rounded())
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: first.maxY - rect.minY).fill()
        NSColor.separatorColor.setFill()
        for row in rows.dropLast() { NSRect(x: rect.minX, y: row.maxY.rounded() - 0.5, width: rect.width, height: 1).fill() }
        for x in columns.dropFirst().dropLast() { NSRect(x: x - 0.5, y: rect.minY, width: 1, height: rect.height).fill() }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        outline.lineWidth = 1
        outline.stroke()
    }
}
