import Foundation

/// Inline Markdown formats the toolbar and ⌘B/⌘I/… toggle.
enum InlineFormat: CaseIterable, Hashable {
    case bold, italic, strike, highlight, code
}

/// A formatted run on one line: `open` and `close` are its marker ranges and
/// `content` what sits between them (all line-relative).
struct InlineSpan: Equatable {
    var formats: Set<InlineFormat>
    var open: NSRange
    var close: NSRange
    var range: NSRange { NSRange(location: open.location, length: NSMaxRange(close) - open.location) }
    var content: NSRange { NSRange(location: NSMaxRange(open), length: close.location - NSMaxRange(open)) }
}

/// Toggles inline formatting on a single line of Markdown so that markers
/// always nest cleanly: they never cut through other formatting, never wrap a
/// line prefix (`## `, `- `, `> `), and toggling a format that is already
/// applied removes it instead of stacking a second copy.
enum InlineFormatter {
    // MARK: Parsing

    /// Every inline span on `line` (code spans first; formatting inside code is ignored).
    static func spans(in line: String) -> [InlineSpan] {
        let ns = line as NSString
        let all = NSRange(location: 0, length: ns.length)
        let line = MarkdownEscapes.masked(line)
        var result: [InlineSpan] = []
        var code: [NSRange] = []
        for m in MDPattern.codeSpan.matches(in: line, range: all) {
            let tick = m.range(at: 1).length
            code.append(m.range)
            result.append(InlineSpan(formats: [.code], open: NSRange(location: m.range.location, length: tick),
                                     close: NSRange(location: NSMaxRange(m.range) - tick, length: tick)))
        }
        func outsideCode(_ r: NSRange) -> Bool { !code.contains { NSIntersectionRange($0, r).length > 0 } }
        func add(_ regex: NSRegularExpression, _ formats: Set<InlineFormat>, marker: Int) {
            for m in regex.matches(in: line, range: all) where outsideCode(m.range) {
                let span = InlineSpan(formats: formats, open: NSRange(location: m.range.location, length: marker),
                                      close: NSRange(location: NSMaxRange(m.range) - marker, length: marker))
                // `***x***` also matches the bold pattern; keep the combined span only.
                if !result.contains(where: { $0.range == span.range }) { result.append(span) }
            }
        }
        add(MDPattern.boldItalic, [.bold, .italic], marker: 3)
        add(MDPattern.boldStar, [.bold], marker: 2)
        add(MDPattern.boldUnderscore, [.bold], marker: 2)
        add(MDPattern.italicStar, [.italic], marker: 1)
        add(MDPattern.italicUnderscore, [.italic], marker: 1)
        add(MDPattern.strike, [.strike], marker: 2)
        add(MDPattern.highlight, [.highlight], marker: 2)
        return result
    }

