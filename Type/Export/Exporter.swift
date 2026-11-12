import AppKit
import UniformTypeIdentifiers
import WebKit

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
            Task { @MainActor in
                do {
                    try await write(markdown: markdown, title: title, baseURL: baseURL, format: format,
                                    fontChoice: fontChoice, customFamily: customFamily, to: url)
                } catch {
                    NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil)
                }
            }
        }
    }

    static func write(markdown: String, title: String, baseURL: URL?, format: ExportFormat,
                      fontChoice: FontChoice, customFamily: String, to url: URL) async throws {
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
            let data = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [
                .documentType: type, .title: title,
                .topMargin: pageMargin, .bottomMargin: pageMargin, .leftMargin: pageMargin, .rightMargin: pageMargin,
            ])
            try data.write(to: url, options: .atomic)
        case .pdf:
            let html = embedImages(htmlDocument(markdown: markdown, title: title, fontChoice: fontChoice, customFamily: customFamily, target: .paged), baseURL: baseURL)
            try await PagedPrinter.run(html: html, title: title, destination: .file(url))
        }
    }

    static func print(markdown: String, title: String, baseURL: URL?, fontChoice: FontChoice, customFamily: String, window: NSWindow?) {
        let html = embedImages(htmlDocument(markdown: markdown, title: title, fontChoice: fontChoice, customFamily: customFamily, target: .paged), baseURL: baseURL)
        Task { @MainActor in
            do {
                try await PagedPrinter.run(html: html, title: title, destination: .printer(window))
            } catch {
                if let window { NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil) }
            }
        }
    }

    // MARK: Rendering

    /// Who reads the HTML: a browser, WebKit laying out pages (PDF/print), or
    /// AppKit's HTML importer (Word/RTF), which understands only simple CSS.
    enum HTMLTarget { case screen, paged, richText }

    /// 0.75 in, a comfortable page margin that doesn't waste the page.
    static let pageMargin: CGFloat = 54

    private static func cssFontStack(_ choice: FontChoice, _ family: String, target: HTMLTarget) -> String {
        // System design fonts (New York, SF Rounded) aren't addressable by name
        // in AppKit's HTML importer, so rich text uses installed families.
        if target == .richText {
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

    static func htmlDocument(markdown: String, title: String, fontChoice: FontChoice, customFamily: String, target: HTMLTarget = .screen) -> String {
        let font = cssFontStack(fontChoice, customFamily, target: target)
        let mono = target == .richText ? "Menlo, monospace" : "ui-monospace, \"SF Mono\", Menlo, monospace"
        var body = MarkdownHTML.render(markdown)
        if target == .paged {
            // Disabled form controls print faintly; draw the boxes with CSS instead.
            body = body.replacingOccurrences(of: "<input type=\"checkbox\" disabled checked>", with: "<span class=\"box on\"></span>")
                .replacingOccurrences(of: "<input type=\"checkbox\" disabled>", with: "<span class=\"box\"></span>")
        }
        if target == .richText {
            // The importer drops form controls and rules; use characters it keeps.
            body = body.replacingOccurrences(of: "<input type=\"checkbox\" disabled checked>", with: "☑")
                .replacingOccurrences(of: "<input type=\"checkbox\" disabled>", with: "☐")
                .replacingOccurrences(of: "<hr>", with: "<p class=\"rule\">• • •</p>")
        }
        let css: String
        switch target {
        case .screen:
            css = """
            :root { color-scheme: light dark; }
            body { max-width: 42rem; margin: 4rem auto; padding: 0 1.25rem; font-family: \(font); font-size: 18px; line-height: 1.6; color: #1d1d1f; }
            @media (prefers-color-scheme: dark) { body { background: #1c1c1e; color: #e5e5e7; } a { color: #6cb4ff; } code, pre { background: #2c2c2e; } th { background: #2c2c2e; } }
            \(sharedCSS(mono: mono))
            """
        case .paged:
            css = """
            @page { margin: 0; }
            html { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
            body { margin: 0; font-family: \(font); font-size: 11.5pt; line-height: 1.55; color: #1d1d1f; -webkit-font-smoothing: antialiased; }
            h1, h2, h3, h4, h5, h6, tr, img, pre, blockquote { break-inside: avoid; }
            h1, h2, h3, h4, h5, h6 { break-after: avoid; }
            \(sharedCSS(mono: mono))
            body > :first-child { margin-top: 0; }
            """
        case .richText:
            css = """
            body { font-family: \(font); font-size: 12pt; color: #1d1d1f; }
            h1, h2, h3, h4, h5, h6 { margin: 1em 0 0.4em; }
            h1 { font-size: 22pt; } h2 { font-size: 17pt; } h3 { font-size: 14pt; }
            p, ul, ol, pre, table { margin: 0 0 0.8em; }
            blockquote { margin: 0 0 0.8em 1.5em; color: #6e6e73; font-style: italic; }
            code { font-family: \(mono); font-size: 10.5pt; background: #f2f2f4; }
            pre { font-family: \(mono); font-size: 10.5pt; background: #f2f2f4; padding: 8pt; }
            pre code { background: none; }
            table { border-collapse: collapse; }
            th, td { border: 1px solid #d1d1d6; padding: 4pt 8pt; text-align: left; vertical-align: top; }
            th { background: #f2f2f4; }
            mark { background: #fff3a3; }
            a { color: #0066cc; }
            p.rule { text-align: center; color: #a1a1a6; }
            """
        }
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(MarkdownHTML.escape(title))</title>
        <style>
        \(css)
        </style></head>
        <body>
        \(body)
        </body></html>
        """
    }

    /// Styles shared by the browser and paged (PDF/print) renderings.
    private static func sharedCSS(mono: String) -> String {
        """
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.5em 0 0.5em; }
        h1 { font-size: 1.9em; } h2 { font-size: 1.45em; } h3 { font-size: 1.2em; } h4 { font-size: 1.05em; }
        p, ul, ol, blockquote, pre, table { margin: 0 0 0.9em; }
        ul, ol { padding-left: 1.5em; }
        li { margin: 0.15em 0; }
        li > ul, li > ol { margin: 0.15em 0 0; }
        li.task { list-style: none; margin-left: -1.5em; }
        li.task input { margin: 0 0.45em 0 0; vertical-align: -0.1em; }
        .box { display: inline-block; box-sizing: border-box; width: 0.9em; height: 0.9em; margin-right: 0.5em; vertical-align: -0.12em;
               border: 1.5px solid #8e8e93; border-radius: 0.22em; position: relative; }
        .box.on { background: #0a84ff; border-color: #0a84ff; }
        .box.on::after { content: ""; position: absolute; left: 0.27em; top: 0.08em; width: 0.2em; height: 0.42em;
                         border: solid white; border-width: 0 0.12em 0.12em 0; transform: rotate(45deg); }
        blockquote { margin-left: 0; padding: 0.1em 0 0.1em 1em; border-left: 3px solid #c7c7cc; color: #6e6e73; font-style: italic; }
        blockquote p:last-child { margin-bottom: 0; }
        code { font-family: \(mono); font-size: 0.86em; background: #f2f2f4; padding: 0.1em 0.3em; border-radius: 4px; }
        pre { background: #f2f2f4; padding: 0.8em 1em; border-radius: 8px; overflow-x: auto; line-height: 1.4; white-space: pre-wrap; }
        pre code { background: none; padding: 0; font-size: 0.86em; }
        img { max-width: 100%; height: auto; border-radius: 6px; }
        table { border-collapse: collapse; width: auto; max-width: 100%; }
        th, td { border: 1px solid #d1d1d6; padding: 0.4em 0.75em; text-align: left; vertical-align: top; }
        th { background: #f5f5f7; font-weight: 600; }
        hr { border: none; border-top: 1px solid #d1d1d6; margin: 1.8em 0; }
        mark { background: #fff3a3; color: inherit; padding: 0 0.1em; }
        a { color: #0066cc; text-decoration: none; }
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
        let html = htmlDocument(markdown: markdown, title: title, fontChoice: fontChoice, customFamily: customFamily, target: .richText)
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        if let baseURL { options[.baseURL] = baseURL }
        return try NSAttributedString(data: Data(html.utf8), options: options, documentAttributes: nil)
    }
}

/// Lays HTML out in pages with WebKit (full CSS: tables, quotes, code blocks,
/// checkboxes) and saves it as a PDF or sends it to the printer.
@MainActor
final class PagedPrinter: NSObject, WKNavigationDelegate {
    enum Destination { case file(URL), printer(NSWindow?) }

    private static var active: Set<PagedPrinter> = []
    private let webView: WKWebView
    private let window: NSWindow
    private let info: NSPrintInfo
    private let title: String
    private let destination: Destination
    private var continuation: CheckedContinuation<Void, Error>?

    static func run(html: String, title: String, destination: Destination) async throws {
        let printer = PagedPrinter(title: title, destination: destination)
        active.insert(printer)
        defer { active.remove(printer) }
        try await withCheckedThrowingContinuation { continuation in
            printer.continuation = continuation
            printer.webView.loadHTMLString(html, baseURL: nil)
        }
    }

    private init(title: String, destination: Destination) {
        self.title = title
        self.destination = destination
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.topMargin = Exporter.pageMargin
        info.bottomMargin = Exporter.pageMargin
        info.leftMargin = Exporter.pageMargin
        info.rightMargin = Exporter.pageMargin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        if case .file(let url) = destination {
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        }
        self.info = info
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 800))
        window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.contentView = webView
        webView.navigationDelegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let op = webView.printOperation(with: info)
        op.jobTitle = title
        op.view?.frame = webView.bounds
        let host: NSWindow
        switch destination {
        case .file:
            op.showsPrintPanel = false
            op.showsProgressPanel = false
            host = window
        case .printer(let parent):
            op.showsPrintPanel = true
            op.showsProgressPanel = true
            host = parent ?? window
        }
        op.runModal(for: host, delegate: self, didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }

    /// AppKit may call this from its print thread.
    @objc nonisolated private func printOperationDidRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if case .file = self.destination, !success { self.finish(CocoaError(.fileWriteUnknown)) } else { self.finish(nil) }
            }
        }
    }

    private func finish(_ error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        window.close()
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}
