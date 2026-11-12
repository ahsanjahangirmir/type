import AppKit

extension NSAttributedString.Key {
    /// Marks characters inside code spans / fenced blocks (smart typing is suppressed there).
    static let typeCode = NSAttributedString.Key("TypeCode")
    /// Marks characters inside `<!-- comments -->`.
    static let typeComment = NSAttributedString.Key("TypeComment")
    /// URL for ⌘-clickable links.
    static let typeLink = NSAttributedString.Key("TypeLink")
    /// Heading level (Int) on heading lines.
    static let typeHeading = NSAttributedString.Key("TypeHeading")
    /// Syntax characters that produce no glyphs ("Hide Markdown syntax").
    static let typeHidden = NSAttributedString.Key("TypeHidden")
    /// Hidden line prefixes (`## `, `> `, `- `); Backspace after one removes it whole.
    static let typeHiddenPrefix = NSAttributedString.Key("TypeHiddenPrefix")
    /// Replacement glyph (String) drawn instead of the character, e.g. "•" for "-".
    static let typeGlyph = NSAttributedString.Key("TypeGlyph")
    /// Checklist box: value is a Bool (checked). The character is drawn as a checkbox.
    static let typeTaskBox = NSAttributedString.Key("TypeTaskBox")
    /// Quote lines get an accent bar instead of `>`.
    static let typeQuoteBar = NSAttributedString.Key("TypeQuoteBar")
    /// Horizontal rules drawn as a hairline.
    static let typeRule = NSAttributedString.Key("TypeRule")
    /// Block image line; value is an `ImageSpec`.
    static let typeImage = NSAttributedString.Key("TypeImage")
    /// A line drawn as a single object (image, divider, hidden code fence, hidden
    /// table divider). The caret never rests inside it. Value is an `AtomicKind` raw value.
    static let typeAtomic = NSAttributedString.Key("TypeAtomic")
    /// Every line of a fenced code block.
    static let typeCodeBlock = NSAttributedString.Key("TypeCodeBlock")
    /// Table rows; value is an `NSValue` holding the whole table's range.
    static let typeTable = NSAttributedString.Key("TypeTable")
}

enum AtomicKind: String {
    case image, rule, fence, tableDivider
}

/// A Markdown image that sits alone on its line and is rendered as a block.
final class ImageSpec: NSObject {
    let alt: String
    let path: String
    let width: CGFloat?
    let displaySize: CGSize
    init(alt: String, path: String, width: CGFloat?, displaySize: CGSize) {
        self.alt = alt; self.path = path; self.width = width; self.displaySize = displaySize
    }
    override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? ImageSpec else { return false }
        return o.path == path && o.width == width && o.displaySize == displaySize && o.alt == alt
    }
    override var hash: Int { path.hashValue ^ Int(displaySize.width) }

    private static let widthRegex = try! NSRegularExpression(pattern: #"width=(\d+)"#)
    static func width(fromTitle title: String) -> CGFloat? {
        let ns = title as NSString
        guard let m = widthRegex.firstMatch(in: title, range: NSRange(location: 0, length: ns.length)),
              let w = Double(ns.substring(with: m.range(at: 1))) else { return nil }
        return CGFloat(w)
    }

    /// The canonical Markdown for this image at `width`.
    static func markdown(alt: String, path: String, width: Int?) -> String {
        width.map { "![\(alt)](\(path) \"width=\($0)\")" } ?? "![\(alt)](\(path))"
    }
}

/// Ranges that span multiple paragraphs and therefore need a document-wide scan.
struct BlockRanges: Equatable {
    var code: [NSRange] = []
    var comments: [NSRange] = []
    /// Pipe tables (header, divider, rows), each a run of whole lines without the final newline.
    var tables: [NSRange] = []

    func intersects(_ range: NSRange) -> Bool {
        let probe = NSRange(location: max(0, range.location - 1), length: range.length + 2)
        return code.contains { NSIntersectionRange($0, probe).length > 0 }
            || comments.contains { NSIntersectionRange($0, probe).length > 0 }
    }
}

/// Live Markdown styling: headings, emphasis, lists, quotes, code, links,
/// comments and tables are styled in place. Syntax is either shown quietly
/// hidden entirely.
final class MarkdownStyler {
    private(set) var config: EditorConfig
    private var fontCache: [String: NSFont] = [:]

    /// Width available to block images (the text column).
    var columnWidth: CGFloat = 700
    /// Resolves an image path from the Markdown source to a loaded image.
    var imageProvider: ((String) -> NSImage?)?

    init(config: EditorConfig) { self.config = config }

    func update(config: EditorConfig) {
        if config.fontChoice != self.config.fontChoice || config.customFontFamily != self.config.customFontFamily || config.fontSize != self.config.fontSize {
            fontCache.removeAll()
        }
        self.config = config
    }

    // MARK: Fonts

