import AppKit

/// ⌘K: find the link to edit (or the text to turn into one).
extension TypeTextView {
    struct LinkTarget {
        /// The existing `[label](url)`, or the text that will become the label.
        var range: NSRange
        /// What the popover shows: the label with its escapes resolved.
        var label: String
        /// The label as stored (with escapes), for turning the link back into text.
        var rawLabel: String
        var url: String
        var isExisting: Bool
    }

    /// The link around the selection, or else the selected text (one line,
    /// after any list/heading prefix) or the word at the caret.
    func linkTarget() -> LinkTarget {
        let ns = string as NSString
        let sel = selectedRange()
        let line = contentLineRange(at: sel.location)
        let text = ns.substring(with: line) as NSString
        let masked = MarkdownEscapes.masked(text as String)
        for m in MDPattern.link.matches(in: masked, range: NSRange(location: 0, length: text.length)) where m.range(at: 1).length == 0 {
            let r = NSRange(location: line.location + m.range.location, length: m.range.length)
            if sel.location >= r.location, sel.location <= NSMaxRange(r) {
                let raw = text.substring(with: m.range(at: 2))
                return LinkTarget(range: r, label: MarkdownEscapes.unescaped(raw), rawLabel: raw, url: text.substring(with: m.range(at: 3)), isExisting: true)
            }
        }
        let contentStart = line.location + InlineFormatter.contentStart(of: text as String)
        var r = NSIntersectionRange(sel, NSRange(location: contentStart, length: NSMaxRange(line) - contentStart))
        if sel.length == 0 {
            let word = wordRange(at: sel.location)
            r = word.length > 0 && word.location >= contentStart ? word : NSRange(location: max(sel.location, contentStart), length: 0)
        }
        while r.length > 0, ns.character(at: r.location) == 32 { r.location += 1; r.length -= 1 }
        while r.length > 0, ns.character(at: NSMaxRange(r) - 1) == 32 { r.length -= 1 }
        let raw = ns.substring(with: r)
        return LinkTarget(range: r, label: MarkdownEscapes.unescaped(raw), rawLabel: raw, url: "", isExisting: false)
    }

    /// Writes `[label](url)` over the target and puts the caret after it.
    func applyLink(_ target: LinkTarget, label: String, url: String) {
        let link = Self.normalizedURL(url)
        guard !link.isEmpty else { return }
        // The label is literal text: `a*b` and `x]y` are stored escaped.
        let typed = label.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let text = typed.isEmpty ? "" : MarkdownEscapes.escape(typed, linePrefix: "a")
        let markdown = "[\(text)](\(link))"
        replace(target.range, with: markdown, caret: target.range.location + (markdown as NSString).length)
    }

    /// Turns a link back into plain text, keeping the label selected.
    func removeLink(_ target: LinkTarget) {
        guard target.isExisting else { return }
        replace(target.range, with: target.rawLabel, caret: nil,
                select: NSRange(location: target.range.location, length: (target.rawLabel as NSString).length))
    }

    /// Adds `https://` (or `mailto:`) when missing and escapes what Markdown can't hold in a URL.
    static func normalizedURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }
        let hasScheme = s.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*:(//|[^0-9])"#, options: .regularExpression) != nil
        if !hasScheme, !["/", "~", "#", "."].contains(where: { s.hasPrefix($0) }) {
            s = (s.contains("@") && !s.contains("/") ? "mailto:" : "https://") + s
        }
        return s.replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
    }

    /// Bounding rect of the first line of `range` in view coordinates (the caret when empty).
    func firstLineRect(for range: NSRange) -> NSRect {
        guard range.length > 0, let lm = layoutManager, let tc = textContainer else { return caretRect(at: range.location) }
        let line = contentLineRange(at: range.location)
        let r = NSIntersectionRange(range, line)
        let glyphs = lm.glyphRange(forCharacterRange: r.length > 0 ? r : range, actualCharacterRange: nil)
        var rect = NSRect.null
        lm.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: tc) { r, stop in
            rect = r
            stop.pointee = true
        }
        if rect.isNull { return caretRect(at: range.location) }
        return rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }
}
