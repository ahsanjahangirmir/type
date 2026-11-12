import AppKit

/// Text-view side of the Format menu (see `EditorController+FormatMenu`).
extension TypeTextView {
    /// Gives the Format menu first refusal on plain keyboard text (a "/" over a selection, or filter letters).
    func interceptsFormatMenuInput(_ typed: String, replacementRange: NSRange) -> Bool {
        guard !typed.isEmpty, !hasMarkedText(), replacementRange.location == NSNotFound || replacementRange == selectedRange() else { return false }
        return events?.textView(self, handleTypedText: typed) ?? false
    }

    /// The selected lines that take part in a format (non-empty ones intersecting the selection).
    private func selectedContentLines() -> [NSRange] {
        let ns = string as NSString
        let sel = selectedRange()
        guard sel.length > 0 else { return [] }
        let block = ns.lineRange(for: sel)
        var lines: [NSRange] = []
        var loc = block.location
        while loc < NSMaxRange(block) {
            let line = contentLineRange(at: loc)
            loc = NSMaxRange(ns.lineRange(for: NSRange(location: loc, length: 0)))
            if NSIntersectionRange(sel, line).length > 0 { lines.append(line) }
        }
        return lines
    }

    /// False when the selection touches fenced code, an image, a divider or a table rule, or holds no text.
    var canFormatSelection: Bool {
        let lines = selectedContentLines()
        return !lines.isEmpty && lines.allSatisfy { isFormattableLine($0) }
    }

    /// Whether `format` is on for any part of the selected text (`any`) and for all of it (`all`).
    func formatCoverage(_ format: InlineFormat) -> (any: Bool, all: Bool) {
        let ns = string as NSString
        let sel = selectedRange()
        var all: [Bool] = []
        var any = false
        for line in selectedContentLines() where isFormattableLine(line) {
            let local = NSIntersectionRange(sel, line)
            let text = ns.substring(with: line)
            let spans = InlineFormatter.spans(in: text).filter { $0.formats.contains(format) }
            for seg in InlineFormatter.segments(of: text, selection: NSRange(location: local.location - line.location, length: local.length)) {
                all.append(InlineFormatter.isActive(format, in: text, segment: seg))
                any = any || spans.contains { NSIntersectionRange($0.content, seg).length > 0 }
            }
        }
        return (any, !all.isEmpty && !all.contains(false))
    }

    /// "Text": strips every inline format from the selection and the heading, quote or
    /// list prefix from its lines, as one undo step. The selection ends up on the lines.
    func clearFormatting() {
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }
        for format in InlineFormat.allCases {
            let coverage = formatCoverage(format)
            guard coverage.any else { continue }
            if !coverage.all { toggleFormat(format) } // first make it uniform, then the toggle removes it
            toggleFormat(format)
        }
        let ns = string as NSString
        let lineRange = ns.lineRange(for: selectedRange())
        let trailingNewline = ns.character(at: NSMaxRange(lineRange) - 1) == 10
        let lines = ns.substring(with: lineRange).components(separatedBy: "\n")
        let stripped = lines.map { line -> String in
            var body = line
            for r in [MDPattern.heading, MDPattern.quote, MDPattern.list] {
                body = r.stringByReplacingMatches(in: body, range: NSRange(location: 0, length: (body as NSString).length), withTemplate: "")
            }
            return body
        }
        let result = stripped.joined(separator: "\n")
        if result != ns.substring(with: lineRange) { replace(lineRange, with: result, caret: nil) }
        setSelectedRange(NSRange(location: lineRange.location, length: (result as NSString).length - (trailingNewline ? 1 : 0)))
    }
}
