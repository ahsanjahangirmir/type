import Foundation

struct DocumentStats: Equatable {
    var words = 0
    var characters = 0
    var charactersNoSpaces = 0
    var paragraphs = 0

    func readingMinutes(wordsPerMinute: Double) -> Int {
        guard words > 0 else { return 0 }
        return max(1, Int((Double(words) / max(wordsPerMinute, 1)).rounded(.up)))
    }
}

struct OutlineItem: Identifiable, Equatable, Hashable {
    let id: Int // character location
    let level: Int
    let title: String
    var location: Int { id }
}

/// Word counts and outline extraction. Markdown syntax and comments are
/// excluded so the numbers reflect what a reader would see.
enum DocumentAnalysis {
    static func analyze(_ text: String) -> (DocumentStats, [OutlineItem]) {
        let ns = text as NSString
        let blocks = MarkdownStyler.scanBlocks(ns)
        var outline: [OutlineItem] = []
        var visible = ""
        visible.reserveCapacity(ns.length)
        var paragraphs = 0

        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { line, range, _, _ in
            guard let line else { return }
            let inCode = blocks.code.contains { NSLocationInRange(range.location, $0) }
            if inCode {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !(trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")) { visible += line + "\n" }
                return
            }
            if let m = MDPattern.heading.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                let title = stripInline((line as NSString).substring(from: m.range.length)).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { outline.append(OutlineItem(id: range.location, level: m.range(at: 1).length, title: title)) }
            }
            var stripped = line
            for r in [MDPattern.heading, MDPattern.quote, MDPattern.list] {
                stripped = r.stringByReplacingMatches(in: stripped, range: NSRange(location: 0, length: (stripped as NSString).length), withTemplate: "")
            }
            if MDPattern.rule.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil { stripped = "" }
            if MDPattern.tableDivider.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil { stripped = "" }
            stripped = stripInline(stripped)
            if !stripped.trimmingCharacters(in: .whitespaces).isEmpty { paragraphs += 1 }
            visible += stripped + "\n"
        }

        // Remove comments (they can span lines, so do it on the joined text).
        var withoutComments = visible
        if !blocks.comments.isEmpty {
            withoutComments = commentStrip.stringByReplacingMatches(in: visible, range: NSRange(location: 0, length: (visible as NSString).length), withTemplate: "")
        }

        var words = 0
        withoutComments.enumerateSubstrings(in: withoutComments.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in words += 1 }
        let body = withoutComments.trimmingCharacters(in: .newlines)
        let chars = body.filter { $0 != "\n" }.count
        let noSpaces = body.filter { !$0.isWhitespace }.count
        return (DocumentStats(words: words, characters: chars, charactersNoSpaces: noSpaces, paragraphs: paragraphs), outline)
    }

    private static let commentStrip = try! NSRegularExpression(pattern: #"<!--[\s\S]*?(?:-->|\z)"#)
    private static let inlineMarkers = try! NSRegularExpression(pattern: #"(\*{1,3}|_{1,3}|~~|==|`+)"#)
    private static let linkStrip = try! NSRegularExpression(pattern: #"!?\[([^\]\n]*)\]\([^)\n]*\)"#)
    private static let pipes = try! NSRegularExpression(pattern: #"\|"#)

    static func stripInline(_ s: String) -> String {
        var out = linkStrip.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "$1")
        out = inlineMarkers.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: (out as NSString).length), withTemplate: "")
        out = pipes.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: (out as NSString).length), withTemplate: " ")
        return out
    }

    /// Markdown → plain text, used for plain-text export.
    static func plainText(_ markdown: String) -> String {
        let ns = markdown as NSString
        let blocks = MarkdownStyler.scanBlocks(ns)
        var lines: [String] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { line, range, _, _ in
            guard var line else { return }
            if blocks.code.contains(where: { NSLocationInRange(range.location, $0) }) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if !(t.hasPrefix("```") || t.hasPrefix("~~~")) { lines.append(line) }
                return
            }
            for r in [MDPattern.heading, MDPattern.quote] {
                line = r.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: "")
            }
            line = MDPattern.list.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: "$1• ")
            lines.append(stripInline(line))
        }
        let joined = lines.joined(separator: "\n")
        return commentStrip.stringByReplacingMatches(in: joined, range: NSRange(location: 0, length: (joined as NSString).length), withTemplate: "")
    }
}