    /// Where a line's text starts, after any heading / quote / list / checklist prefix.
    static func contentStart(of line: String) -> Int {
        let ns = line as NSString
        var start = 0
        if let m = MDPattern.heading.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
            return m.range.length
        }
        if let m = MDPattern.quote.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
            start = m.range.length
        }
        let rest = ns.substring(from: start)
        if let m = MDPattern.list.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) {
            start += m.range.length
        }
        return start
    }

    /// The parts of `selection` (line-relative) that formatting may wrap: the
    /// line's text after its prefix, split at table cell borders, with
    /// surrounding whitespace trimmed (markers must hug the text).
    static func segments(of line: String, selection: NSRange) -> [NSRange] {
        let ns = line as NSString
        let start = contentStart(of: line)
        let content = NSRange(location: start, length: ns.length - start)
        var clamped = NSIntersectionRange(selection, content)
        if clamped.length == 0 && !(selection.length == 0 && NSLocationInRange(selection.location, NSRange(location: start, length: content.length + 1))) {
            return []
        }
        if selection.length == 0 { clamped = NSRange(location: selection.location, length: 0) }
        var pieces: [NSRange] = []
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
            var pieceStart = clamped.location
            for i in clamped.location..<NSMaxRange(clamped) where ns.character(at: i) == 124 /* | */ && (i == 0 || ns.character(at: i - 1) != 92) {
                pieces.append(NSRange(location: pieceStart, length: i - pieceStart))
                pieceStart = i + 1
            }
            pieces.append(NSRange(location: pieceStart, length: NSMaxRange(clamped) - pieceStart))
        } else {
            pieces = [clamped]
        }
        let markers = spans(in: line).flatMap { [$0.open, $0.close] }
        func isMarkerAt(_ i: Int) -> Bool { markers.contains { NSLocationInRange(i, $0) } }
        return pieces.compactMap { piece -> NSRange? in
            // A selection that runs over existing markers ("one**") means the text inside them.
            guard var r = trimWhitespace(piece, in: ns) else { return nil }
            while r.length > 0, isMarkerAt(r.location) { r.location += 1; r.length -= 1 }
            while r.length > 0, isMarkerAt(NSMaxRange(r) - 1) { r.length -= 1 }
            return trimWhitespace(r, in: ns)
        }.filter { $0.length > 0 }
    }

    private static func trimWhitespace(_ r: NSRange, in ns: NSString) -> NSRange? {
        var r = r
        while r.length > 0, isSpace(ns.character(at: r.location)) { r.location += 1; r.length -= 1 }
        while r.length > 0, isSpace(ns.character(at: NSMaxRange(r) - 1)) { r.length -= 1 }
        return r
    }

    private static func isSpace(_ c: unichar) -> Bool { c == 32 || c == 9 || c == 10 || c == 0xA0 }
    private static func isMarker(_ c: unichar) -> Bool { "*_~=`".utf16.contains(c) }
    private static func isWordChar(_ c: unichar?) -> Bool {
        guard let c, let u = UnicodeScalar(c) else { return false }
        return CharacterSet.alphanumerics.contains(u)
    }

    // MARK: State

    /// The innermost span with `format` whose content contains `segment`.
    static func enclosingSpan(_ format: InlineFormat, in spans: [InlineSpan], segment: NSRange) -> InlineSpan? {
        spans.filter { span in
            span.formats.contains(format) && segment.location >= span.content.location
                && NSMaxRange(segment) <= NSMaxRange(span.content)
        }
        .min { $0.content.length < $1.content.length }
    }

    static func isActive(_ format: InlineFormat, in line: String, segment: NSRange) -> Bool {
        enclosingSpan(format, in: spans(in: line), segment: segment) != nil
    }

    /// True when `segment` sits inside a code span (other formatting would show as literal text there).
    static func isInCode(_ line: String, segment: NSRange) -> Bool {
        enclosingSpan(.code, in: spans(in: line), segment: segment) != nil
    }

    // MARK: Editing

    /// A replacement of `range` (line-relative) by `text`, with the formatted
    /// text's new location inside the replacement.
    struct Edit: Equatable {
        var range: NSRange
        var text: String
        var selection: NSRange
    }

    /// Applies (`on == true`) or removes `format` on `segment` of `line`.
    static func edit(_ format: InlineFormat, on: Bool, in line: String, segment: NSRange) -> Edit? {
        let all = spans(in: line)
        if format != .code, enclosingSpan(.code, in: all, segment: segment) != nil { return nil }
        if on {
            return apply(format, in: line, segment: segment, spans: all)
        }
        guard let span = enclosingSpan(format, in: all, segment: segment) else { return nil }
        return remove(format, from: span, in: line, segment: segment)
    }

    /// The marker for `format` around `inner`, picking `__`/`_` where `**`/`*`
    /// would run into a neighbouring asterisk (`***x** y*` doesn't parse; `*__x__ y*` does).
    static func marker(for format: InlineFormat, inner: String, before: unichar?, after: unichar?, underscores: Bool = false) -> String {
        let star: unichar = 42
        let i = inner as NSString
        let touchesStar = before == star || after == star
            || (i.length > 0 && (i.character(at: 0) == star || i.character(at: i.length - 1) == star))
        let intraword = isWordChar(before) || isWordChar(after)
        switch format {
        case .bold: return (touchesStar || underscores) && !intraword ? "__" : "**"
        case .italic: return (touchesStar || underscores) && !intraword ? "_" : "*"
        case .strike: return "~~"
        case .highlight: return "=="
        case .code: return inner.contains("`") ? "``" : "`"
        }
    }

    private static func apply(_ format: InlineFormat, in line: String, segment: NSRange, spans: [InlineSpan]) -> Edit? {
        let ns = line as NSString
        guard segment.length > 0 else { return nil }
        var r = segment
        // Grow over any span the selection cuts through, so markers never interleave.
        var changed = true
        while changed {
            changed = false
            for s in spans {
                let inter = NSIntersectionRange(r, s.range)
                let partial = inter.length > 0 && NSUnionRange(r, s.range) != r
                let inside = r.location >= s.content.location && NSMaxRange(r) <= NSMaxRange(s.content)
                if partial && !inside {
                    r = NSUnionRange(r, s.range)
                    changed = true
                }
            }
        }
        // Merge: same-format spans inside the range lose their markers.
        var inner = ns.substring(with: r)
        if format != .code {
            let nested = spans.filter { $0.formats.contains(format) && NSUnionRange($0.range, r) == r }
                .sorted { $0.open.location > $1.open.location }
            var innerNS = inner as NSString
            for s in nested {
                let rem = remainingMarker(after: format, span: s, in: ns)
                let close = NSRange(location: s.close.location - r.location, length: s.close.length)
                let open = NSRange(location: s.open.location - r.location, length: s.open.length)
                innerNS = innerNS.replacingCharacters(in: close, with: rem) as NSString
                innerNS = innerNS.replacingCharacters(in: open, with: rem) as NSString
            }
            inner = innerNS as String
        }
        let before: unichar? = r.location > 0 ? ns.character(at: r.location - 1) : nil
        let after: unichar? = NSMaxRange(r) < ns.length ? ns.character(at: NSMaxRange(r)) : nil
        let m = marker(for: format, inner: inner, before: before, after: after)
        let mLen = (m as NSString).length
        return Edit(range: r, text: m + inner + m,
                    selection: NSRange(location: r.location + mLen, length: (inner as NSString).length))
    }

    /// The markers left when `format` is taken off `span` (`***` minus italic is `**`).
    private static func remainingMarker(after format: InlineFormat, span: InlineSpan, in ns: NSString) -> String {
        let rest = span.formats.subtracting([format])
        guard !rest.isEmpty else { return "" }
        let ch = ns.substring(with: NSRange(location: span.open.location, length: 1))
        return rest.contains(.bold) ? ch + ch : ch
    }

    private static func remove(_ format: InlineFormat, from span: InlineSpan, in line: String, segment: NSRange) -> Edit {
        let ns = line as NSString
        let content = span.content
        var seg = segment
        // Selecting the words of "**~~words~~**" covers the whole content.
        while seg.location > content.location, isMarker(ns.character(at: seg.location - 1)) { seg.location -= 1; seg.length += 1 }
        while NSMaxRange(seg) < NSMaxRange(content), isMarker(ns.character(at: NSMaxRange(seg))) { seg.length += 1 }
        let open = ns.substring(with: span.open)
        let close = ns.substring(with: span.close)
        let rem = remainingMarker(after: format, span: span, in: ns)
        let remLen = (rem as NSString).length

        if seg == content || segment.length == 0 {
            let text = rem + ns.substring(with: content) + rem
            let selStart = span.open.location + remLen + (segment.location - content.location)
            return Edit(range: span.range, text: text, selection: NSRange(location: selStart, length: segment.length))
        }
        // Partial: keep the format on the text before and after the selection.
        func piece(_ r: NSRange) -> String {
            let s = ns.substring(with: r)
            guard let core = trimWhitespace(NSRange(location: 0, length: (s as NSString).length), in: s as NSString), core.length > 0 else { return s }
            let sn = s as NSString
            return sn.substring(to: core.location) + open + sn.substring(with: core) + close + sn.substring(from: NSMaxRange(core))
        }
        let beforeText = piece(NSRange(location: content.location, length: segment.location - content.location))
        let afterText = piece(NSRange(location: NSMaxRange(segment), length: NSMaxRange(content) - NSMaxRange(segment)))
        let middle = rem + ns.substring(with: segment) + rem
        let selStart = span.open.location + (beforeText as NSString).length + remLen
        return Edit(range: span.range, text: beforeText + middle + afterText,
                    selection: NSRange(location: selStart, length: segment.length))
    }

    /// Opening/closing markers for text typed with `formats` pending (no selection).
    static func wrap(_ text: String, in formats: Set<InlineFormat>, before: unichar?, after: unichar?, underscores: Bool = false) -> (open: String, close: String) {
        var open = "", close = ""
        var inner = text
        for f in [InlineFormat.code, .italic, .bold, .strike, .highlight] where formats.contains(f) {
            let m = marker(for: f, inner: inner, before: before, after: after, underscores: underscores)
            open = m + open
            close += m
            inner = m + inner + m
        }
        return (open, close)
    }

    // MARK: Health checks

    /// Total number of formats applied by the spans of `line`.
    static func formatCount(in line: String) -> Int {
        spans(in: line).reduce(0) { $0 + $1.formats.count }
    }

    /// Offsets of marker characters in `line` that no span uses and nothing escapes: they would be drawn.
    static func strayIndices(in line: String) -> [Int] {
        let masked = MarkdownEscapes.masked(line) as NSString
        let lone = MarkdownEscapes.scanAll(line as NSString).loneTicks.flatMap { Array($0.location..<NSMaxRange($0)) }
        guard !lone.isEmpty || (0..<masked.length).contains(where: { isMarker(masked.character(at: $0)) }) else { return [] }
        var used = Set<Int>()
        for span in spans(in: line) {
            for r in [span.open, span.close] { used.formUnion(r.location..<NSMaxRange(r)) }
            if span.formats == [.code] { used.formUnion(span.content.location..<NSMaxRange(span.content)) }
        }
        let markers = (0..<masked.length).filter { !used.contains($0) && isMarker(masked.character(at: $0)) }
        return Array(Set(markers).union(lone.filter { !used.contains($0) })).sorted()
    }

    static func strayMarkers(in line: String) -> Int { strayIndices(in: line).count }

    /// True when no two spans of `line` partly overlap (`_a **b_ c**` crosses).
    static func isWellNested(_ line: String) -> Bool {
        let all = spans(in: line).map(\.range)
        return !all.contains { a in all.contains { b in NSIntersectionRange(a, b).length > 0 && NSUnionRange(a, b) != a && NSUnionRange(a, b) != b } }
    }
}
