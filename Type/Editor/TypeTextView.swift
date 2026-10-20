import AppKit

protocol TypeTextViewEvents: AnyObject {
    func textViewDidType(_ textView: TypeTextView)
    func textViewMouseMoved(_ textView: TypeTextView)
    func textView(_ textView: TypeTextView, didBeginSlashAt location: Int)
    /// Return true to swallow the command (used for slash-menu navigation).
    func textView(_ textView: TypeTextView, handleSlashCommand selector: Selector) -> Bool
}

/// The writing surface: a TextKit 1 NSTextView tuned for distraction-free
/// Markdown writing.
final class TypeTextView: NSTextView, NSLayoutManagerDelegate {
    var config: EditorConfig? {
        didSet { if config != oldValue { applyChrome(); updateLayoutInsets() } }
    }
    weak var events: TypeTextViewEvents?
    private var lastMouse: NSPoint = .zero
    private var trackingArea: NSTrackingArea?
    private var focusedParagraph: NSRange?

    /// Folder that relative image paths resolve against.
    var documentBaseURL: URL?
    /// Width of the text column (images are capped to it).
    private(set) var columnWidth: CGFloat = 700
    var onColumnWidthChange: ((CGFloat) -> Void)?
    /// Saves pasteboard images and returns the Markdown paths to insert; nil when not handled.
    var imagePasteHandler: ((NSPasteboard) -> [ImageStore.Saved]?)?
    private var imageViews: [ImageBlockView] = []
    private var imageLayoutScheduled = false

    // MARK: Setup

    func applyChrome() {
        guard let config else { return }
        insertionPointColor = config.hideCaret ? .clear : config.caretColor.nsColor
        selectedTextAttributes = [.backgroundColor: config.selectionColor.nsColor(custom: config.selectionCustomHex)]
        baseWritingDirection = config.direction.nsDirection
        refreshFocusDimming(force: true)
        needsDisplay = true
    }

    func installLayoutDelegate() {
        layoutManager?.delegate = self
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateLayoutInsets()
        scheduleImageLayout()
    }

