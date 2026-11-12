import AppKit

/// WYSIWYG typing: characters are literal (stored as Markdown escapes) and
/// formatted spans stay valid Markdown at every keystroke.
extension TypeTextView {
    /// Pasteboard flavour carrying the Markdown source of a copy made in Type.
    static let markdownType = NSPasteboard.PasteboardType("com.ajm.type.markdown")

    // MARK: Escapes

    /// True when the character at `i` is the backslash of an escape (read from the text, so it holds before restyling).
    func isEscapeBackslash(_ i: Int) -> Bool {
        let ns = string as NSString
        guard i >= 0, i + 1 < ns.length, ns.character(at: i) == 92, MarkdownEscapes.isPunctuation(ns.character(at: i + 1)) else { return false }
        let line = contentLineRange(at: i)
        return MarkdownEscapes.scan(ns.substring(with: line) as NSString).escapes.contains(i - line.location)
    }

    /// Widens a selection so it never splits a `\X` pair; a caret between the two hops over the pair.
    func keepingEscapesWhole(_ r: NSRange, movingForward: Bool) -> NSRange? {
        guard r.location <= (string as NSString).length else { return nil }
        if r.length == 0 {
            guard isEscapeBackslash(r.location - 1) else { return r }
            return NSRange(location: movingForward ? r.location + 1 : r.location - 1, length: 0)
        }
        var start = r.location, end = NSMaxRange(r)
        if isEscapeBackslash(start - 1) { start -= 1 }
        if isEscapeBackslash(end - 1) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// True when the backslash at `i` is the second half of an escaped backslash (`\\`).
    private func isLoneEscapedPair(_ i: Int) -> Bool { i > 0 && isEscapeBackslash(i - 1) }

    /// The text before `location` on its line.
    private func linePrefix(at location: Int) -> String {
        let line = contentLineRange(at: location)
        return (string as NSString).substring(with: NSRange(location: line.location, length: location - line.location))
    }

    /// True inside a fenced block or between the backticks of a code span.
    func isInsideCode(at location: Int) -> Bool {
        guard let s = textStorage, location <= s.length else { return false }
        let line = contentLineRange(at: location)
        if line.location < s.length, s.attribute(.typeCodeBlock, at: line.location, effectiveRange: nil) != nil { return true }
        let text = (string as NSString).substring(with: line) as NSString
        let local = location - line.location
        return MarkdownEscapes.scan(text).code.contains { span in
            var ticks = 0
            while span.location + ticks < text.length, text.character(at: span.location + ticks) == 96 { ticks += 1 }
            return local >= span.location + ticks && local <= NSMaxRange(span) - ticks
        }
    }

    /// `text` as it must be stored to read back literally when typed or pasted over `range`.
    func literalText(_ text: String, replacing range: NSRange) -> String {
        let ns = string as NSString
        guard range.location <= ns.length, !isInsideCode(at: range.location) else { return text }
        let next: unichar? = NSMaxRange(range) < ns.length ? ns.character(at: NSMaxRange(range)) : nil
        let escaped = MarkdownEscapes.escape(text, linePrefix: linePrefix(at: range.location), next: next)
        // A lone backslash just before would swallow our own: it is escaped first.
        if range.location > 0, ns.character(at: range.location - 1) == 92, !isEscapeBackslash(range.location - 1),
           !isLoneEscapedPair(range.location - 1), let first = text.utf16.first, MarkdownEscapes.isPunctuation(first) { return "\\" + escaped }
        return escaped
    }

    // MARK: Span edges

    /// The closing markers meeting at a caret: `inner` is where text typed
    /// "inside" goes, `end` just after the last marker.
    struct ClosingRun { var inner: Int; var end: Int; var markers: String; var innermostIsCode: Bool }

    /// Describes the closing markers the caret touches (inside their end or just after), if any.
    func closingRun(at location: Int) -> ClosingRun? {
        let line = contentLineRange(at: location)
        guard line.length > 0, isFormattableLine(line) else { return nil }
        let text = (string as NSString).substring(with: line)
        let spans = InlineFormatter.spans(in: text)
        guard !spans.isEmpty else { return nil }
        var inner = location - line.location
        while let s = spans.first(where: { NSMaxRange($0.close) == inner }) { inner = s.close.location }
        var end = inner
        var chain: [InlineSpan] = []
        while let s = spans.first(where: { $0.close.location == end }) { chain.append(s); end = NSMaxRange(s.close) }
        guard let first = chain.first else { return nil }
        let markers = (text as NSString).substring(with: NSRange(location: inner, length: end - inner))
        return ClosingRun(inner: line.location + inner, end: line.location + end, markers: markers, innermostIsCode: first.formats == [.code])
    }

    /// Just inside the opening markers that start at `location`, when they begin with `_`.
    func underscoreOpenerEnd(at location: Int) -> Int? {
        let line = contentLineRange(at: location)
        guard line.length > 0, isFormattableLine(line) else { return nil }
        let text = (string as NSString).substring(with: line) as NSString
        let spans = InlineFormatter.spans(in: text as String)
        var p = location - line.location
        guard let first = spans.first(where: { $0.open.location == p }), text.character(at: first.open.location) == 95 else { return nil }
        while let s = spans.first(where: { $0.open.location == p }) { p = NSMaxRange(s.open) }
        return line.location + p
    }

    /// Where the opening markers begin when the caret sits just inside them.
    func openingRunStart(at location: Int) -> Int? {
        let line = contentLineRange(at: location)
        guard line.length > 0, isFormattableLine(line) else { return nil }
        let spans = InlineFormatter.spans(in: (string as NSString).substring(with: line))
        let local = location - line.location
        var start = local
        while let s = spans.first(where: { $0.content.location == start }) { start = s.open.location }
        return start == local ? nil : line.location + start
    }

    /// A backtick typed inside a code span would end it: the span's fences grow instead
    /// (`` `a` `` + backtick -> ``` ``a`b`` ```), as Markdown does it.
    func insertBacktickInCode(at loc: Int) -> Bool {
        let line = contentLineRange(at: loc)
        guard line.length > 0, isFormattableLine(line) else { return false }
        let text = (string as NSString).substring(with: line) as NSString
        let local = loc - line.location
        guard let span = InlineFormatter.spans(in: text as String).first(where: { $0.formats == [.code] && $0.content.location <= local && local <= NSMaxRange($0.content) }) else { return false }
        let inner = text.substring(with: span.content)
        let offset = local - span.content.location
        var content = (inner as NSString).replacingCharacters(in: NSRange(location: offset, length: 0), with: "`")
        func longestRun(_ s: String) -> Int {
            var best = 0, run = 0
            for c in s { run = c == "`" ? run + 1 : 0; best = max(best, run) }
            return best
        }
        let fence = String(repeating: "`", count: longestRun(content) + 1)
        let pad = content.hasPrefix("`") || content.hasSuffix("`")
        if pad { content = " " + content + " " }
        let new = fence + content + fence
        let caret = line.location + span.open.location + fence.count + (pad ? 1 : 0) + offset + 1
        replace(NSRange(location: line.location + span.range.location, length: span.range.length), with: new, caret: caret)
        return true
    }

    /// Typing at the end of a span: text joins the span, and whitespace waits
    /// outside it (markers can't hug a space) until the next character.
    func insertAtSpanEdge(_ text: String, at loc: Int) -> Bool {
        guard !text.contains("\n") else { return false }
        if text == "`", insertBacktickInCode(at: loc) { return true }
        let length = (text as NSString).length
        let isSpace = text == " " || text == "\t"
        let ns = string as NSString
        if let r = rejoin, r.location == loc, !isSpace {
            let mLen = (r.markers as NSString).length
            let ws = ns.substring(with: NSRange(location: r.closeStart + mLen, length: loc - r.closeStart - mLen))
            replace(NSRange(location: r.closeStart, length: loc - r.closeStart), with: ws + text + r.markers,
                    caret: r.closeStart + (ws as NSString).length + length)
            rejoin = nil
            return true
        }
        if let c = text.unicodeScalars.first, text.count == 1, CharacterSet.alphanumerics.contains(c), let inside = underscoreOpenerEnd(at: loc) {
            // A word glued to an `_` opener would stop it opening: the text joins the span instead.
            replace(NSRange(location: inside, length: 0), with: text, caret: inside + length)
            return true
        }
        if isSpace, let start = openingRunStart(at: loc) {
            // A space can't follow an opening marker: it goes in front of the markers, the caret stays inside.
            replace(NSRange(location: start, length: 0), with: text, caret: loc + length)
            return true
        }
        guard let edge = closingRun(at: loc) else { return false }
        if edge.innermostIsCode, loc != edge.inner {
            // Just after a code span the text joins it, and inside code nothing is escaped.
            let raw = MarkdownEscapes.unescaped(text)
            if raw == "`", insertBacktickInCode(at: edge.inner) { return true }
            replace(NSRange(location: edge.inner, length: 0), with: raw, caret: edge.inner + (raw as NSString).length)
            return true
        }
        if isSpace && !edge.innermostIsCode {
            replace(NSRange(location: edge.end, length: 0), with: text, caret: edge.end + length)
            rejoin = (edge.inner, edge.markers, edge.end + length)
            return true
        }
        guard loc != edge.inner else { return false }
        replace(NSRange(location: edge.inner, length: 0), with: text, caret: edge.inner + length)
        return true
    }

    /// Types `text` wrapped in `formats` at `loc` so that every marker still parses: it joins an adjacent
    /// span of the same format, else tries `_`/`__` markers when `*` would run into a neighbour, else stays plain.
    func insertWrapped(_ text: String, formats: Set<InlineFormat>, at loc: Int) {
        let ns = string as NSString
        let line = contentLineRange(at: loc)
        let lineText = ns.substring(with: line)
        let local = loc - line.location
        let length = (text as NSString).length
        if formats.count == 1, let format = formats.first {
            for span in InlineFormatter.spans(in: lineText) where span.formats == [format] {
                if NSMaxRange(span.close) == local { replace(NSRange(location: line.location + span.close.location, length: 0), with: text, caret: line.location + span.close.location + length); return }
                if span.open.location == local { let at = line.location + NSMaxRange(span.open); replace(NSRange(location: at, length: 0), with: text, caret: at + length); return }
            }
        }
        let before: unichar? = loc > 0 ? ns.character(at: loc - 1) : nil
        let after: unichar? = loc < ns.length ? ns.character(at: loc) : nil
        let oldStray = InlineFormatter.strayMarkers(in: lineText), oldFormats = InlineFormatter.formatCount(in: lineText)
        for underscores in [false, true] {
            let (open, close) = InlineFormatter.wrap(text, in: formats, before: before, after: after, underscores: underscores)
            let candidate = (lineText as NSString).replacingCharacters(in: NSRange(location: local, length: 0), with: open + text + close)
            guard InlineFormatter.strayMarkers(in: candidate) <= oldStray, InlineFormatter.formatCount(in: candidate) == oldFormats + formats.count else { continue }
            replace(NSRange(location: loc, length: 0), with: open + text + close, caret: loc + (open as NSString).length + length)
            return
        }
        replace(NSRange(location: loc, length: 0), with: text, caret: loc + length)
    }

    /// Return must not cut a span in two: at its edges the break moves outside
    /// the markers; in the middle the span is closed and reopened around it.
    /// Returns true when it inserted the break itself (`continuingList` gets the first try, so list and quote items carry on).
    func breakLineOutsideSpans(continuingList: (_ closers: String, _ openers: String) -> Bool) -> Bool {
        let sel = selectedRange()
        guard sel.length == 0 else { return false }
        let line = contentLineRange(at: sel.location)
        guard isFormattableLine(line) else { return false }
        let text = (string as NSString).substring(with: line) as NSString
        let spans = InlineFormatter.spans(in: text as String)
        guard !spans.isEmpty else { return false }
        // Break outside the markers the caret touches.
        var p = sel.location - line.location
        if let edge = closingRun(at: sel.location) {
            p = edge.end - line.location
        } else {
            while let s = spans.first(where: { $0.content.location == p }) { p = s.open.location }
        }
        if p != sel.location - line.location { placeCaretExactly(line.location + p) }
        let enclosing = spans.filter { $0.content.location < p && p < NSMaxRange($0.content) }
            .sorted { $0.content.length < $1.content.length }
        guard !enclosing.isEmpty else { return false }
        // Close the spans before the break and reopen them after it; whitespace next to the
        // break moves outside the new markers (they can't hug a space). When `*` markers would
        // run together with a neighbour, `_` markers do the same job; failing that the spans
        // are dropped rather than left showing markers.
        var before = p, after = p
        while before > 0, isBlank(text.character(at: before - 1)) { before -= 1 }
        while after < text.length, isBlank(text.character(at: after)) { after += 1 }
        let blanks = text.substring(with: NSRange(location: before, length: after - before))
        let oldStray = InlineFormatter.strayMarkers(in: text as String), oldFormats = InlineFormatter.formatCount(in: text as String)
        func underscored(_ m: String) -> String? { m == "*" ? "_" : m == "**" ? "__" : m == "***" ? "___" : nil }
        for mode in 0..<3 {
            var edits: [(NSRange, String)] = []
            var closers = "", openers = ""
            var ok = true
            for s in enclosing {
                var open = text.substring(with: s.open), close = text.substring(with: s.close)
                if s.formats == [.code] {
                    // Backticks at the cut would run into the fences: a space keeps them apart.
                    if before > 0, text.character(at: before - 1) == 96 { close = " " + close }
                    if after < text.length, text.character(at: after) == 96 { open += " " }
                }
                if mode == 1 {
                    guard let o = underscored(open), let c = underscored(close) else { ok = false; break }
                    open = o; close = c
                }
                if mode > 0 { edits.append((s.open, mode == 2 ? "" : open)); edits.append((s.close, mode == 2 ? "" : close)) }
                if mode < 2 { closers += close; openers = open + openers }
            }
            guard ok else { continue }
            edits.append((NSRange(location: before, length: after - before), closers + blanks))
            var work = text as String as NSString
            var breakAt = 0
            for (range, replacement) in edits.sorted(by: { $0.0.location > $1.0.location }) {
                work = work.replacingCharacters(in: range, with: replacement) as NSString
            }
            breakAt = before + edits.filter { $0.0.location < before }.reduce(0) { $0 + ($1.1 as NSString).length - $1.0.length }
                + (closers as NSString).length + (blanks as NSString).length
            let line1 = work.substring(to: breakAt), line2 = openers + work.substring(from: breakAt)
            let strays = InlineFormatter.strayMarkers(in: line1) + InlineFormatter.strayMarkers(in: line2)
            let formats = InlineFormatter.formatCount(in: line1) + InlineFormatter.formatCount(in: line2)
            guard strays <= oldStray, mode == 2 || formats >= oldFormats else { continue }
            healingSuspended = true
            replace(line, with: work as String, caret: nil)
            healingSuspended = false
            placeCaretExactly(line.location + breakAt)
            if continuingList("", openers) { return true }
            replace(NSRange(location: line.location + breakAt, length: 0), with: "\n" + openers, caret: nil)
            placeCaretExactly(line.location + breakAt + 1 + (openers as NSString).length)
            return true
        }
        return false
    }

    private func isBlank(_ c: unichar) -> Bool { c == 32 || c == 9 }

    /// `line` with its emphasis markers made to parse by switching a pair of equal runs between `*` and `_`
    /// (`**a***c*` -> `**a**_c_`: the same emphasis, but where the first form could not parse, as `**`
    /// touching `*` or an `_` glued to a word). Unchanged when that cannot reduce the markers showing.
    func healed(_ line: String, preferring: (String) -> Bool = { _ in true }) -> String {
        var text = line
        for _ in 0..<3 {
            let current = InlineFormatter.strayMarkers(in: text)
            guard current > 0 else { break }
            let ns = text as NSString
            let masked = MarkdownEscapes.masked(text) as NSString
            // Runs of `*` / `_`; a run of three can be read as `**`+`*` or `*`+`**`.
            var runs: [NSRange] = []
            var i = 0
            while i < masked.length {
                let c = masked.character(at: i)
                guard c == 42 || c == 95 else { i += 1; continue }
                var end = i
                while end + 1 < masked.length, masked.character(at: end + 1) == c { end += 1 }
                let whole = NSRange(location: i, length: end - i + 1)
                if whole.length <= 2 { runs.append(whole) } else {
                    runs += [NSRange(location: whole.location, length: 1), NSRange(location: whole.location, length: 2),
                             NSRange(location: NSMaxRange(whole) - 1, length: 1), NSRange(location: NSMaxRange(whole) - 2, length: 2)]
                }
                i = end + 1
            }
            guard runs.count <= 16 else { break }
            let swap = ["*": "_", "**": "__", "_": "*", "__": "**"]
            typealias Move = (ranges: [NSRange], replacement: String)
            var moves: [Move] = []
            for (x, first) in runs.enumerated() {
                let marker = ns.substring(with: first)
                guard let swapped = swap[marker] else { continue }
                for second in runs[(x + 1)...] where NSIntersectionRange(first, second).length == 0 && ns.substring(with: second) == marker {
                    moves.append(([first, second], swapped))
                }
            }
            func apply(_ chosen: [Move]) -> String {
                chosen.flatMap { m in m.ranges.map { ($0, m.replacement) } }.sorted { $0.0.location > $1.0.location }
                    .reduce(ns) { $0.replacingCharacters(in: $1.0, with: $1.1) as NSString } as String
            }
            var best = (text: text, count: current)
            func consider(_ candidate: String) {
                let count = InlineFormatter.strayMarkers(in: candidate)
                guard count <= best.count, InlineFormatter.isWellNested(candidate) else { return }
                if count < best.count || (count == best.count && best.text != text && !preferring(best.text) && preferring(candidate)) { best = (candidate, count) }
            }
            for move in moves { consider(apply([move])) }
            // Fences that touch a backtick inside their content need a space between them.
            var t = 0
            while t < ns.length, best.count > 0 {
                guard ns.character(at: t) == 96 else { t += 1; continue }
                var end = t
                while end + 1 < ns.length, ns.character(at: end + 1) == 96 { end += 1 }
                for at in Set([t, end + 1] + Array(stride(from: t + 1, through: end, by: 1))) { consider(ns.replacingCharacters(in: NSRange(location: at, length: 0), with: " ")) }
                t = end + 1
            }
            if best.count > 0, moves.count <= 14 {
                // Nested emphasis can need two pairs to switch together (`_**b**_` -> `*__b__*`).
                for (x, m1) in moves.enumerated() {
                    for m2 in moves[(x + 1)...] where m1.ranges.allSatisfy({ r in m2.ranges.allSatisfy { NSIntersectionRange(r, $0).length == 0 } }) {
                        consider(apply([m1, m2]))
                    }
                }
            }
            if best.text == text { break }
            text = best.text
        }
        return text
    }

    /// After an edit made the line show more markers than before, repairs it by `healed`.
    func healLine(afterEditWithStrays before: Int) {
        let caret = selectedRange()
        let line = contentLineRange(at: caret.location)
        guard line.length > 0, caret.length == 0, isFormattableLine(line) else { return }
        let text = (string as NSString).substring(with: line)
        guard InlineFormatter.strayMarkers(in: text) > before else { return }
        let fixed = healed(text)
        guard fixed != text, InlineFormatter.strayMarkers(in: fixed) < InlineFormatter.strayMarkers(in: text) else { return }
        replace(line, with: fixed, caret: nil)
        placeCaretExactly(caret.location)
    }

    /// How many markers the line at `location` shows now (to compare after an edit).
    func strayMarkersOfLine(at location: Int) -> Int {
        let ns = string as NSString
        guard location <= ns.length else { return 0 }
        return InlineFormatter.strayMarkers(in: ns.substring(with: contentLineRange(at: location)))
    }

    /// After a deletion at `location`: drops a span left empty, and moves whitespace that ended up
    /// against a marker (`**a **`) back outside it so the span still parses.
    func repairSpans(near location: Int) {
        let before = string
        removeEmptySpan(at: location)
        guard string == before else { return }
        let line = contentLineRange(at: location)
        guard line.length > 0, location >= line.location, location <= NSMaxRange(line), isFormattableLine(line) else { return }
        let text = (string as NSString).substring(with: line) as NSString
        let local = location - line.location
        let escaped = Set(MarkdownEscapes.scan(text).escapes.map { $0 + 1 })
        func isMarker(_ i: Int) -> Bool { !escaped.contains(i) && "*_~=`".utf16.contains(text.character(at: i)) }
        func isBlank(_ i: Int) -> Bool { text.character(at: i) == 32 || text.character(at: i) == 9 }
        let strays = InlineFormatter.strayMarkers(in: text as String)
        /// The best way to write `moved` so the span at `marker` parses and fewer markers show than now.
        func best(_ moved: NSString, test: (InlineSpan) -> Bool) -> String? {
            [moved as String, healed(moved as String, preferring: { InlineFormatter.spans(in: $0).contains(where: test) })]
                .filter { InlineFormatter.spans(in: $0).contains(where: test) && InlineFormatter.strayMarkers(in: $0) < strays }
                .min { InlineFormatter.strayMarkers(in: $0) < InlineFormatter.strayMarkers(in: $1) }
        }
        // Whitespace before a closing run: `a |**` -> `a** `. Only as many markers as close the span
        // move ahead of the whitespace (`==*x*` keeps its `*` after it).
        var runEnd = local
        while runEnd < text.length, isMarker(runEnd) { runEnd += 1 }
        var blankStart = local
        while blankStart > 0, isBlank(blankStart - 1) { blankStart -= 1 }
        if runEnd > local, blankStart < local, blankStart > 0 {
            let blanks = text.substring(with: NSRange(location: blankStart, length: local - blankStart))
            var options: [(text: String, caret: Int)] = []
            for length in stride(from: runEnd - local, through: 1, by: -1) {
                let run = text.substring(with: NSRange(location: local, length: length))
                let moved = text.replacingCharacters(in: NSRange(location: blankStart, length: local + length - blankStart), with: run + blanks) as NSString
                if let fixed = best(moved, test: { $0.close.location == blankStart }) { options.append((fixed, blankStart)) }
            }
            if let pick = options.min(by: { InlineFormatter.strayMarkers(in: $0.text) < InlineFormatter.strayMarkers(in: $1.text) }) {
                replace(line, with: pick.text, caret: nil)
                placeCaretExactly(line.location + pick.caret)
                return
            }
        }
        // Whitespace after an opening run: `** a` -> ` **a`.
        var runStart = local
        while runStart > 0, isMarker(runStart - 1) { runStart -= 1 }
        var blankEnd = local
        while blankEnd < text.length, isBlank(blankEnd) { blankEnd += 1 }
        if runStart < local, blankEnd > local {
            let blanks = text.substring(with: NSRange(location: local, length: blankEnd - local))
            var options: [(text: String, caret: Int)] = []
            for length in stride(from: local - runStart, through: 1, by: -1) {
                let run = text.substring(with: NSRange(location: local - length, length: length))
                let moved = text.replacingCharacters(in: NSRange(location: local - length, length: blankEnd - local + length), with: blanks + run) as NSString
                let newOpen = local - length + (blanks as NSString).length
                if let fixed = best(moved, test: { $0.open.location == newOpen }) { options.append((fixed, newOpen + length)) }
            }
            if let pick = options.min(by: { InlineFormatter.strayMarkers(in: $0.text) < InlineFormatter.strayMarkers(in: $1.text) }) {
                replace(line, with: pick.text, caret: nil)
                placeCaretExactly(line.location + pick.caret)
            }
        }
    }

    /// Drops the markers of a span whose last character was just deleted at `location`
    /// (and of a span pair that a joined line leaves back to back).
    func removeEmptySpan(at location: Int) {
        let line = contentLineRange(at: location)
        guard line.length > 0, location >= line.location, location <= NSMaxRange(line) else { return }
        let text = (string as NSString).substring(with: line) as NSString
        let escaped = Set(MarkdownEscapes.scan(text).escapes.map { $0 + 1 })
        func isMarker(_ i: Int) -> Bool { !escaped.contains(i) && "*_~=`".utf16.contains(text.character(at: i)) }
        let local = location - line.location
        // Markers mirrored around the spot: the opening and closing runs of an empty span,
        // cut only at the edges of whole runs.
        var radius = 0
        while local - radius > 0, local + radius < text.length, isMarker(local - radius - 1), isMarker(local + radius),
              text.character(at: local - radius - 1) == text.character(at: local + radius) { radius += 1 }
        while radius > 0 {
            let l = local - radius, r = local + radius
            let leftEdge = l == 0 || !isMarker(l - 1) || text.character(at: l - 1) != text.character(at: l)
            let rightEdge = r == text.length || !isMarker(r) || text.character(at: r) != text.character(at: r - 1)
            if leftEdge && rightEdge { break }
            radius -= 1
        }
        guard radius >= 1 else { return }
        let junction = local - radius
        let merged = text.replacingCharacters(in: NSRange(location: junction, length: 2 * radius), with: "") as NSString
        // Merging can leave `**` touching `*`: healing switches such pairs to underscores.
        let candidates = [merged as String, healed(merged as String)]
        let fixed = candidates.min { InlineFormatter.strayMarkers(in: $0) < InlineFormatter.strayMarkers(in: $1) }!
        replace(line, with: fixed, caret: nil)
        placeCaretExactly(line.location + junction)
        repairSpans(near: line.location + junction)
    }

    // MARK: Block syntax made by editing

    /// Where block syntax (heading, quote, list marker, rule) starts a line, and the character to escape.
    private func blockMarkerIndex(in line: String) -> Int? {
        let ns = line as NSString
        let all = NSRange(location: 0, length: ns.length)
        if MDPattern.heading.firstMatch(in: line, range: all) != nil { return 0 }
        if let m = MDPattern.quote.firstMatch(in: line, range: all) { return ns.range(of: ">", range: m.range).location }
        if let m = MDPattern.list.firstMatch(in: line, range: all) {
            let marker = m.range(at: 2)
            return marker.length > 1 ? NSMaxRange(marker) - 1 : marker.location
        }
        if MDPattern.rule.firstMatch(in: line, range: all) != nil {
            return (0..<ns.length).first { ns.character(at: $0) != 32 && ns.character(at: $0) != 9 }
        }
        return nil
    }

    /// Whether the text that will start the edited line already was block syntax before `edit`
    /// (a real list stays one when the line above it is deleted).
    func blockBaselineBefore(_ edit: NSRange) -> Bool {
        let ns = string as NSString
        guard edit.location <= ns.length else { return false }
        let first = contentLineRange(at: edit.location)
        let prefix = ns.substring(with: NSRange(location: first.location, length: edit.location - first.location))
        if edit.length > 0, prefix.allSatisfy({ $0 == " " || $0 == "\t" }), NSMaxRange(edit) <= ns.length {
            let tail = contentLineRange(at: NSMaxRange(edit))
            if tail.location == NSMaxRange(edit) { return blockMarkerIndex(in: ns.substring(with: tail)) != nil }
        }
        return blockMarkerIndex(in: ns.substring(with: first)) != nil
    }

    /// Typing and deleting never make structure: when an edit leaves the line starting with block
    /// syntax it did not have, the marker is escaped so it stays text.
    func keepNewBlockSyntaxLiteral(wasBlock: Bool) {
        guard !wasBlock, undoManager?.isUndoing != true, undoManager?.isRedoing != true, !hasMarkedText() else { return }
        let caret = selectedRange()
        guard caret.length == 0 else { return }
        let line = contentLineRange(at: caret.location)
        guard line.length > 0, textStorage?.attribute(.typeCodeBlock, at: line.location, effectiveRange: nil) == nil,
              let index = blockMarkerIndex(in: (string as NSString).substring(with: line)) else { return }
        replace(NSRange(location: line.location + index, length: 0), with: "\\", caret: nil)
        placeCaretExactly(caret.location + (line.location + index <= caret.location ? 1 : 0))
    }

    // MARK: Copy

    /// The characters of `range` that are drawn: syntax and escapes removed, bullets and boxes as shown.
    func visibleText(in range: NSRange) -> String {
        guard let s = textStorage else { return "" }
        let ns = s.string as NSString
        var out = ""
        for i in range.location..<NSMaxRange(range) {
            if let done = s.attribute(.typeTaskBox, at: i, effectiveRange: nil) as? Bool { out += done ? "\u{2611}" : "\u{2610}"; continue }
            if s.attribute(.typeHidden, at: i, effectiveRange: nil) != nil { continue }
            if let glyph = s.attribute(.typeGlyph, at: i, effectiveRange: nil) as? String { out += glyph; continue }
            out += ns.substring(with: NSRange(location: i, length: 1))
        }
        return out
    }
}
