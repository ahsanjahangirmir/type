import AppKit

/// Converts rich text (RTF / Word) into Markdown, preserving headings,
/// bold, italic, strikethrough, links and lists.
enum RichTextImporter {
    static func markdown(from data: Data, type: NSAttributedString.DocumentType) throws -> String {
        let attributed = try NSAttributedString(
            data: data,
            options: [.documentType: type],
            documentAttributes: nil
        )
        return markdown(from: attributed)
    }

    static func markdown(from attributed: NSAttributedString) -> String {
        let ns = attributed.string as NSString
        let bodySize = dominantFontSize(in: attributed)
        var lines: [String] = []

        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            guard range.length > 0 else { lines.append(""); return }
            let para = attributed.attributedSubstring(from: range)
            let style = para.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            let font = para.attribute(.font, at: 0, effectiveRange: nil) as? NSFont

            var prefix = ""
            var headingLevel = 0
            if let font, bodySize > 0 {
                let ratio = font.pointSize / bodySize
                if ratio >= 1.6 { headingLevel = 1 } else if ratio >= 1.3 { headingLevel = 2 } else if ratio >= 1.12 { headingLevel = 3 }
            }
            if headingLevel > 0 {
                prefix = String(repeating: "#", count: headingLevel) + " "
            } else if let list = style?.textLists.last {
                let depth = max(0, (style?.textLists.count ?? 1) - 1)
                let indent = String(repeating: "  ", count: depth)
                let format = list.markerFormat.rawValue
                prefix = indent + (format.contains("decimal") ? "1. " : "- ")
            }

            var body = inlineMarkdown(para, skipEmphasis: headingLevel > 0)
            // Rich-text lists carry their marker as literal text (e.g. "\t•\t"),
            // and Word imports may have no list metadata at all.
            if style?.textLists.isEmpty == false {
                body = body.replacingOccurrences(of: #"^\s*(?:[•◦▪︎\-–]|\d+[.)])\s*"#, with: "", options: .regularExpression)
            } else if headingLevel == 0, let m = body.range(of: #"^\s*[•◦▪︎●]\t\s*"#, options: .regularExpression) {
                prefix = "- "
                body.removeSubrange(m)
            } else if headingLevel == 0, let m = body.range(of: #"^\s*\d+[.)]\t\s*"#, options: .regularExpression) {
                prefix = "1. "
                body.removeSubrange(m)
            }
            lines.append(prefix + body.trimmingCharacters(in: .whitespaces))
        }

        // Separate block paragraphs with a blank line, but keep list items tight.
        var out: [String] = []
        for (i, line) in lines.enumerated() {
            out.append(line)
            let next = i + 1 < lines.count ? lines[i + 1] : nil
            let isList = line.range(of: #"^\s*(- |\d+\. )"#, options: .regularExpression) != nil
            let nextIsList = next?.range(of: #"^\s*(- |\d+\. )"#, options: .regularExpression) != nil
            if !line.isEmpty, let next, !next.isEmpty, !(isList && nextIsList) { out.append("") }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func inlineMarkdown(_ para: NSAttributedString, skipEmphasis: Bool) -> String {
        var result = ""
        para.enumerateAttributes(in: NSRange(location: 0, length: para.length)) { attrs, range, _ in
            var chunk = (para.string as NSString).substring(with: range)
            guard !chunk.trimmingCharacters(in: .whitespaces).isEmpty else { result += chunk; return }

            // Keep surrounding whitespace outside of the markers.
            let leading = String(chunk.prefix { $0.isWhitespace })
            let trailing = String(chunk.reversed().prefix { $0.isWhitespace }.reversed())
            chunk = chunk.trimmingCharacters(in: .whitespaces)

            if !skipEmphasis, let font = attrs[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                let name = font.fontName.lowercased()
                let bold = traits.contains(.bold) || name.contains("bold")
                let italic = traits.contains(.italic) || name.contains("italic") || name.contains("oblique")
                    || ((attrs[.obliqueness] as? CGFloat) ?? 0) > 0
                if bold && italic { chunk = "***\(chunk)***" } else if bold { chunk = "**\(chunk)**" } else if italic { chunk = "*\(chunk)*" }
            }
            if let strike = attrs[.strikethroughStyle] as? Int, strike != 0 { chunk = "~~\(chunk)~~" }
            if let link = attrs[.link] {
                let url = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                if !url.isEmpty { chunk = "[\(chunk)](\(url))" }
            }
            result += leading + chunk + trailing
        }
        return result
    }

    private static func dominantFontSize(in attributed: NSAttributedString) -> CGFloat {
        var counts: [CGFloat: Int] = [:]
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            if let f = value as? NSFont { counts[f.pointSize, default: 0] += range.length }
        }
        return counts.max { $0.value < $1.value }?.key ?? 12
    }
}