    /// Centers the text column and, in typewriter mode, pads top/bottom so the
    /// first and last lines can sit in the middle of the window.
    func updateLayoutInsets() {
        guard let config else { return }
        let width = bounds.width
        let column = config.textWidth.points.map { min($0, width - 64) } ?? (width - 96)
        let side = max(32, ((width - column) / 2).rounded())
        let visibleHeight = enclosingScrollView?.contentView.bounds.height ?? 600
        let vertical: CGFloat = config.typewriterScrolling ? max(80, (visibleHeight / 2 - config.fontSize).rounded()) : 72
        let inset = NSSize(width: side, height: vertical)
        if textContainerInset != inset { textContainerInset = inset }
        let newColumn = max(80, width - 2 * side)
        if abs(newColumn - columnWidth) >= 1 {
            columnWidth = newColumn
            onColumnWidthChange?(newColumn)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let p = event.locationInWindow
        if hypot(p.x - lastMouse.x, p.y - lastMouse.y) > 4 {
            lastMouse = p
            events?.textViewMouseMoved(self)
        }
        let point = convert(p, from: nil)
        if (event.modifierFlags.contains(.command) && link(at: point) != nil)
            || (config?.hideSyntax == true && taskBox(at: point) != nil) {
            NSCursor.pointingHand.set()
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard config?.hideSyntax == true else { return }
        for (range, _) in attributeRuns(.typeTaskBox, in: visibleCharacterRange()) {
            addCursorRect(checkboxRect(forCharacterAt: range.location).insetBy(dx: -4, dy: -4), cursor: .pointingHand)
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control])
        if flags.isEmpty {
            if config?.typingSounds == true {
                switch event.keyCode {
                case 36, 76: TypingSounds.shared.play(.returnKey)
                case 49: TypingSounds.shared.play(.space)
                case 51, 117: TypingSounds.shared.play(.delete)
                case 123...126, 53: break // arrows, escape
                default: TypingSounds.shared.play(.key)
                }
            }
            events?.textViewDidType(self)
        }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        if events?.textView(self, handleSlashCommand: selector) == true { return }
        if selector == #selector(insertNewline(_:)), config?.continueLists == true, continueListOnNewline() { return }
        if selector == #selector(insertTab(_:)), indentListItem(outdent: false) { return }
        if selector == #selector(insertBacktab(_:)), indentListItem(outdent: true) { return }
        super.doCommand(by: selector)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        guard let config, typed.count == 1, !hasMarkedText() else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        let ns = self.string as NSString
        let sel = replacementRange.location != NSNotFound ? replacementRange : selectedRange()
        let loc = sel.location
        let prev: Character? = loc > 0 ? Character(ns.substring(with: ns.rangeOfComposedCharacterSequence(at: loc - 1))) : nil
        let prev2: Character? = loc > 1 ? Character(ns.substring(with: ns.rangeOfComposedCharacterSequence(at: loc - 2))) : nil
        let inCode = loc > 0 && (textStorage?.attribute(.typeCode, at: loc - 1, effectiveRange: nil) != nil)
        let inComment = loc > 0 && (textStorage?.attribute(.typeComment, at: loc - 1, effectiveRange: nil) != nil)
        let linePrefix = ns.substring(with: NSRange(location: ns.lineRange(for: NSRange(location: loc, length: 0)).location, length: loc - ns.lineRange(for: NSRange(location: loc, length: 0)).location))

        func replacePrevious(_ count: Int, with text: String) {
            super.insertText(text, replacementRange: NSRange(location: loc - count, length: count + sel.length))
        }

        if !inCode {
            switch typed {
            case "\"" where config.smartQuotes:
                super.insertText(Self.opens(prev) ? "\u{201C}" : "\u{201D}", replacementRange: sel); return
            case "'" where config.smartQuotes:
                super.insertText(Self.opens(prev) ? "\u{2018}" : "\u{2019}", replacementRange: sel); return
            case "." where config.smartEllipses && prev == "." && prev2 == ".":
                replacePrevious(2, with: "\u{2026}"); return
            case "-" where config.smartDashes && prev == "-" && !inComment && prev2 != "!" && prev2 != "<"
                && !linePrefix.trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == "-" }):
                replacePrevious(1, with: "\u{2014}"); return
            case ">" where config.smartArrows && !inComment && prev == "-" && prev2 != "-" && !linePrefix.trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == "-" }):
                replacePrevious(1, with: "\u{2192}"); return
            case ">" where config.smartArrows && prev == "=" && prev2 != "=":
                replacePrevious(1, with: "\u{21D2}"); return
            case "-" where config.smartArrows && prev == "<" && !inComment:
                replacePrevious(1, with: "\u{2190}"); return
            default: break
            }
            if config.autoCapitalize, let c = typed.first, c.isLowercase, isSentenceStart(at: loc, linePrefix: linePrefix) {
                super.insertText(typed.uppercased(), replacementRange: sel); return
            }
        }

        super.insertText(string, replacementRange: replacementRange)

        if typed == "/" && linePrefix.trimmingCharacters(in: .whitespaces).isEmpty && !inCode {
            events?.textView(self, didBeginSlashAt: loc)
        }
    }

    private static func opens(_ prev: Character?) -> Bool {
        guard let prev else { return true }
        return prev.isWhitespace || "([{<\u{2014}\u{2013}-/\u{201C}\u{2018}".contains(prev)
    }

    private func isSentenceStart(at loc: Int, linePrefix: String) -> Bool {
        if linePrefix.range(of: #"^\s*(#{1,6}|>|[-*+]|\d+[.)])?\s*(\[[ xX]\]\s*)?$"#, options: .regularExpression) != nil { return true }
        let trimmed = linePrefix.reversed().drop { $0 == " " }
        guard trimmed.count < linePrefix.count, let last = trimmed.first else { return false }
        return ".!?\u{2026}".contains(last)
    }

    // MARK: Lists

    /// Continues Markdown lists / quotes on Return, or ends the list when the item is empty.
    private func continueListOnNewline() -> Bool {
        let sel = selectedRange()
        guard sel.length == 0 else { return false }
        let ns = string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        var line = ns.substring(with: lineRange)
        if line.hasSuffix("\n") { line.removeLast() }
        if textStorage?.attribute(.typeCode, at: max(0, min(sel.location, ns.length) - 1), effectiveRange: nil) != nil, sel.location > 0 { return false }

        let lineNS = line as NSString
        let lineLen = lineNS.length
        var prefix: String?
        var markerLength = 0
        if let m = MDPattern.list.firstMatch(in: line, range: NSRange(location: 0, length: lineLen)) {
            markerLength = m.range.length
            let indent = lineNS.substring(with: m.range(at: 1))
            var marker = lineNS.substring(with: m.range(at: 2))
            if let n = Int(marker.dropLast()) { marker = "\(n + 1)\(marker.last!)" }
            let task = m.range(at: 3).location != NSNotFound ? "[ ] " : ""
            prefix = indent + marker + " " + task
        } else if let m = MDPattern.quote.firstMatch(in: line, range: NSRange(location: 0, length: lineLen)) {
            markerLength = m.range.length
            prefix = lineNS.substring(with: m.range)
        }
        guard let prefix else { return false }

        // Caret must be after the marker.
        guard sel.location - lineRange.location >= markerLength else { return false }

        if lineNS.substring(from: markerLength).trimmingCharacters(in: .whitespaces).isEmpty {
            // Empty item: remove the marker and end the list.
            replace(NSRange(location: lineRange.location, length: lineLen), with: "", caret: lineRange.location)
            return true
        }
        replace(sel, with: "\n" + prefix, caret: sel.location + 1 + (prefix as NSString).length)
        renumberList(after: sel.location + 1)
        return true
    }

    private func indentListItem(outdent: Bool) -> Bool {
        let ns = string as NSString
        let sel = selectedRange()
        let lineRange = ns.lineRange(for: sel)
        let lines = ns.substring(with: lineRange)
        guard lines.split(separator: "\n").allSatisfy({ MDPattern.list.firstMatch(in: String($0), range: NSRange(location: 0, length: ($0 as Substring).utf16.count)) != nil }), !lines.isEmpty else { return false }
        var changed: [String] = []
        for raw in lines.components(separatedBy: "\n") {
            if raw.isEmpty { changed.append(raw); continue }
            if outdent {
                if raw.hasPrefix("    ") { changed.append(String(raw.dropFirst(4))) }
                else if raw.hasPrefix("\t") { changed.append(String(raw.dropFirst())) }
                else if raw.hasPrefix("  ") { changed.append(String(raw.dropFirst(2))) }
                else { changed.append(raw) }
            } else {
                changed.append("    " + raw)
            }
        }
        let result = changed.joined(separator: "\n")
        let delta = (result as NSString).length - lineRange.length
        replace(lineRange, with: result, caret: nil)
        setSelectedRange(sel.length == 0 ? NSRange(location: max(lineRange.location, sel.location + (outdent ? delta : 4)), length: 0) : NSRange(location: lineRange.location, length: (result as NSString).length))
        return true
    }

    /// Renumbers a contiguous ordered list starting at the line containing `location`.
    private func renumberList(after location: Int) {
        let ns = string as NSString
        var lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
        guard let first = MDPattern.list.firstMatch(in: ns.substring(with: lineRange), range: NSRange(location: 0, length: lineRange.length)),
              let start = Int((ns.substring(with: lineRange) as NSString).substring(with: first.range(at: 2)).dropLast()) else { return }
        let indent = (ns.substring(with: lineRange) as NSString).substring(with: first.range(at: 1))
        var expected = start + 1
        var loc = NSMaxRange(lineRange)
        while loc < (string as NSString).length {
            let current = string as NSString
            lineRange = current.lineRange(for: NSRange(location: loc, length: 0))
            let text = current.substring(with: lineRange)
            guard let m = MDPattern.list.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
                  (text as NSString).substring(with: m.range(at: 1)) == indent else { break }
            let markerRange = m.range(at: 2)
            let marker = (text as NSString).substring(with: markerRange)
            guard let n = Int(marker.dropLast()) else { break }
            if n != expected {
                let caret = selectedRange()
                let new = "\(expected)\(marker.last!)"
                replace(NSRange(location: lineRange.location + markerRange.location, length: markerRange.length), with: new, caret: nil)
                setSelectedRange(caret)
            }
            expected += 1
            loc = NSMaxRange((string as NSString).lineRange(for: NSRange(location: loc, length: 0)))
        }
    }

    // MARK: Editing helpers (undoable)

    func replace(_ range: NSRange, with text: String, caret: Int?, select: NSRange? = nil) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        if let select { setSelectedRange(select) } else if let caret { setSelectedRange(NSRange(location: caret, length: 0)) }
    }

    /// Toggles an inline wrapper like `**` around the selection.
    func toggleWrap(_ marker: String, placeholder: String = "") {
        let ns = string as NSString
        var sel = selectedRange()
        let m = (marker as NSString).length
        // Expand an empty selection to the word under the caret.
        if sel.length == 0, placeholder.isEmpty {
            let word = wordRange(at: sel.location)
            if word.length > 0 { sel = word }
        }
        // Markers must hug the text ("==a b==", not "== a b =="), so leave
        // surrounding whitespace (often caught by a drag selection) outside them.
        while sel.length > 0, let u = UnicodeScalar(ns.character(at: sel.location)), CharacterSet.whitespacesAndNewlines.contains(u) {
            sel = NSRange(location: sel.location + 1, length: sel.length - 1)
        }
        while sel.length > 0, let u = UnicodeScalar(ns.character(at: NSMaxRange(sel) - 1)), CharacterSet.whitespacesAndNewlines.contains(u) {
            sel.length -= 1
        }
        // Already wrapped? Unwrap.
        if sel.location >= m, NSMaxRange(sel) + m <= ns.length,
           ns.substring(with: NSRange(location: sel.location - m, length: m)) == marker,
           ns.substring(with: NSRange(location: NSMaxRange(sel), length: m)) == marker {
            let inner = ns.substring(with: sel)
            replace(NSRange(location: sel.location - m, length: sel.length + 2 * m), with: inner, caret: nil,
                    select: NSRange(location: sel.location - m, length: sel.length))
            return
        }
        let inner = sel.length > 0 ? ns.substring(with: sel) : placeholder
        if inner.hasPrefix(marker), inner.hasSuffix(marker), (inner as NSString).length >= 2 * m {
            let stripped = (inner as NSString).substring(with: NSRange(location: m, length: (inner as NSString).length - 2 * m))
            replace(sel, with: stripped, caret: nil, select: NSRange(location: sel.location, length: (stripped as NSString).length))
            return
        }
        replace(sel, with: marker + inner + marker, caret: nil,
                select: NSRange(location: sel.location + m, length: (inner as NSString).length))
    }

    private func wordRange(at location: Int) -> NSRange {
        let ns = string as NSString
        guard ns.length > 0 else { return NSRange(location: location, length: 0) }
        var start = location, end = location
        let letters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'’-"))
        func isWord(_ i: Int) -> Bool {
            guard i >= 0, i < ns.length, let u = UnicodeScalar(ns.character(at: i)) else { return false }
            return letters.contains(u)
        }
        while isWord(start - 1) { start -= 1 }
        while isWord(end) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// Sets (or toggles off) a line prefix such as "## " on every selected line.
    func setLinePrefix(_ newPrefix: String, kind: LinePrefixKind) {
        let ns = string as NSString
        let sel = selectedRange()
        let lineRange = ns.lineRange(for: sel)
        let block = ns.substring(with: lineRange)
        var lines = block.components(separatedBy: "\n")
        let trailingNewline = block.hasSuffix("\n")
        if trailingNewline { lines.removeLast() }

        let pattern: NSRegularExpression = switch kind {
        case .heading: MDPattern.heading
        case .quote: MDPattern.quote
        case .list, .task, .numbered: MDPattern.list
        }
        let allHave = lines.allSatisfy { line in
            guard let m = pattern.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return false }
            return (line as NSString).substring(with: m.range).trimmingCharacters(in: .whitespaces) == newPrefix.trimmingCharacters(in: .whitespaces) || kind == .numbered && (line as NSString).substring(with: m.range(at: 2)).last == "."
        }
        var n = 1
        let updated = lines.map { line -> String in
            var body = line
            for r in [MDPattern.heading, MDPattern.quote, MDPattern.list] {
                body = r.stringByReplacingMatches(in: body, range: NSRange(location: 0, length: (body as NSString).length), withTemplate: "")
            }
            if allHave || (line.trimmingCharacters(in: .whitespaces).isEmpty && lines.count > 1) { return body }
            defer { n += 1 }
            return (kind == .numbered ? "\(n). " : newPrefix) + body
        }
        let result = updated.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        let caretDelta = (result as NSString).length - lineRange.length
        replace(lineRange, with: result, caret: nil)
        if sel.length == 0 {
            setSelectedRange(NSRange(location: min(max(lineRange.location, sel.location + caretDelta), lineRange.location + (result as NSString).length - (trailingNewline ? 1 : 0)), length: 0))
        } else {
            setSelectedRange(NSRange(location: lineRange.location, length: (result as NSString).length - (trailingNewline ? 1 : 0)))
        }
    }

    enum LinePrefixKind { case heading, quote, list, numbered, task }

    func insertSnippet(_ snippet: String, caretOffset: Int? = nil, at range: NSRange? = nil) {
        let r = range ?? selectedRange()
        let ns = string as NSString
        var text = snippet
        // Block snippets start on their own line.
        if snippet.hasPrefix("\n") == false, snippet.contains("\n"), r.location > 0,
           ns.character(at: r.location - 1) != 10 { text = "\n" + text }
        let offset = (caretOffset ?? (snippet as NSString).length) + ((text as NSString).length - (snippet as NSString).length)
        replace(r, with: text, caret: r.location + offset)
    }

    // MARK: Links

    func link(at point: NSPoint) -> URL? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = lm.glyphIndex(for: p, in: tc, fractionOfDistanceThroughGlyph: &fraction)
        guard lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc).contains(p) else { return nil }
        let idx = lm.characterIndexForGlyph(at: glyph)
        guard idx < storage.length, let raw = storage.attribute(.typeLink, at: idx, effectiveRange: nil) as? String else { return nil }
        if let url = URL(string: raw), url.scheme != nil { return url }
        if raw.hasPrefix("/") || raw.hasPrefix("~") { return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath) }
        return URL(string: "https://" + raw)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command), let url = link(at: point) {
            NSWorkspace.shared.open(url)
            return
        }
        if config?.hideSyntax == true, let box = taskBox(at: point) {
            toggleTask(at: box)
            return
        }
        super.mouseDown(with: event)
    }

    /// Location of the checklist box character under `point`, if any.
    private func taskBox(at point: NSPoint) -> Int? {
        guard let storage = textStorage else { return nil }
        for (range, _) in attributeRuns(.typeTaskBox, in: visibleCharacterRange()) {
            let rect = checkboxRect(forCharacterAt: range.location).insetBy(dx: -4, dy: -4)
            if rect.contains(point), range.location < storage.length { return range.location }
        }
        return nil
    }

    private func toggleTask(at boxMid: Int) {
        let ns = string as NSString
        guard boxMid > 0, boxMid + 1 < ns.length else { return }
        let current = ns.substring(with: NSRange(location: boxMid, length: 1))
        let caret = selectedRange()
        replace(NSRange(location: boxMid, length: 1), with: current.lowercased() == "x" ? " " : "x", caret: nil)
        setSelectedRange(caret)
    }

    // MARK: Hidden syntax (glyph generation)

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>,
                       font aFont: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = layoutManager.textStorage, glyphRange.length > 0 else { return 0 }
        let count = glyphRange.length
        var newProps: [NSLayoutManager.GlyphProperty]?
        var newGlyphs: [CGGlyph]?
        for i in 0..<count {
            let ci = charIndexes[i]
            guard ci < storage.length else { continue }
            if storage.attribute(.typeHidden, at: ci, effectiveRange: nil) != nil {
                // Zero-width control glyphs (not .null) so leading hidden syntax stays on its own line.
                if newProps == nil { newProps = Array(UnsafeBufferPointer(start: props, count: count)) }
                newProps![i] = .controlCharacter
            } else if let sub = storage.attribute(.typeGlyph, at: ci, effectiveRange: nil) as? String,
                      let unit = sub.utf16.first {
                var chars = [unit]
                var g: CGGlyph = 0
                if CTFontGetGlyphsForCharacters(aFont as CTFont, &chars, &g, 1) {
                    if newGlyphs == nil { newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: count)) }
                    newGlyphs![i] = g
                }
            }
        }
        guard newProps != nil || newGlyphs != nil else { return 0 }
        let finalGlyphs = newGlyphs ?? Array(UnsafeBufferPointer(start: glyphs, count: count))
        let finalProps = newProps ?? Array(UnsafeBufferPointer(start: props, count: count))
        layoutManager.setGlyphs(finalGlyphs, properties: finalProps, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
        return count
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        if let s = layoutManager.textStorage, charIndex < s.length,
           s.attribute(.typeHidden, at: charIndex, effectiveRange: nil) != nil,
           (s.string as NSString).character(at: charIndex) != 10 {
            return .zeroAdvancement
        }
        return action
    }

    func layoutManager(_ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?, atEnd layoutFinishedFlag: Bool) {
        scheduleImageLayout()
    }

    private func isHidden(_ i: Int) -> Bool {
        guard let s = textStorage, i >= 0, i < s.length else { return false }
        return s.attribute(.typeHidden, at: i, effectiveRange: nil) != nil
    }

    private func isHiddenPrefix(_ i: Int) -> Bool {
        guard let s = textStorage, i >= 0, i < s.length else { return false }
        return s.attribute(.typeHiddenPrefix, at: i, effectiveRange: nil) != nil
    }

    /// Keeps the caret out of the middle of hidden syntax, and after hidden line prefixes.
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        var ranges = ranges
        if config?.hideSyntax == true, ranges.count == 1, let r = ranges.first?.rangeValue, r.length == 0 {
            let old = selectedRange().location
            var loc = r.location
            let ns = string as NSString
            let lineStart = ns.lineRange(for: NSRange(location: min(loc, ns.length), length: 0)).location
            if isHiddenPrefix(loc) && (loc == lineStart || !isHiddenPrefix(loc - 1)) {
                // Never type in front of a hidden heading / quote / checklist prefix.
                while isHiddenPrefix(loc) { loc += 1 }
            } else if isHidden(loc) && isHidden(loc - 1) {
                if loc >= old { while isHidden(loc) { loc += 1 } } else { while isHidden(loc - 1) { loc -= 1 } }
            }
            if loc != r.location { ranges = [NSValue(range: NSRange(location: loc, length: 0))] }
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        updateImageSelection()
    }

    /// Backspace that respects hidden markers: never silently deletes syntax.
    override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange()
        guard config?.hideSyntax == true, sel.length == 0, sel.location > 0 else { super.deleteBackward(sender); return }
        let ns = string as NSString
        var loc = sel.location
        if isHiddenPrefix(loc - 1) {
            // Remove the whole line prefix (heading → body text, quote/task → plain line).
            var start = loc - 1
            while start > 0 && isHiddenPrefix(start - 1) && ns.character(at: start - 1) != 10 { start -= 1 }
            replace(NSRange(location: start, length: loc - start), with: "", caret: start)
            return
        }
        if isHidden(loc - 1) {
            while loc > 0 && isHidden(loc - 1) { loc -= 1 }
            guard loc > 0 else { return }
            if isHiddenPrefix(loc - 1) { super.setSelectedRanges([NSValue(range: NSRange(location: loc, length: 0))], affinity: .downstream, stillSelecting: false); deleteBackward(sender); return }
            let target = ns.rangeOfComposedCharacterSequence(at: loc - 1)
            replace(target, with: "", caret: target.location)
            return
        }
        super.deleteBackward(sender)
    }

    // MARK: Decorations (quote bars, rules, checkboxes)

    private func visibleCharacterRange() -> NSRange {
        guard let lm = layoutManager, let tc = textContainer else { return NSRange(location: 0, length: 0) }
        var rect = visibleRect
        rect.origin.x -= textContainerOrigin.x
        rect.origin.y -= textContainerOrigin.y
        let glyphs = lm.glyphRange(forBoundingRect: rect, in: tc)
        return lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }

    private func attributeRuns(_ key: NSAttributedString.Key, in range: NSRange) -> [(NSRange, Any)] {
        guard let s = textStorage, range.length > 0 else { return [] }
        var runs: [(NSRange, Any)] = []
        s.enumerateAttribute(key, in: NSIntersectionRange(range, NSRange(location: 0, length: s.length))) { v, r, _ in
            if let v { runs.append((r, v)) }
        }
        return runs
    }

    /// The checkbox square drawn over a task's hidden "[ ]", centered on the
    /// line's text (midway between baseline and cap height).
    private func checkboxRect(forCharacterAt index: Int) -> NSRect {
        guard let lm = layoutManager, let config else { return .zero }
        let g = lm.glyphIndexForCharacter(at: index)
        let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        let loc = lm.location(forGlyphAt: g)
        let font = (textStorage?.attribute(.font, at: index, effectiveRange: nil) as? NSFont) ?? .systemFont(ofSize: config.fontSize)
        let size = (config.fontSize * 0.95).rounded()
        let baseline = frag.minY + loc.y
        let midY = baseline - font.capHeight / 2
        let rect = NSRect(x: frag.minX + loc.x + textContainerOrigin.x, y: midY - size / 2 + textContainerOrigin.y, width: size, height: size)
        return backingAlignedRect(rect, options: .alignAllEdgesNearest)
    }

    private func drawCheckbox(in r: NSRect, checked: Bool) {
        let box = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: r.width * 0.26, yRadius: r.width * 0.26)
        if checked {
            NSColor.controlAccentColor.setFill()
            box.fill()
            let mark = NSBezierPath()
            mark.move(to: NSPoint(x: r.minX + r.width * 0.27, y: r.minY + r.height * 0.52))
            mark.line(to: NSPoint(x: r.minX + r.width * 0.44, y: r.minY + r.height * 0.69))
            mark.line(to: NSPoint(x: r.minX + r.width * 0.74, y: r.minY + r.height * 0.33))
            mark.lineWidth = max(1.5, r.width * 0.12)
            mark.lineCapStyle = .round
            mark.lineJoinStyle = .round
            NSColor.white.setStroke()
            mark.stroke()
        } else {
            box.lineWidth = 1.5
            NSColor.secondaryLabelColor.setStroke()
            box.stroke()
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard config?.hideSyntax == true, let lm = layoutManager else { return }
        let visible = visibleCharacterRange()

        // Quote bars
        NSColor.controlAccentColor.withAlphaComponent(0.55).setFill()
        for (range, _) in attributeRuns(.typeQuoteBar, in: visible) {
            let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var union = NSRect.null
            lm.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in union = union.union(used) }
            guard !union.isNull else { continue }
            let bar = NSRect(x: textContainerOrigin.x + 1, y: union.minY + textContainerOrigin.y + 2, width: 3, height: union.height - 4)
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        }

        // Horizontal rules
        NSColor.separatorColor.setFill()
        for (range, _) in attributeRuns(.typeRule, in: visible) {
            let g = lm.glyphIndexForCharacter(at: range.location)
            let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let y = frag.midY + textContainerOrigin.y
            NSRect(x: textContainerOrigin.x, y: y.rounded(), width: columnWidth, height: 1).fill()
        }

        // Checkboxes
        for (range, value) in attributeRuns(.typeTaskBox, in: visible) {
            let checked = (value as? Bool) == true
            let r = checkboxRect(forCharacterAt: range.location)
            guard r.intersects(rect) else { continue }
            drawCheckbox(in: r, checked: checked)
        }
    }

    // MARK: Images

    func resolveImageURL(_ path: String) -> URL? {
        ImageStore.resolve(path, baseURL: documentBaseURL)
    }

    func image(for path: String) -> NSImage? {
        resolveImageURL(path).flatMap { ImageCache.shared.image(at: $0) }
    }

    func scheduleImageLayout() {
        guard !imageLayoutScheduled else { return }
        imageLayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.imageLayoutScheduled = false
            self?.layoutImageViews()
        }
    }

    func layoutImageViews() {
        guard let storage = textStorage, let lm = layoutManager else { return }
        let runs = attributeRuns(.typeImage, in: NSRange(location: 0, length: storage.length))
        while imageViews.count < runs.count {
            let v = ImageBlockView(frame: .zero)
            v.textView = self
            addSubview(v)
            imageViews.append(v)
        }
        while imageViews.count > runs.count { imageViews.removeLast().removeFromSuperview() }
        for (i, (range, value)) in runs.enumerated() {
            guard let spec = value as? ImageSpec else { continue }
            let view = imageViews[i]
            view.configure(image: image(for: spec.path), spec: spec, range: range)
            let g = lm.glyphIndexForCharacter(at: range.location)
            let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let size = spec.displaySize
            let x = baseWritingDirection == .rightToLeft
                ? textContainerOrigin.x + columnWidth - size.width
                : textContainerOrigin.x + frag.minX
            let frame = NSRect(x: x.rounded(), y: (textContainerOrigin.y + frag.minY + 8).rounded(), width: size.width, height: size.height)
            if view.frame != frame { view.frame = frame }
        }
        updateImageSelection()
    }

    private func updateImageSelection() {
        let sel = selectedRange()
        for v in imageViews {
            v.isSelected = sel.length > 0 && NSIntersectionRange(sel, v.sourceRange).length > 0
        }
    }

    func selectImage(_ view: ImageBlockView) {
        window?.makeFirstResponder(self)
        setSelectedRange(view.sourceRange)
    }

    func commitImageWidth(_ width: Int?, spec: ImageSpec, range: NSRange) {
        let ns = string as NSString
        guard NSMaxRange(range) <= ns.length else { return }
        let markdown = ImageSpec.markdown(alt: spec.alt, path: spec.path, width: width)
        replace(range, with: markdown, caret: nil, select: NSRange(location: range.location, length: (markdown as NSString).length))
    }

    func deleteImage(range: NSRange) {
        let ns = string as NSString
        guard NSMaxRange(range) <= ns.length else { return }
        let line = ns.lineRange(for: range)
        replace(line, with: "", caret: line.location)
    }

    /// Inserts saved images, each on its own line, at `location`.
    func insertImages(_ saved: [ImageStore.Saved], at location: Int? = nil) {
        guard !saved.isEmpty else { return }
        let ns = string as NSString
        var range = location.map { NSRange(location: $0, length: 0) } ?? selectedRange()
        range.location = min(range.location, ns.length)
        let lines = saved.map { s in
            let width = ImageStore.defaultWidth(for: s.size, column: columnWidth)
            let alt = s.fileURL.deletingPathExtension().lastPathComponent
            return ImageSpec.markdown(alt: alt, path: s.markdownPath, width: width)
        }
        var text = lines.joined(separator: "\n")
        if range.location > 0, ns.character(at: range.location - 1) != 10 { text = "\n" + text }
        let end = NSMaxRange(range)
        if end >= ns.length || ns.character(at: end) != 10 { text += "\n" }
        replace(range, with: text, caret: range.location + (text as NSString).length)
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if ImageStore.hasImage(pb), let saved = imagePasteHandler?(pb), !saved.isEmpty {
            insertImages(saved)
            return
        }
        super.paste(sender)
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.png, .tiff, .fileURL]
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.png, .tiff, .fileURL]
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if ImageStore.hasImage(pb), let saved = imagePasteHandler?(pb), !saved.isEmpty {
            let point = convert(sender.draggingLocation, from: nil)
            let index = characterIndexForInsertion(at: point)
            let ns = string as NSString
            let lineEnd = NSMaxRange(ns.lineRange(for: NSRange(location: min(index, ns.length), length: 0)))
            let at = lineEnd > 0 && lineEnd <= ns.length && ns.length > 0 && ns.character(at: lineEnd - 1) == 10 ? lineEnd - 1 : lineEnd
            insertImages(saved, at: at)
            window?.makeFirstResponder(self)
            return true
        }
        return super.performDragOperation(sender)
    }

    // MARK: Geometry

    /// Caret rectangle in this view's coordinates.
    func caretRect(at location: Int) -> NSRect {
        guard let lm = layoutManager, let tc = textContainer else { return .zero }
        let ns = string as NSString
        let len = ns.length
        var rect: NSRect
        if len == 0 || (location >= len && ns.character(at: len - 1) == 10) {
            rect = lm.extraLineFragmentRect
            rect.size.width = 1
        } else if location >= len {
            let g = lm.glyphIndexForCharacter(at: len - 1)
            rect = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
            rect.origin.x = rect.maxX
            rect.size.width = 1
        } else {
            let g = lm.glyphIndexForCharacter(at: location)
            rect = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
            rect.size.width = 1
        }
        return rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    // MARK: Typewriter & focus

    func centerCaretIfNeeded(animated: Bool = true) {
        guard config?.typewriterScrolling == true, let clip = enclosingScrollView?.contentView else { return }
        let caret = caretRect(at: selectedRange().location)
        var origin = clip.bounds.origin
        origin.y = max(0, caret.midY - clip.bounds.height / 2)
        guard abs(origin.y - clip.bounds.origin.y) > 1 else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(origin)
            }
        } else {
            clip.setBoundsOrigin(origin)
        }
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    /// Dims everything except the paragraph containing the caret.
    func refreshFocusDimming(force: Bool = false) {
        guard let lm = layoutManager else { return }
        let ns = string as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let config, config.focusMode, ns.length > 0 else {
            if focusedParagraph != nil || force {
                lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
                focusedParagraph = nil
            }
            return
        }
        let current = ns.paragraphRange(for: NSRange(location: min(selectedRange().location, ns.length), length: selectedRange().length))
        guard force || current != focusedParagraph else { return }
        focusedParagraph = current
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        let dim = NSColor.labelColor.dynamicAlpha(max(0.05, config.focusOpacity))
        if current.location > 0 {
            lm.addTemporaryAttribute(.foregroundColor, value: dim, forCharacterRange: NSRange(location: 0, length: current.location))
        }
        if NSMaxRange(current) < ns.length {
            lm.addTemporaryAttribute(.foregroundColor, value: dim, forCharacterRange: NSRange(location: NSMaxRange(current), length: ns.length - NSMaxRange(current)))
        }
    }
}
