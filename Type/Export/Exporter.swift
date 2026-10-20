import AppKit
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case pdf, html, word, rtf, markdown, plainText
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pdf: "PDF"
        case .html: "Web Page (HTML)"
        case .word: "Word Document"
        case .rtf: "Rich Text (RTF)"
        case .markdown: "Markdown"
        case .plainText: "Plain Text"
        }
    }
    var symbol: String {
        switch self {
        case .pdf: "doc.richtext"
        case .html: "globe"
        case .word: "doc.text"
        case .rtf: "doc.plaintext"
        case .markdown: "number"
        case .plainText: "text.alignleft"
        }
    }
    var contentType: UTType {
        switch self {
        case .pdf: .pdf
        case .html: .html
        case .word: .wordDocument
        case .rtf: .rtf
        case .markdown: .markdownText
        case .plainText: .plainText
        }
    }
    var fileExtension: String {
        switch self {
        case .pdf: "pdf"
        case .html: "html"
        case .word: "docx"
        case .rtf: "rtf"
        case .markdown: "md"
        case .plainText: "txt"
        }
    }
}

@MainActor
enum Exporter {
    static func export(markdown: String, title: String, baseURL: URL?, format: ExportFormat,
                       fontChoice: FontChoice, customFamily: String, window: NSWindow) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "\(title).\(format.fileExtension)"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try write(markdown: markdown, title: title, baseURL: baseURL, format: format,
                          fontChoice: fontChoice, customFamily: customFamily, to: url)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    static func write(markdown: String, title: String, baseURL: URL?, format: ExportFormat,
                      fontChoice: FontChoice, customFamily: String, to url: URL) throws {
        switch format {
        case .markdown:
            try Data(markdown.utf8).write(to: url, options: .atomic)
        case .plainText:
            try Data(DocumentAnalysis.plainText(markdown).utf8).write(to: url, options: .atomic)
        case .html:
            let html = embedImages(htmlDocument(markdown: markdown, title: title, fontChoice: fontChoice, customFamily: customFamily), baseURL: baseURL)
            try Data(html.utf8).write(to: url, options: .atomic)
        case .word, .rtf:
            let attributed = try attributedString(markdown: markdown, title: title, baseURL: baseURL, fontChoice: fontChoice, customFamily: customFamily)
            let type: NSAttributedString.DocumentType = format == .word ? .officeOpenXML : .rtf
            let data = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: type, .title: title])
            try data.write(to: url, options: .atomic)
        case .pdf:
            let attributed = try attributedString(markdown: markdown, title: title, baseURL: baseURL, fontChoice: fontChoice, customFamily: customFamily)
            try writePDF(attributed, to: url)
        }
    }

    static func print(markdown: String, title: String, baseURL: URL?, fontChoice: FontChoice, customFamily: String, window: NSWindow?) {
        guard let attributed = try? attributedString(markdown: markdown, title: title, baseURL: baseURL, fontChoice: fontChoice, customFamily: customFamily) else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        configure(info)
        let view = printableView(attributed, info: info)
        let op = NSPrintOperation(view: view, printInfo: info)
        op.jobTitle = title
        if let window { op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil) } else { op.run() }
    }

    // MARK: Rendering

    private static func cssFontStack(_ choice: FontChoice, _ family: String, forPrint: Bool) -> String {
        // System design fonts (New York, SF Rounded) aren't addressable by name
        // in AppKit's HTML importer, so documents use installed families.
        if forPrint {
            switch choice {
            case .serif: return "Charter, Georgia, serif"
            case .sans: return "\"Helvetica Neue\", Helvetica, sans-serif"
            case .rounded: return "\"Avenir Next\", Avenir, sans-serif"
            case .mono: return "Menlo, monospace"
            case .custom: return "\"\(family)\", Charter, serif"
            }
        }
        return switch choice {
        case .serif: "\"New York\", ui-serif, Georgia, serif"
        case .sans: "-apple-system, \"SF Pro Text\", \"Helvetica Neue\", sans-serif"
        case .rounded: "ui-rounded, \"SF Pro Rounded\", -apple-system, sans-serif"
        case .mono: "ui-monospace, \"SF Mono\", Menlo, monospace"
        case .custom: "\"\(family)\", -apple-system, serif"
        }
    }

    static func htmlDocument(markdown: String, title: String, fontChoice: FontChoice, customFamily: String, forPrint: Bool = false) -> String {
        let font = cssFontStack(fontChoice, customFamily, forPrint: forPrint)
        // Print/PDF rendering goes through AppKit's HTML importer, which only
        // understands a subset of CSS; keep that path simple.
        let screenCSS = forPrint ? "" : """
            :root { color-scheme: light dark; }
            body { max-width: 42rem; margin: 4rem auto; padding: 0 1.25rem; line-height: 1.6; }
            @media (prefers-color-scheme: dark) { body { background: #1c1c1e; color: #e5e5e7; } a { color: #6cb4ff; } code, pre { background: #2c2c2e; } }
            """
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(MarkdownHTML.escape(title))</title>
        <style>
        \(screenCSS)
        body { font-family: \(font); font-size: \(forPrint ? "12pt" : "18px"); color: #1d1d1f; }
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.4em 0 0.5em; }
        h1 { font-size: 2em; } h2 { font-size: 1.5em; } h3 { font-size: 1.25em; }
        p, ul, ol, blockquote, pre, table { margin: 0 0 1em; }
        blockquote { margin-left: 0; padding-left: 1em; border-left: 3px solid #c7c7cc; color: #6e6e73; font-style: italic; }
        code { font-family: \(forPrint ? "Menlo" : "ui-monospace, \"SF Mono\", Menlo"), monospace; font-size: 0.88em; background: #f2f2f4; padding: 0.1em 0.3em; border-radius: 4px; }
        pre { background: #f2f2f4; padding: 0.9em 1em; border-radius: 8px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        img { max-width: 100%; border-radius: 6px; }
        table { border-collapse: collapse; }
        th, td { border: 1px solid #d1d1d6; padding: 0.35em 0.7em; }
        hr { border: none; border-top: 1px solid #d1d1d6; margin: 2em 0; }
        mark { background: #fff3a3; }
        li.task { list-style: none; margin-left: -1.3em; }
        a { color: #0066cc; }
        </style></head>
        <body>
        \(MarkdownHTML.render(markdown))
        </body></html>
        """
    }

    private static let imgSrc = try! NSRegularExpression(pattern: #"<img src="([^"]+)""#)

    /// Inlines local images as data URIs so an exported web page stands alone.
    static func embedImages(_ html: String, baseURL: URL?) -> String {
        let ns = html as NSString
        var out = ""
        var last = 0
        for m in imgSrc.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let srcRange = m.range(at: 1)
            out += ns.substring(with: NSRange(location: last, length: srcRange.location - last))
            let src = ns.substring(with: srcRange).replacingOccurrences(of: "&amp;", with: "&")
            if let url = ImageStore.resolve(src, baseURL: baseURL), let data = try? Data(contentsOf: url) {
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
                out += "data:\(mime);base64,\(data.base64EncodedString())"
            } else {
                out += ns.substring(with: srcRange)
            }
            last = NSMaxRange(srcRange)
        }
        return out + ns.substring(from: last)
    }

    static func attributedString(markdown: String, title: String, baseURL: URL?, fontChoice: FontChoice, customFamily: String) throws -> NSAttributedString {
        let html = htmlDocument(markdown: markdown, title: title, fontChoice: fontChoice, customFamily: customFamily, forPrint: true)
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        if let baseURL { options[.baseURL] = baseURL }
        return try NSAttributedString(data: Data(html.utf8), options: options, documentAttributes: nil)
    }

    private static func configure(_ info: NSPrintInfo) {
        info.topMargin = 54; info.bottomMargin = 54
        info.leftMargin = 64; info.rightMargin = 64
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
    }

    private static func printableView(_ attributed: NSAttributedString, info: NSPrintInfo) -> NSTextView {
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.textStorage?.setAttributedString(attributed)
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        view.sizeToFit()
        view.appearance = NSAppearance(named: .aqua)
        return view
    }

    private static func writePDF(_ attributed: NSAttributedString, to url: URL) throws {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        configure(info)
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let view = printableView(attributed, info: info)
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        if !op.run() { throw CocoaError(.fileWriteUnknown) }
    }
}