    func font(scale: CGFloat = 1, bold: Bool = false, italic: Bool = false, mono: Bool = false) -> NSFont {
        let size = (config.fontSize * scale).rounded()
        let key = "\(size)-\(bold)-\(italic)-\(mono)"
        if let f = fontCache[key] { return f }
        var base: NSFont
        if mono {
            base = .monospacedSystemFont(ofSize: size * 0.9, weight: bold ? .semibold : .regular)
        } else {
            base = Self.baseFont(choice: config.fontChoice, family: config.customFontFamily, size: size)
        }
        var traits = base.fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        if traits != base.fontDescriptor.symbolicTraits {
            let desc = base.fontDescriptor.withSymbolicTraits(traits)
            base = NSFont(descriptor: desc, size: base.pointSize) ?? base
        }
        fontCache[key] = base
        return base
    }

    static func baseFont(choice: FontChoice, family: String, size: CGFloat) -> NSFont {
        let system = NSFont.systemFont(ofSize: size)
        switch choice {
        case .serif:
            return system.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? system
        case .rounded:
            return system.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? system
        case .sans:
            return system
        case .mono:
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        case .custom:
            return NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) ?? system
        }
    }

    // MARK: Colors

    var textColor: NSColor { .labelColor }
    var syntaxColor: NSColor { .tertiaryLabelColor }
    var accentColor: NSColor { .controlAccentColor }
    var codeBackground: NSColor { NSColor.labelColor.dynamicAlpha(0.06) }
    var commentColor: NSColor { config.commentTint.nsColor }

    // MARK: Paragraph style

    func paragraphStyle(headIndent: CGFloat = 0, firstLineIndent: CGFloat = 0, spacingBefore: CGFloat = 0, scale: CGFloat = 1) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = config.lineHeight
        p.paragraphSpacing = config.paragraphSpacing ? config.fontSize * 0.5 : 0
        p.paragraphSpacingBefore = spacingBefore
        p.headIndent = headIndent
        p.firstLineHeadIndent = firstLineIndent
        p.baseWritingDirection = config.direction.nsDirection
        p.alignment = .natural
        return p
    }

    /// Code and table lines sit flush against each other.
    var tightParagraphStyle: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = max(1.0, config.lineHeight * 0.9)
        p.baseWritingDirection = config.direction.nsDirection
        return p
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: font(), .foregroundColor: textColor, .paragraphStyle: paragraphStyle()]
    }

    // MARK: Block scan

    private static let fenceRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*(`{3,}|~{3,})[^\n]*(?:\n(?:[\s\S]*?\n)?[ \t]*\1[ \t]*(?=\n|\z)|[\s\S]*\z)"#,
        options: [.anchorsMatchLines])
    private static let commentRegex = try! NSRegularExpression(pattern: #"(?<!\\)<!--[\s\S]*?(?:-->|\z)"#)

    static func scanBlocks(_ ns: NSString) -> BlockRanges {
        let all = NSRange(location: 0, length: ns.length)
        // Regex scans of a long document cost milliseconds per keystroke. One pass over
        // the characters rules out fences and comments, and finds table lines directly.
        var chars = [unichar](repeating: 0, count: ns.length)
        ns.getCharacters(&chars, range: all)
        var hasFence = false, hasComment = false
        for (i, c) in chars.enumerated() {
            if c == 0x60 || c == 0x7E { hasFence = true }  // ` ~
            else if c == 0x3C, i + 3 < chars.count, chars[i + 1] == 0x21, chars[i + 2] == 0x2D, chars[i + 3] == 0x2D { hasComment = true }
        }
        let code = hasFence ? fenceRegex.matches(in: ns as String, range: all).map(\.range) : []
        let comments = hasComment ? commentRegex.matches(in: ns as String, range: all).map(\.range)
            .filter { c in !code.contains { NSIntersectionRange($0, c).length > 0 } } : []
        let tables = pipeLineBlocks(chars).filter { t in
            guard !code.contains(where: { NSIntersectionRange($0, t).length > 0 }) else { return false }
            let lines = ns.substring(with: t).components(separatedBy: "\n")
            return lines.count >= 2 && MDPattern.tableDivider.firstMatch(in: lines[1], range: NSRange(location: 0, length: (lines[1] as NSString).length)) != nil
        }
        return BlockRanges(code: code, comments: comments, tables: tables)
    }

    /// Runs of consecutive lines whose first non-blank character is `|`
    /// (without the final newline): the candidates for tables.
    private static func pipeLineBlocks(_ chars: [unichar]) -> [NSRange] {
        var blocks: [NSRange] = []
        var start: Int?, end = 0
        var i = 0
        while i < chars.count {
            var j = i
            while j < chars.count, chars[j] == 0x20 || chars[j] == 0x09 { j += 1 }
            var lineEnd = j
            while lineEnd < chars.count, chars[lineEnd] != 0x0A { lineEnd += 1 }
            if j < chars.count, chars[j] == 0x7C {
                if start == nil { start = i }
                end = lineEnd
            } else if let s = start {
                blocks.append(NSRange(location: s, length: end - s))
                start = nil
            }
            i = lineEnd + 1
        }
        if let s = start { blocks.append(NSRange(location: s, length: end - s)) }
        return blocks
    }

    // MARK: Styling

    /// Restyle `range` (expanded to whole paragraphs) of `storage`.
    func style(_ storage: NSTextStorage, range requested: NSRange? = nil, blocks: BlockRanges) {
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        var range = requested.map { ns.paragraphRange(for: NSIntersectionRange($0, full)) } ?? full
        if range.location == NSNotFound { range = full }
        // A list item's spacing depends on the line after it, so restyle the line above too.
        if range.location > 0 { range = NSUnionRange(range, ns.paragraphRange(for: NSRange(location: range.location - 1, length: 0))) }
        // Column widths depend on every row, so a table is always restyled whole.
        let probe = NSRange(location: max(0, range.location - 1), length: min(full.length - max(0, range.location - 1), range.length + 2))
        let tables = blocks.tables.filter { NSIntersectionRange($0, probe).length > 0 || NSLocationInRange(range.location, $0) }
        for t in tables { range = NSUnionRange(range, ns.paragraphRange(for: t)) }

        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: range)

        ns.enumerateSubstrings(in: range, options: [.byParagraphs, .substringNotRequired]) { _, line, enclosing, _ in
            self.styleLine(storage, ns: ns, line: line, enclosing: enclosing, blocks: blocks)
        }
        for t in tables { alignTable(storage, ns: ns, table: t) }

        for comment in blocks.comments where NSIntersectionRange(comment, range).length > 0 {
            let r = NSIntersectionRange(comment, range)
            storage.addAttributes([
                .foregroundColor: commentColor.dynamicBlend(0.25, with: .labelColor),
                .backgroundColor: commentColor.dynamicAlpha(0.12),
                .typeComment: true,
            ], range: r)
            addTraits(storage, r, italic: true)
            if NSLocationInRange(comment.location, range) { hideRange(storage, NSRange(location: comment.location, length: 4)) }
            let end = NSMaxRange(comment)
            if comment.length >= 7, ns.substring(with: NSRange(location: end - 3, length: 3)) == "-->", NSLocationInRange(end - 1, range) {
                hideRange(storage, NSRange(location: end - 3, length: 3))
            }
        }
        storage.endEditing()
    }

    private func styleLine(_ s: NSTextStorage, ns: NSString, line: NSRange, enclosing: NSRange, blocks: BlockRanges) {
        // Fenced code blocks
        if let block = blocks.code.first(where: { NSIntersectionRange($0, enclosing).length > 0 || NSLocationInRange(line.location, $0) }) {
            s.addAttributes([.font: font(mono: true), .backgroundColor: codeBackground, .typeCode: true,
                             .typeCodeBlock: true, .paragraphStyle: tightParagraphStyle], range: enclosing)
            let text = ns.substring(with: line)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let isFence = line.location == block.location || ((trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")) && NSMaxRange(line) >= NSMaxRange(block) - 1)
            if isFence {
                s.addAttribute(.foregroundColor, value: syntaxColor, range: line)
                hideRange(s, line)
                if line.length > 0 { s.addAttribute(.typeAtomic, value: AtomicKind.fence.rawValue, range: line) }
                let p = NSMutableParagraphStyle()
                p.lineHeightMultiple = 0.45
                s.addAttribute(.paragraphStyle, value: p, range: enclosing)
            }
            return
        }
        guard line.length > 0 else {
            // Blank separator lines: keep them short so Markdown's blank lines
            // plus paragraph spacing don't produce oversized gaps.
            let p = NSMutableParagraphStyle()
            p.lineHeightMultiple = 0.55
            p.baseWritingDirection = config.direction.nsDirection
            s.addAttribute(.paragraphStyle, value: p, range: enclosing)
            return
        }
        let text = ns.substring(with: line)
        let textRange = NSRange(location: 0, length: (text as NSString).length)
        var contentStart = line.location

        // Block images
        if let m = MDPattern.blockImage.firstMatch(in: text, range: textRange), styleImageLine(s, text: text as NSString, match: m, line: line, enclosing: enclosing) {
            return
        }

        // Headings
        if let m = MDPattern.heading.firstMatch(in: text, range: textRange) {
            let level = m.range(at: 1).length
            let scales: [CGFloat] = [1.85, 1.5, 1.28, 1.14, 1.05, 1.0]
            let scale = scales[level - 1]
            s.addAttributes([
                .font: font(scale: scale, bold: true),
                .paragraphStyle: paragraphStyle(spacingBefore: config.fontSize * (level <= 2 ? 0.9 : 0.5), scale: scale),
                .typeHeading: level,
            ], range: line)
            marker(s, NSRange(location: line.location, length: m.range.length), prefix: true)
            styleInline(s, ns: ns, range: NSRange(location: line.location + m.range.length, length: line.length - m.range.length))
            return
        }

        // Horizontal rule
        if MDPattern.rule.firstMatch(in: text, range: textRange) != nil {
            s.addAttributes([.foregroundColor: syntaxColor, .kern: config.fontSize * 0.4], range: line)
            hideRange(s, line)
            s.addAttributes([.typeRule: true, .typeAtomic: AtomicKind.rule.rawValue], range: line)
            return
        }

        // Tables
        if let table = blocks.tables.first(where: { NSLocationInRange(line.location, $0) }) {
            styleTableRow(s, ns: ns, text: text, line: line, enclosing: enclosing, table: table)
            return
        }
        if text.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
            s.addAttribute(.font, value: font(scale: 0.95, mono: true), range: line)
            s.addAttribute(.paragraphStyle, value: tightParagraphStyle, range: enclosing)
            for m in MDPattern.pipe.matches(in: text, range: textRange) {
                s.addAttribute(.foregroundColor, value: syntaxColor, range: NSRange(location: line.location + m.range.location, length: m.range.length))
            }
            if MDPattern.tableDivider.firstMatch(in: text, range: textRange) != nil {
                s.addAttribute(.foregroundColor, value: syntaxColor, range: line)
            }
            styleInline(s, ns: ns, range: line)
            return
        }

        // Block quotes
        if let m = MDPattern.quote.firstMatch(in: text, range: textRange) {
            let markerRange = NSRange(location: line.location, length: m.range.length)
            s.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: line)
            addTraits(s, line, italic: true)
            marker(s, markerRange, prefix: true)
            s.addAttribute(.typeQuoteBar, value: true, range: enclosing)
            let indent = config.fontSize * 1.1
            s.addAttribute(.paragraphStyle, value: paragraphStyle(headIndent: indent, firstLineIndent: indent), range: enclosing)
            contentStart = NSMaxRange(markerRange)
        }
        // Lists & tasks
        else if let m = MDPattern.list.firstMatch(in: text, range: textRange) {
            let markerRange = NSRange(location: line.location, length: m.range.length)
            let bullet = NSRange(location: line.location + m.range(at: 2).location, length: m.range(at: 2).length)
            let isTask = m.range(at: 3).location != NSNotFound
            s.addAttribute(.foregroundColor, value: accentColor, range: bullet)
            var visiblePrefix = ns.substring(with: markerRange)

            if isTask {
                let box = NSRange(location: line.location + m.range(at: 3).location, length: m.range(at: 3).length)
                s.addAttribute(.foregroundColor, value: accentColor, range: box)
                let done = (text as NSString).substring(with: m.range(at: 3)).lowercased().contains("x")
                if done {
                    let rest = NSRange(location: NSMaxRange(markerRange), length: NSMaxRange(line) - NSMaxRange(markerRange))
                    s.addAttributes([.foregroundColor: NSColor.secondaryLabelColor, .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: rest)
                }
                // "- [ ] " → checkbox glyph: hide the bullet and brackets, draw the box over the middle char.
                let indentLen = m.range(at: 1).length
                hideRange(s, NSRange(location: line.location + indentLen, length: box.location - line.location - indentLen), prefix: true)
                hideRange(s, NSRange(location: box.location, length: 1), prefix: true)
                hideRange(s, NSRange(location: box.location + 2, length: 1), prefix: true)
                let mid = NSRange(location: box.location + 1, length: 1)
                let boxWidth = config.fontSize * 1.25
                let charWidth = (ns.substring(with: mid) as NSString).size(withAttributes: [.font: font()]).width
                s.addAttributes([.foregroundColor: NSColor.clear, .typeTaskBox: done, .kern: boxWidth - charWidth, .typeHiddenPrefix: true], range: mid)
                // The whitespace after "]" belongs to the prefix (caret never lands before it).
                let trailing = NSRange(location: box.location + 3, length: max(0, box.length - 3))
                s.addAttribute(.typeHiddenPrefix, value: true, range: trailing)
                let markerWidth = boxWidth + (ns.substring(with: trailing) as NSString).size(withAttributes: [.font: font()]).width
                indentList(s, indent: NSRange(location: line.location, length: m.range(at: 1).length), markerWidth: markerWidth, enclosing: enclosing)
                styleInline(s, ns: ns, range: NSRange(location: NSMaxRange(markerRange), length: NSMaxRange(line) - NSMaxRange(markerRange)))
                return
            } else if "-*+".contains(ns.substring(with: bullet)) {
                s.addAttribute(.typeGlyph, value: "•", range: bullet)
                visiblePrefix = visiblePrefix.replacingOccurrences(of: ns.substring(with: bullet), with: "•")
                // Give "• " the width of "1. " so bulleted and numbered text start together, a word-gap
                // from the bullet (the old checkbox-wide gap read as an extra space).
                let natural = ((visiblePrefix as NSString).substring(from: m.range(at: 1).length) as NSString).size(withAttributes: [.font: font()]).width
                let target = ("1. " as NSString).size(withAttributes: [.font: font()]).width
                if target > natural { s.addAttribute(.kern, value: target - natural, range: bullet) }
            }
            let indentLength = m.range(at: 1).length
            let markerText = (visiblePrefix as NSString).substring(from: indentLength)
            var markerWidth = (markerText as NSString).size(withAttributes: [.font: font()]).width
            if let kern = s.attribute(.kern, at: bullet.location, effectiveRange: nil) as? CGFloat { markerWidth += kern }
            indentList(s, indent: NSRange(location: line.location, length: indentLength), markerWidth: markerWidth, enclosing: enclosing)
            contentStart = NSMaxRange(markerRange)
        }

        styleInline(s, ns: ns, range: NSRange(location: contentStart, length: NSMaxRange(line) - contentStart))
    }

    /// Indents a list item: the item sits `listIndent` in from the margin, each
    /// nesting level (a tab or four spaces) steps in by `levelIndent`, and wrapped
    /// lines align with the text after the marker.
    private func indentList(_ s: NSTextStorage, indent: NSRange, markerWidth: CGFloat, enclosing: NSRange) {
        let base = (config.fontSize * 1.2).rounded()
        let level = (config.fontSize * 1.5).rounded()
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font()]).width
        let ns = s.string as NSString
        var leading: CGFloat = 0
        for i in indent.location..<NSMaxRange(indent) {
            if ns.character(at: i) == 9 {
                leading = (leading / level).rounded(.down) * level + level
            } else {
                s.addAttribute(.kern, value: level / 4 - spaceWidth, range: NSRange(location: i, length: 1))
                leading += level / 4
            }
        }
        let p = paragraphStyle(headIndent: base + leading + markerWidth, firstLineIndent: base).mutableCopy() as! NSMutableParagraphStyle
        p.tabStops = (1...12).map { NSTextTab(textAlignment: .natural, location: base + CGFloat($0) * level) }
        p.defaultTabInterval = level
        // Items of one list sit close together, like Word and Notes; the gap comes after the list.
        let next = NSMaxRange(enclosing)
        if next < ns.length {
            let nextLine = ns.lineRange(for: NSRange(location: next, length: 0))
            if MDPattern.list.firstMatch(in: ns.substring(with: nextLine), range: NSRange(location: 0, length: nextLine.length)) != nil {
                p.paragraphSpacing = (config.fontSize * 0.2).rounded()
            }
        }
        s.addAttribute(.paragraphStyle, value: p, range: enclosing)
    }

    /// Renders an image line as a block (glyphs hidden, height reserved for the overlay view).
    private func styleImageLine(_ s: NSTextStorage, text: NSString, match m: NSTextCheckingResult, line: NSRange, enclosing: NSRange) -> Bool {
        let alt = text.substring(with: m.range(at: 1))
        let path = text.substring(with: m.range(at: 2))
        var width: CGFloat?
        if m.range(at: 3).location != NSNotFound {
            width = ImageSpec.width(fromTitle: text.substring(with: m.range(at: 3)))
        }
        guard let image = imageProvider?(path), image.size.width > 0 else { return false }
        let maxWidth = max(80, columnWidth)
        let w = min(width ?? image.size.width, maxWidth)
        let size = CGSize(width: w.rounded(), height: (w * image.size.height / image.size.width).rounded())
        let spec = ImageSpec(alt: alt, path: path, width: width, displaySize: size)

        s.addAttributes([.typeHidden: true, .typeImage: spec, .typeAtomic: AtomicKind.image.rawValue], range: line)
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = size.height + 16
        p.maximumLineHeight = size.height + 16
        p.paragraphSpacing = config.paragraphSpacing ? config.fontSize * 0.5 : 0
        p.baseWritingDirection = config.direction.nsDirection
        s.addAttribute(.paragraphStyle, value: p, range: enclosing)
        return true
    }

    // MARK: Tables

    /// Cell padding on each side of a table cell.
    var tableCellPadding: CGFloat { (config.fontSize * 0.6).rounded() }

    /// Vertical padding above and below the text of each table row.
    static func tableRowPadding(fontSize: CGFloat) -> CGFloat { (fontSize * 0.42).rounded() }

    private static func width(of text: String, in font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    private func tableFont(header: Bool) -> NSFont {
        font(bold: header)
    }

    /// A table row: an even grid (pipes become cell
    /// borders, the `---` row a hairline).
    private func styleTableRow(_ s: NSTextStorage, ns: NSString, text: String, line: NSRange, enclosing: NSRange, table: NSRange) {
        let isHeader = line.location == table.location
        let isDivider = !isHeader && MDPattern.tableDivider.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
        s.addAttributes([.font: tableFont(header: isHeader), .typeTable: NSValue(range: table)], range: enclosing)
        let p = NSMutableParagraphStyle()
        p.baseWritingDirection = config.direction.nsDirection
        p.lineBreakMode = .byClipping
        if isDivider {
            p.minimumLineHeight = 1
            p.maximumLineHeight = 1
            s.addAttribute(.paragraphStyle, value: p, range: enclosing)
            hideRange(s, line)
            s.addAttribute(.typeAtomic, value: AtomicKind.tableDivider.rawValue, range: line)
            return
        }
        let pad = Self.tableRowPadding(fontSize: config.fontSize)
        p.paragraphSpacingBefore = pad
        p.paragraphSpacing = pad
        p.lineHeightMultiple = 1.05
        s.addAttribute(.paragraphStyle, value: p, range: enclosing)
        let pipeFont = tableFont(header: false)
        // A hidden pipe is drawn as a space with the pipe's advance: the grid
        // owns the borders, and no temporary colour (focus dimming, typing
        // fades) can bring the glyph back.
        let pipeKern = Self.width(of: "|", in: pipeFont) - Self.width(of: " ", in: pipeFont)
        for i in Self.pipes(in: text) {
            // Same pipe width in every row (a bold header pipe is wider), so borders line up.
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.clear, .font: pipeFont]
            attributes[.typeGlyph] = " "; attributes[.kern] = pipeKern
            s.addAttributes(attributes, range: NSRange(location: line.location + i, length: 1))
        }
        if isDivider {
            s.addAttribute(.foregroundColor, value: syntaxColor, range: line)
            return
        }
        styleInline(s, ns: ns, range: line)
    }

    /// Offsets of the cell-border pipes in a table row (escaped `\|` and pipes in code are skipped).
    static func pipes(in row: String) -> [Int] {
        let ns = row as NSString
        let (escapes, code) = MarkdownEscapes.scan(ns)
        let escaped = Set(escapes.map { $0 + 1 })
        return (0..<ns.length).filter { i in
            ns.character(at: i) == 124 && !escaped.contains(i) && !code.contains { NSLocationInRange(i, $0) }
        }
    }

    /// Pads every cell with kerning so the columns line up.
    private func alignTable(_ s: NSTextStorage, ns: NSString, table: NSRange) {
        guard NSMaxRange(table) <= ns.length else { return }
        struct Cell { var lead: NSRange; var content: NSRange; var trail: NSRange; var pipe: Int; var closed: Bool }
        var rows: [(line: NSRange, divider: Bool, cells: [Cell])] = []
        var loc = table.location
        while loc < NSMaxRange(table) {
            var line = ns.lineRange(for: NSRange(location: loc, length: 0))
            loc = NSMaxRange(line)
            if line.length > 0, ns.character(at: NSMaxRange(line) - 1) == 10 { line.length -= 1 }
            let text = ns.substring(with: line)
            let divider = rows.count == 1 && MDPattern.tableDivider.firstMatch(in: text, range: NSRange(location: 0, length: line.length)) != nil
            let pipes = Self.pipes(in: text)
            guard !pipes.isEmpty else { rows.append((line, divider, [])); continue }
            var cells: [Cell] = []
            for (n, p) in pipes.enumerated() {
                let end = n + 1 < pipes.count ? pipes[n + 1] : line.length
                guard end > p + 1 || n + 1 < pipes.count else { continue }
                var a = p + 1, b = end
                while a < b, Self.isBlank(ns.character(at: line.location + a)) { a += 1 }
                while b > a, Self.isBlank(ns.character(at: line.location + b - 1)) { b -= 1 }
                cells.append(Cell(lead: NSRange(location: line.location + p + 1, length: a - p - 1),
                                  content: NSRange(location: line.location + a, length: b - a),
                                  trail: NSRange(location: line.location + b, length: end - b),
                                  pipe: line.location + p, closed: n + 1 < pipes.count))
            }
            rows.append((line, divider, cells))
        }
        let columns = rows.map { $0.cells.count }.max() ?? 0
        guard columns > 0 else { return }
        var widths = [CGFloat](repeating: (config.fontSize * 3).rounded(), count: columns)
        for row in rows where !row.divider {
            for (c, cell) in row.cells.enumerated() {
                widths[c] = max(widths[c], visibleWidth(s, cell.content).rounded(.up))
            }
        }
        let pad = tableCellPadding
        for row in rows where !row.divider {
            for (c, cell) in row.cells.enumerated() where cell.closed {
                // Space after the left border, then fill the cell out to its column width.
                addKern(s, at: cell.pipe, pad - visibleWidth(s, cell.lead))
                let used = visibleWidth(s, cell.content) + visibleWidth(s, cell.trail)
                let fill = widths[c] + pad - used
                let tail = NSUnionRange(cell.content, cell.trail)
                if let last = lastVisibleCharacter(s, in: tail.length > 0 ? tail : cell.lead) {
                    addKern(s, at: last, fill)
                } else {
                    addKern(s, at: cell.pipe, fill)
                }
            }
        }
    }

    private static func isBlank(_ c: unichar) -> Bool { c == 32 || c == 9 }

    private func addKern(_ s: NSTextStorage, at index: Int, _ amount: CGFloat) {
        let current = (s.attribute(.kern, at: index, effectiveRange: nil) as? CGFloat) ?? 0
        s.addAttribute(.kern, value: current + amount, range: NSRange(location: index, length: 1))
    }

    private func lastVisibleCharacter(_ s: NSTextStorage, in range: NSRange) -> Int? {
        var i = NSMaxRange(range) - 1
        while i >= range.location {
            if s.attribute(.typeHidden, at: i, effectiveRange: nil) == nil { return i }
            i -= 1
        }
        return nil
    }

    /// Width of the characters in `range` that are actually drawn.
    private func visibleWidth(_ s: NSTextStorage, _ range: NSRange) -> CGFloat {
        guard range.length > 0 else { return 0 }
        var width: CGFloat = 0
        s.enumerateAttribute(.typeHidden, in: range) { hidden, run, _ in
            guard hidden == nil else { return }
            width += s.attributedSubstring(from: run).size().width
        }
        return width
    }

    private func styleInline(_ s: NSTextStorage, ns: NSString, range: NSRange) {
        guard range.length > 0 else { return }
        let source = ns.substring(with: range)
        // Escaped characters are hidden behind placeholders so no pattern can use them as syntax.
        let str = MarkdownEscapes.masked(source)
        let base = range.location
        let all = NSRange(location: 0, length: (str as NSString).length)
        func at(_ r: NSRange) -> NSRange { NSRange(location: r.location + base, length: r.length) }
        for e in MarkdownEscapes.scan(source as NSString).escapes {
            let r = NSRange(location: base + e, length: 1)
            hideRange(s, r)
            s.addAttribute(.typeEscape, value: true, range: r)
        }
        var codeSpans: [NSRange] = []

        for m in MDPattern.codeSpan.matches(in: str, range: all) {
            let r = at(m.range)
            codeSpans.append(r)
            s.addAttributes([.font: font(mono: true), .backgroundColor: codeBackground, .typeCode: true], range: r)
            let tick = m.range(at: 1).length
            marker(s, NSRange(location: r.location, length: tick))
            marker(s, NSRange(location: NSMaxRange(r) - tick, length: tick))
        }
        func outsideCode(_ r: NSRange) -> Bool { !codeSpans.contains { NSIntersectionRange($0, r).length > 0 } }

        for m in MDPattern.boldItalic.matches(in: str, range: all) where outsideCode(at(m.range)) {
            let r = at(m.range)
            addTraits(s, r, bold: true, italic: true)
            marker(s, NSRange(location: r.location, length: 3))
            marker(s, NSRange(location: NSMaxRange(r) - 3, length: 3))
        }
        for regex in [MDPattern.boldStar, MDPattern.boldUnderscore] {
            for m in regex.matches(in: str, range: all) where outsideCode(at(m.range)) {
                let r = at(m.range)
                addTraits(s, r, bold: true)
                marker(s, NSRange(location: r.location, length: 2))
                marker(s, NSRange(location: NSMaxRange(r) - 2, length: 2))
            }
        }
        for regex in [MDPattern.italicStar, MDPattern.italicUnderscore] {
            for m in regex.matches(in: str, range: all) where outsideCode(at(m.range)) {
                let r = at(m.range)
                addTraits(s, r, italic: true)
                marker(s, NSRange(location: r.location, length: 1))
                marker(s, NSRange(location: NSMaxRange(r) - 1, length: 1))
            }
        }
        for m in MDPattern.strike.matches(in: str, range: all) where outsideCode(at(m.range)) {
            let r = at(m.range)
            s.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.secondaryLabelColor], range: r)
            marker(s, NSRange(location: r.location, length: 2))
            marker(s, NSRange(location: NSMaxRange(r) - 2, length: 2))
        }
        for m in MDPattern.highlight.matches(in: str, range: all) where outsideCode(at(m.range)) {
            let r = at(m.range)
            s.addAttribute(.backgroundColor, value: NSColor.systemYellow.dynamicAlpha(0.35), range: r)
            marker(s, NSRange(location: r.location, length: 2))
            marker(s, NSRange(location: NSMaxRange(r) - 2, length: 2))
        }
        var linkRanges: [NSRange] = []
        for m in MDPattern.link.matches(in: str, range: all) where outsideCode(at(m.range)) {
            let whole = at(m.range)
            linkRanges.append(whole)
            let isImage = m.range(at: 1).length > 0
            let label = at(m.range(at: 2))
            dim(s, whole)
            s.addAttribute(.foregroundColor, value: isImage ? NSColor.secondaryLabelColor : accentColor, range: label)
            if !isImage {
                s.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: label)
                s.addAttribute(.underlineColor, value: accentColor.dynamicAlpha(0.35), range: label)
            }
            let urlRange = at(m.range(at: 3))
            let url = MarkdownEscapes.unescaped(ns.substring(with: urlRange))
            let scheme = LinkDisplay.schemeLength(url)
            if label.length == 0, !isImage, scheme < urlRange.length {
                // No label: the address (without its scheme) stands in for it.
                let shown = NSRange(location: urlRange.location + scheme, length: urlRange.length - scheme)
                hideRange(s, NSRange(location: whole.location, length: shown.location - whole.location))
                hideRange(s, NSRange(location: NSMaxRange(shown), length: NSMaxRange(whole) - NSMaxRange(shown)))
                s.addAttributes([.foregroundColor: accentColor, .underlineStyle: NSUnderlineStyle.single.rawValue,
                                 .underlineColor: accentColor.dynamicAlpha(0.35)], range: shown)
                s.addAttribute(.typeLink, value: url, range: whole)
                s.addAttribute(.toolTip, value: url, range: shown)
                continue
            }
            hideRange(s, NSRange(location: whole.location, length: label.location - whole.location))
            hideRange(s, NSRange(location: NSMaxRange(label), length: NSMaxRange(whole) - NSMaxRange(label)))
            s.addAttribute(.typeLink, value: url, range: whole)
            s.addAttribute(.toolTip, value: url, range: label)
        }
        for m in MDPattern.bareURL.matches(in: str, range: all) where outsideCode(at(m.range)) && !linkRanges.contains(where: { NSIntersectionRange($0, at(m.range)).length > 0 }) {
            s.addAttributes([.foregroundColor: accentColor, .typeLink: MarkdownEscapes.unescaped(ns.substring(with: at(m.range)))], range: at(m.range))
        }
    }

    /// A syntax marker: dimmed and hidden.
    private func marker(_ s: NSTextStorage, _ r: NSRange, prefix: Bool = false) {
        dim(s, r)
        hideRange(s, r, prefix: prefix)
    }

    private func hideRange(_ s: NSTextStorage, _ r: NSRange, prefix: Bool = false) {
        guard r.length > 0 else { return }
        s.addAttribute(.typeHidden, value: true, range: r)
        if prefix { s.addAttribute(.typeHiddenPrefix, value: true, range: r) }
    }

    private func dim(_ s: NSTextStorage, _ r: NSRange) {
        s.addAttribute(.foregroundColor, value: syntaxColor, range: r)
    }

    /// Adds bold/italic traits to whatever fonts are already in `range`.
    func addTraits(_ s: NSTextStorage, _ range: NSRange, bold: Bool = false, italic: Bool = false) {
        s.enumerateAttribute(.font, in: range) { value, sub, _ in
            guard let f = value as? NSFont else { return }
            var traits = f.fontDescriptor.symbolicTraits
            if bold { traits.insert(.bold) }
            if italic { traits.insert(.italic) }
            let desc = f.fontDescriptor.withSymbolicTraits(traits)
            if let nf = NSFont(descriptor: desc, size: f.pointSize) { s.addAttribute(.font, value: nf, range: sub) }
        }
    }
}

