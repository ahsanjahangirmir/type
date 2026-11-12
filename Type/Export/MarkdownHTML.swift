import Foundation

/// A compact CommonMark-ish renderer covering what Type's editor styles:
/// headings, paragraphs, emphasis, strike, highlight, code, links, images,
/// block quotes, nested lists, checklists, tables and rules. Comments are dropped.
enum MarkdownHTML {
    static func render(_ markdown: String) -> String {
        let cleaned = stripComments(markdown.replacingOccurrences(of: "\r\n", with: "\n"))
        let lines = cleaned.components(separatedBy: "\n")
        var html = ""
        var i = 0
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            html += "<p>" + paragraph.map(inline).joined(separator: "<br>\n") + "</p>\n"
            paragraph.removeAll()
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i]); i += 1
                }
                i += 1
                let cls = lang.isEmpty ? "" : " class=\"language-\(escape(lang))\""
                html += "<pre><code\(cls)>\(escape(code.joined(separator: "\n")))</code></pre>\n"
                continue
            }
            if trimmed.isEmpty { flushParagraph(); i += 1; continue }

            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)

            if let m = MDPattern.heading.firstMatch(in: line, range: full) {
                flushParagraph()
                let level = m.range(at: 1).length
                let content = ns.substring(from: m.range.length).replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
                html += "<h\(level) id=\"\(slug(content))\">\(inline(content))</h\(level)>\n"
                i += 1; continue
            }
            if MDPattern.rule.firstMatch(in: line, range: full) != nil {
                flushParagraph(); html += "<hr>\n"; i += 1; continue
            }
            if trimmed.hasPrefix("|"), i + 1 < lines.count,
               MDPattern.tableDivider.firstMatch(in: lines[i + 1], range: NSRange(location: 0, length: (lines[i + 1] as NSString).length)) != nil {
                flushParagraph()
                var rows: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") { rows.append(lines[i]); i += 1 }
                html += table(rows)
                continue
            }
            if MDPattern.quote.firstMatch(in: line, range: full) != nil {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.count, let m = MDPattern.quote.firstMatch(in: lines[i], range: NSRange(location: 0, length: (lines[i] as NSString).length)) {
                    let inner = (lines[i] as NSString).substring(from: m.range.length)
                    let depthMarker = (lines[i] as NSString).substring(with: m.range).filter { $0 == ">" }.count
                    quoted.append(String(repeating: "> ", count: max(0, depthMarker - 1)) + inner)
                    i += 1
                }
                html += "<blockquote>\n\(render(quoted.joined(separator: "\n")))</blockquote>\n"
                continue
            }
            if MDPattern.list.firstMatch(in: line, range: full) != nil {
                flushParagraph()
                var items: [String] = []
                while i < lines.count {
                    let l = lines[i]
                    if MDPattern.list.firstMatch(in: l, range: NSRange(location: 0, length: (l as NSString).length)) != nil
                        || (!l.trimmingCharacters(in: .whitespaces).isEmpty && (l.hasPrefix("  ") || l.hasPrefix("\t")) && !items.isEmpty) {
                        items.append(l); i += 1
                    } else { break }
                }
                html += list(items)
                continue
            }
            paragraph.append(trimmed)
            i += 1
        }
        flushParagraph()
        return html
    }

    // MARK: Blocks

    private static func indentWidth(_ s: String) -> Int {
        var w = 0
        for c in s { if c == " " { w += 1 } else if c == "\t" { w += 4 } else { break } }
        return w
    }

    private static func list(_ lines: [String]) -> String {
        guard let first = lines.first, let fm = MDPattern.list.firstMatch(in: first, range: NSRange(location: 0, length: (first as NSString).length)) else { return "" }
        let baseIndent = indentWidth(first)
        func opening(_ marker: String) -> String {
            guard let n = Int(marker.dropLast()) else { return "<ul>\n" }
            return n == 1 ? "<ol>\n" : "<ol start=\"\(n)\">\n"
        }
        var ordered = (first as NSString).substring(with: fm.range(at: 2)).first?.isNumber == true
        var html = opening((first as NSString).substring(with: fm.range(at: 2)))
        var idx = 0
        while idx < lines.count {
            let line = lines[idx]
            let ns = line as NSString
            guard let m = MDPattern.list.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)), indentWidth(line) <= baseIndent else { idx += 1; continue }
            // A bullet run followed by a numbered run (or back) is two lists.
            let marker = ns.substring(with: m.range(at: 2))
            let isOrdered = marker.first?.isNumber == true
            if isOrdered != ordered {
                html += (ordered ? "</ol>\n" : "</ul>\n") + opening(marker)
                ordered = isOrdered
            }
            var content = ns.substring(from: m.range.length)
            var cls = ""
            if m.range(at: 3).location != NSNotFound {
                let done = ns.substring(with: m.range(at: 3)).lowercased().contains("x")
                content = "<input type=\"checkbox\" disabled\(done ? " checked" : "")> " + inline(content)
                cls = " class=\"task\""
            } else {
                content = inline(content)
            }
            idx += 1
            var children: [String] = []
            while idx < lines.count, indentWidth(lines[idx]) > baseIndent {
                children.append(lines[idx]); idx += 1
            }
            if !children.isEmpty {
                let nested = children.filter { MDPattern.list.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil }
                if !nested.isEmpty { content += "\n" + list(children) }
                else { content += "<br>" + children.map { inline($0.trimmingCharacters(in: .whitespaces)) }.joined(separator: "<br>") }
            }
            html += "<li\(cls)>\(content)</li>\n"
        }
        return html + (ordered ? "</ol>\n" : "</ul>\n")
    }

    private static func table(_ rows: [String]) -> String {
        func cells(_ row: String) -> [String] {
            var r = MarkdownEscapes.protect(row).trimmingCharacters(in: .whitespaces)
            if r.hasPrefix("|") { r.removeFirst() }
            if r.hasSuffix("|") { r.removeLast() }
            return r.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        guard rows.count >= 2 else { return "" }
        let aligns = cells(rows[1]).map { c -> String in
            if c.hasPrefix(":") && c.hasSuffix(":") { return " style=\"text-align:center\"" }
            if c.hasSuffix(":") { return " style=\"text-align:right\"" }
            return ""
        }
        var html = "<table>\n<thead><tr>"
        for (n, c) in cells(rows[0]).enumerated() { html += "<th\(n < aligns.count ? aligns[n] : "")>\(inline(c))</th>" }
        html += "</tr></thead>\n<tbody>\n"
        for row in rows.dropFirst(2) {
            html += "<tr>"
            for (n, c) in cells(row).enumerated() { html += "<td\(n < aligns.count ? aligns[n] : "")>\(inline(c))</td>" }
            html += "</tr>\n"
        }
        return html + "</tbody>\n</table>\n"
    }

    // MARK: Inline

    private static let codeSpan = try! NSRegularExpression(pattern: #"(`+)(.+?)\1"#)

    static func inline(_ source: String) -> String {
        let text = MarkdownEscapes.protect(source)
        // Protect code spans first.
        var placeholders: [String] = []
        let ns = text as NSString
        var protected = ""
        var last = 0
        for m in codeSpan.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            protected += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            placeholders.append("<code>\(escape(ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)))</code>")
            protected += "\u{E000}\(placeholders.count - 1)\u{E001}"
            last = NSMaxRange(m.range)
        }
        protected += ns.substring(from: last)

        var s = emptyLinks(in: images(in: escape(protected), placeholders: &placeholders), placeholders: &placeholders)
        let rules: [(String, String)] = [
            (#"\[([^\]]+)\]\(([^)\s]+)(?:\s+&quot;([^&]*)&quot;)?\)"#, "<a href=\"$2\">$1</a>"),
            (#"(?<![\"=>])\b(https?://[^\s<]+[^\s<.,;:!?)])"#, "<a href=\"$1\">$1</a>"),
            (#"(\*\*\*|___)(?=\S)(.+?)(?<=\S)\1"#, "<strong><em>$2</em></strong>"),
            (#"(?<!\*)\*\*(?=\S)(.+?)(?<=\S)\*\*(?!\*)"#, "<strong>$1</strong>"),
            (#"(?<![_\w])__(?=\S)(.+?)(?<=\S)__(?![_\w])"#, "<strong>$1</strong>"),
            (#"(?<!\*)\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?!\*)"#, "<em>$1</em>"),
            (#"(?<![_\w])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![_\w])"#, "<em>$1</em>"),
            (#"~~(?=\S)(.+?)(?<=\S)~~"#, "<del>$1</del>"),
            (#"==(?=\S)(.+?)(?<=\S)=="#, "<mark>$1</mark>"),
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        for (n, p) in placeholders.enumerated() {
            s = s.replacingOccurrences(of: "\u{E000}\(n)\u{E001}", with: p)
        }
        // Escaped characters come back literal (and HTML-escaped).
        return s.unicodeScalars.reduce(into: "") { out, u in
            if (0xE121...0xE17E).contains(u.value), let c = UnicodeScalar(u.value - 0xE100) { out += escape(String(c)) } else { out.unicodeScalars.append(u) }
        }
    }

    private static let emptyLinkRegex = try! NSRegularExpression(pattern: #"(?<!!)\[\]\(([^)\s]+)(?:\s+&quot;.*?&quot;)?\)"#)

    /// `[](url)` has no label to show, so the address (without its scheme) stands in.
    private static func emptyLinks(in s: String, placeholders: inout [String]) -> String {
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in emptyLinkRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let url = ns.substring(with: m.range(at: 1))
            let shown = LinkDisplay.text(for: url)
            placeholders.append("<a href=\"\(url)\">\(shown.isEmpty ? url : shown)</a>")
            out += "\u{E000}\(placeholders.count - 1)\u{E001}"
            last = NSMaxRange(m.range)
        }
        return out + ns.substring(from: last)
    }

    private static let imageRegex = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)\s]+)(?:\s+&quot;(.*?)&quot;)?\)"#)

    /// `![alt](src "width=480")` → `<img src alt width>`.
    private static func images(in s: String, placeholders: inout [String]) -> String {
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in imageRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let alt = ns.substring(with: m.range(at: 1))
            let src = ns.substring(with: m.range(at: 2))
            var attrs = ""
            if m.range(at: 3).location != NSNotFound {
                let title = ns.substring(with: m.range(at: 3))
                if let w = ImageSpec.width(fromTitle: title) { attrs = " width=\"\(Int(w))\"" }
                else { attrs = " title=\"\(title)\"" }
            }
            placeholders.append("<img src=\"\(src)\" alt=\"\(alt)\"\(attrs)>")
            out += "\u{E000}\(placeholders.count - 1)\u{E001}"
            last = NSMaxRange(m.range)
        }
        return out + ns.substring(from: last)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func slug(_ s: String) -> String {
        DocumentAnalysis.stripInline(s).lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: "-")
    }

    private static func stripComments(_ s: String) -> String {
        s.replacingOccurrences(of: #"(?<!\\)<!--[\s\S]*?(?:-->|\z)"#, with: "", options: .regularExpression)
    }
}
