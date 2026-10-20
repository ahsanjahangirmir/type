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

    func intersects(_ range: NSRange) -> Bool {
        let probe = NSRange(location: max(0, range.location - 1), length: range.length + 2)
        return code.contains { NSIntersectionRange($0, probe).length > 0 }
            || comments.contains { NSIntersectionRange($0, probe).length > 0 }
    }
}

/// Live Markdown styling: headings, emphasis, lists, quotes, code, links,
/// comments and tables are styled in place. Syntax is either shown quietly
/// or hidden entirely (`hideSyntax`).
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

    private var hide: Bool { config.hideSyntax }

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
    var syntaxColor: NSColor { config.dimSyntax ? .tertiaryLabelColor : .secondaryLabelColor }
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
    private static let commentRegex = try! NSRegularExpression(pattern: #"<!--[\s\S]*?(?:-->|\z)"#)

    static func scanBlocks(_ ns: NSString) -> BlockRanges {
        let all = NSRange(location: 0, length: ns.length)
        let code = fenceRegex.matches(in: ns as String, range: all).map(\.range)
        let comments = commentRegex.matches(in: ns as String, range: all).map(\.range)
            .filter { c in !code.contains { NSIntersectionRange($0, c).length > 0 } }
        return BlockRanges(code: code, comments: comments)
    }

    // MARK: Styling

    /// Restyle `range` (expanded to whole paragraphs) of `storage`.
    func style(_ storage: NSTextStorage, range requested: NSRange? = nil, blocks: BlockRanges) {
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        var range = requested.map { ns.paragraphRange(for: NSIntersectionRange($0, full)) } ?? full
        if range.location == NSNotFound { range = full }

        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: range)

        ns.enumerateSubstrings(in: range, options: [.byParagraphs, .substringNotRequired]) { _, line, enclosing, _ in
            self.styleLine(storage, ns: ns, line: line, enclosing: enclosing, blocks: blocks)
        }

        for comment in blocks.comments where NSIntersectionRange(comment, range).length > 0 {
            let r = NSIntersectionRange(comment, range)
            storage.addAttributes([
                .foregroundColor: commentColor.dynamicBlend(0.25, with: .labelColor),
                .backgroundColor: commentColor.dynamicAlpha(0.12),
                .typeComment: true,
            ], range: r)
            addTraits(storage, r, italic: true)
            if hide {
                if NSLocationInRange(comment.location, range) { hideRange(storage, NSRange(location: comment.location, length: 4)) }
                let end = NSMaxRange(comment)
                if comment.length >= 7, ns.substring(with: NSRange(location: end - 3, length: 3)) == "-->", NSLocationInRange(end - 1, range) {
                    hideRange(storage, NSRange(location: end - 3, length: 3))
                }
            }
        }
        storage.endEditing()
    }

    private func styleLine(_ s: NSTextStorage, ns: NSString, line: NSRange, enclosing: NSRange, blocks: BlockRanges) {
        // Fenced code blocks
        if let block = blocks.code.first(where: { NSIntersectionRange($0, enclosing).length > 0 || NSLocationInRange(line.location, $0) }) {
            s.addAttributes([.font: font(mono: true), .backgroundColor: codeBackground, .typeCode: true,
                             .paragraphStyle: tightParagraphStyle], range: enclosing)
            let text = ns.substring(with: line)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let isFence = line.location == block.location || ((trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")) && NSMaxRange(line) >= NSMaxRange(block) - 1)
            if isFence {
                s.addAttribute(.foregroundColor, value: syntaxColor, range: line)
                if hide {
                    hideRange(s, line)
                    let p = NSMutableParagraphStyle()
                    p.lineHeightMultiple = 0.45
                    s.addAttribute(.paragraphStyle, value: p, range: enclosing)
                }
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

        // Block images (always rendered, regardless of hideSyntax)
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
            if hide {
                hideRange(s, line)
                s.addAttribute(.typeRule, value: true, range: line)
            }
            return
        }

        // Tables
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
            if hide {
                marker(s, markerRange, prefix: true)
                s.addAttribute(.typeQuoteBar, value: true, range: enclosing)
                let indent = config.fontSize * 1.1
                s.addAttribute(.paragraphStyle, value: paragraphStyle(headIndent: indent, firstLineIndent: indent), range: enclosing)
            } else {
                s.addAttribute(.foregroundColor, value: accentColor.dynamicAlpha(0.7), range: markerRange)
                let indent = (ns.substring(with: markerRange) as NSString).size(withAttributes: [.font: font()]).width
                s.addAttribute(.paragraphStyle, value: paragraphStyle(headIndent: indent), range: enclosing)
            }
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
                if hide {
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
                }
            } else if hide, "-*+".contains(ns.substring(with: bullet)) {
                s.addAttribute(.typeGlyph, value: "•", range: bullet)
                visiblePrefix = visiblePrefix.replacingOccurrences(of: ns.substring(with: bullet), with: "•")
                // Give "• " the same width as a checkbox so bullet and task text line up.
                let natural = ((visiblePrefix as NSString).substring(from: m.range(at: 1).length) as NSString).size(withAttributes: [.font: font()]).width
                let target = config.fontSize * 1.25 + (" " as NSString).size(withAttributes: [.font: font()]).width
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

        s.addAttributes([.typeHidden: true, .typeImage: spec], range: line)
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = size.height + 16
        p.maximumLineHeight = size.height + 16
        p.paragraphSpacing = config.paragraphSpacing ? config.fontSize * 0.5 : 0
        p.baseWritingDirection = config.direction.nsDirection
        s.addAttribute(.paragraphStyle, value: p, range: enclosing)
        return true
    }

    private func styleInline(_ s: NSTextStorage, ns: NSString, range: NSRange) {
        guard range.length > 0 else { return }
        let str = ns as String
        var codeSpans: [NSRange] = []

        for m in MDPattern.codeSpan.matches(in: str, range: range) {
            codeSpans.append(m.range)
            s.addAttributes([.font: font(mono: true), .backgroundColor: codeBackground, .typeCode: true], range: m.range)
            let tick = m.range(at: 1).length
            marker(s, NSRange(location: m.range.location, length: tick))
            marker(s, NSRange(location: NSMaxRange(m.range) - tick, length: tick))
        }
        func outsideCode(_ r: NSRange) -> Bool { !codeSpans.contains { NSIntersectionRange($0, r).length > 0 } }

        for m in MDPattern.boldItalic.matches(in: str, range: range) where outsideCode(m.range) {
            addTraits(s, m.range, bold: true, italic: true)
            marker(s, NSRange(location: m.range.location, length: 3))
            marker(s, NSRange(location: NSMaxRange(m.range) - 3, length: 3))
        }
        for m in MDPattern.bold.matches(in: str, range: range) where outsideCode(m.range) {
            addTraits(s, m.range, bold: true)
            marker(s, NSRange(location: m.range.location, length: 2))
            marker(s, NSRange(location: NSMaxRange(m.range) - 2, length: 2))
        }
        for regex in [MDPattern.italicStar, MDPattern.italicUnderscore] {
            for m in regex.matches(in: str, range: range) where outsideCode(m.range) {
                addTraits(s, m.range, italic: true)
                marker(s, NSRange(location: m.range.location, length: 1))
                marker(s, NSRange(location: NSMaxRange(m.range) - 1, length: 1))
            }
        }
        for m in MDPattern.strike.matches(in: str, range: range) where outsideCode(m.range) {
            s.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.secondaryLabelColor], range: m.range)
            marker(s, NSRange(location: m.range.location, length: 2))
            marker(s, NSRange(location: NSMaxRange(m.range) - 2, length: 2))
        }
        for m in MDPattern.highlight.matches(in: str, range: range) where outsideCode(m.range) {
            s.addAttribute(.backgroundColor, value: NSColor.systemYellow.dynamicAlpha(0.35), range: m.range)
            marker(s, NSRange(location: m.range.location, length: 2))
            marker(s, NSRange(location: NSMaxRange(m.range) - 2, length: 2))
        }
        var linkRanges: [NSRange] = []
        for m in MDPattern.link.matches(in: str, range: range) where outsideCode(m.range) {
            linkRanges.append(m.range)
            let isImage = m.range(at: 1).length > 0
            let label = m.range(at: 2)
            dim(s, m.range)
            s.addAttribute(.foregroundColor, value: isImage ? NSColor.secondaryLabelColor : accentColor, range: label)
            if !isImage {
                s.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: label)
                s.addAttribute(.underlineColor, value: accentColor.dynamicAlpha(0.35), range: label)
            }
            if hide {
                hideRange(s, NSRange(location: m.range.location, length: label.location - m.range.location))
                hideRange(s, NSRange(location: NSMaxRange(label), length: NSMaxRange(m.range) - NSMaxRange(label)))
            }
            let url = ns.substring(with: m.range(at: 3))
            s.addAttribute(.typeLink, value: url, range: m.range)
            s.addAttribute(.toolTip, value: url, range: label)
        }
        for m in MDPattern.bareURL.matches(in: str, range: range) where outsideCode(m.range) && !linkRanges.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
            s.addAttributes([.foregroundColor: accentColor, .typeLink: ns.substring(with: m.range)], range: m.range)
        }
    }

    /// A syntax marker: dimmed, or hidden when `hideSyntax` is on.
    private func marker(_ s: NSTextStorage, _ r: NSRange, prefix: Bool = false) {
        dim(s, r)
        if hide { hideRange(s, r, prefix: prefix) }
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
    static let bold = try! NSRegularExpression(pattern: #"(?<![*_])(\*\*|__)(?=\S)(.+?)(?<=\S)\1(?![*_])"#)
    static let italicStar = try! NSRegularExpression(pattern: #"(?<![*\w])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![*\w])"#)
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