// MARK: - Patterns

enum MDPattern {
    static let heading = try! NSRegularExpression(pattern: #"^(#{1,6})[ \t]+"#)
    static let rule = try! NSRegularExpression(pattern: #"^[ \t]*([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
    static let quote = try! NSRegularExpression(pattern: #"^[ \t]*(?:>[ \t]?)+"#)
    static let list = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|\d+[.)])[ \t]+(\[[ xX]\][ \t]+)?"#)
    static let pipe = try! NSRegularExpression(pattern: #"\|"#)
    static let tableDivider = try! NSRegularExpression(pattern: #"^[ \t]*\|?[ \t]*:?-{2,}:?[ \t]*(\|[ \t]*:?-{2,}:?[ \t]*)*\|?[ \t]*$"#)
    static let codeSpan = try! NSRegularExpression(pattern: #"(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)
    static let boldItalic = try! NSRegularExpression(pattern: #"(\*\*\*|___)(?=\S)(.+?)(?<=\S)\1"#)
    static let boldStar = try! NSRegularExpression(pattern: #"(?<!\*)\*\*(?=\S)(.+?)(?<=\S)\*\*(?!\*)"#)
    static let boldUnderscore = try! NSRegularExpression(pattern: #"(?<![_\w])__(?=\S)(.+?)(?<=\S)__(?![_\w])"#)
    /// `*` emphasis may sit inside a word (`I*ncome/Expe*nses`), as in CommonMark; `_` may not.
    static let italicStar = try! NSRegularExpression(pattern: #"(?<!\*)\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?!\*)"#)
    static let italicUnderscore = try! NSRegularExpression(pattern: #"(?<![_\w])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![_\w])"#)
    static let strike = try! NSRegularExpression(pattern: #"~~(?=\S)(.+?)(?<=\S)~~"#)
    static let highlight = try! NSRegularExpression(pattern: #"==(?=\S)(.+?)(?<=\S)=="#)
    static let link = try! NSRegularExpression(pattern: #"(!?)\[([^\]\n]*)\]\(([^)\s]+)(?:[ \t]+"[^"\n]*")?\)"#)
    static let blockImage = try! NSRegularExpression(pattern: #"^[ \t]*!\[([^\]\n]*)\]\(([^)\s]+)(?:[ \t]+"([^"\n]*)")?\)[ \t]*$"#)
    static let bareURL = try! NSRegularExpression(pattern: #"\bhttps?://[^\s<>()\[\]]+[^\s<>()\[\].,;:!?'"]"#)
}

extension NSColor {
    /// Like `withAlphaComponent`, but stays dynamic: the base color is resolved
    /// against whichever appearance the text is drawn in.
    func dynamicAlpha(_ alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            var resolved = self
            appearance.performAsCurrentDrawingAppearance {
                resolved = (self.usingColorSpace(.sRGB) ?? self).withAlphaComponent(alpha)
            }
            return resolved
        }
    }

    /// Like `dynamicAlpha`, but scales the color's own alpha (dimmed syntax stays dimmer).
    func dynamicAlphaScaled(_ factor: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            var resolved = self
            appearance.performAsCurrentDrawingAppearance {
                let c = self.usingColorSpace(.sRGB) ?? self
                resolved = c.withAlphaComponent(c.alphaComponent * factor)
            }
            return resolved
        }
    }

    /// Appearance-aware `blended(withFraction:of:)`.
    func dynamicBlend(_ fraction: CGFloat, with other: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            var resolved = self
            appearance.performAsCurrentDrawingAppearance {
                let a = self.usingColorSpace(.sRGB) ?? self
                let b = other.usingColorSpace(.sRGB) ?? other
                resolved = a.blended(withFraction: fraction, of: b) ?? a
            }
            return resolved
        }
    }
}
