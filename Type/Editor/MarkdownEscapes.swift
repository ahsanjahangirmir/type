import Foundation

extension NSAttributedString.Key {
    /// The backslash of a `\X` escape: drawn with no width, never separated from its character.
    static let typeEscape = NSAttributedString.Key("TypeEscape")
}

/// Backslash escapes, the way Markdown stores literal punctuation: `\*` is a
/// plain `*`. Inside code spans backslashes are ordinary characters.
enum MarkdownEscapes {
    /// Stands in for escaped characters while patterns run, so they never see them.
    static let placeholder: Character = "\u{E000}"

    static func isPunctuation(_ c: unichar) -> Bool {
        (33...47).contains(c) || (58...64).contains(c) || (91...96).contains(c) || (123...126).contains(c)
    }

    /// Offsets of the escape backslashes in `text`, and the code spans (which hold none).
    static func scan(_ text: NSString) -> (escapes: [Int], code: [NSRange]) {
        let (escapes, code, _) = scanAll(text)
        return (escapes, code)
    }

    /// `scan`, plus the backtick runs that open no code span (plain characters).
    static func scanAll(_ text: NSString) -> (escapes: [Int], code: [NSRange], loneTicks: [NSRange]) {
        var escapes: [Int] = [], code: [NSRange] = [], lone: [NSRange] = []
        let n = text.length
        var i = 0
        while i < n {
            let c = text.character(at: i)
            if c == 92, i + 1 < n, isPunctuation(text.character(at: i + 1)) {
                escapes.append(i); i += 2; continue
            }
            if c == 96 {
                var k = 1
                while i + k < n, text.character(at: i + k) == 96 { k += 1 }
                var j = i + k
                var closed: Int?
                while j < n {
                    guard text.character(at: j) == 96 else { j += 1; continue }
                    var m = 1
                    while j + m < n, text.character(at: j + m) == 96 { m += 1 }
                    if m == k { closed = j + m; break }
                    j += m
                }
                if let end = closed { code.append(NSRange(location: i, length: end - i)); i = end } else { lone.append(NSRange(location: i, length: k)); i += k }
                continue
            }
            i += 1
        }
        return (escapes, code, lone)
    }

    /// `text` with every escape pair replaced by placeholders (same length).
    static func masked(_ text: String) -> String {
        let (escapes, _, lone) = scanAll(text as NSString)
        guard !escapes.isEmpty || !lone.isEmpty else { return text }
        var units = Array(text.utf16)
        for e in escapes { units[e] = 0xE000; units[e + 1] = 0xE000 }
        // Backticks that open no code span are plain characters, whatever the patterns would make of them.
        for r in lone { for i in r.location..<NSMaxRange(r) { units[i] = 0xE000 } }
        return String(utf16CodeUnits: units, count: units.count)
    }

    /// `text` as the reader sees it: escape backslashes removed.
    static func unescaped(_ text: String) -> String {
        let ns = text as NSString
        let (escapes, _) = scan(ns)
        guard !escapes.isEmpty else { return text }
        let drop = Set(escapes)
        let units = (0..<ns.length).filter { !drop.contains($0) }.map { ns.character(at: $0) }
        return String(utf16CodeUnits: units, count: units.count)
    }

    /// Replaces each `\X` by one private-use character, so patterns that
    /// rewrite text skip it; `restore` turns those back into plain `X`.
    static func protect(_ text: String) -> String {
        let ns = text as NSString
        let (escapes, _) = scan(ns)
        guard !escapes.isEmpty else { return text }
        let drop = Set(escapes)
        var units: [unichar] = []
        var i = 0
        while i < ns.length {
            if drop.contains(i) { units.append(0xE100 + ns.character(at: i + 1)); i += 2 } else { units.append(ns.character(at: i)); i += 1 }
        }
        return String(utf16CodeUnits: units, count: units.count)
    }

    static func restore(_ text: String) -> String {
        let units = text.utf16.map { (0xE121...0xE17E).contains($0) ? $0 - 0xE100 : $0 }
        return String(utf16CodeUnits: units, count: units.count)
    }

    // MARK: Typing and pasting

    /// `text` with a backslash before every character that would otherwise be
    /// Markdown, given the line text before the insertion point and the
    /// character after it. Code spans are not special here: callers skip this
    /// when inserting inside code.
    static func escape(_ text: String, linePrefix: String, next: unichar? = nil) -> String {
        let units = Array(text.utf16)
        var out: [unichar] = []
        var prefix = linePrefix
        for (idx, c) in units.enumerated() {
            if c == 10 { prefix = ""; out.append(c); continue }
            let following: unichar? = idx + 1 < units.count ? units[idx + 1] : next
            if needsEscape(c, prefix: prefix, next: following) { out.append(92) }
            out.append(c)
            prefix.unicodeScalars.append(UnicodeScalar(c) ?? " ")
        }
        return String(utf16CodeUnits: out, count: out.count)
    }

    private static func needsEscape(_ c: unichar, prefix: String, next: unichar?) -> Bool {
        switch c {
        case 92, 96, 42, 95, 126, 61, 91, 93, 60, 124: return true // \ ` * _ ~ = [ ] < |
        case 33: return next == 91 // ! before [
        case 35, 45, 43, 62: return atContentStart(prefix) // # - + >
        case 46, 41: // . ) after digits
            let p = InlineFormatter.contentStart(of: prefix)
            let rest = (prefix as NSString).substring(from: p).trimmingCharacters(in: .whitespaces)
            return !rest.isEmpty && rest.allSatisfy { $0.isASCII && $0.isNumber }
        default: return false
        }
    }

    /// True when nothing but whitespace (after any block prefix) precedes on the line.
    static func atContentStart(_ prefix: String) -> Bool {
        let p = InlineFormatter.contentStart(of: prefix)
        return (prefix as NSString).substring(from: p).allSatisfy { $0 == " " || $0 == "\t" }
    }
}

/// Links whose label is empty (`[](https://x.com)`) show their address instead.
enum LinkDisplay {
    private static let scheme = try! NSRegularExpression(pattern: #"^(?:[a-zA-Z][a-zA-Z0-9+.-]*://|mailto:)"#)

    /// UTF-16 length of the leading `https://`-style scheme of `url`.
    static func schemeLength(_ url: String) -> Int {
        scheme.firstMatch(in: url, range: NSRange(location: 0, length: (url as NSString).length))?.range.length ?? 0
    }

    /// The address as shown: `www.google.com` for `https://www.google.com`.
    static func text(for url: String) -> String {
        (url as NSString).substring(from: schemeLength(url))
    }
}
