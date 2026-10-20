import SwiftUI
import UniformTypeIdentifiers
import AppKit

extension UTType {
    static let markdownText = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
    static let wordDocument = UTType("org.openxmlformats.wordprocessingml.document")
        ?? UTType(filenameExtension: "docx", conformingTo: .data)!
}

/// A Type document. The source of truth is Markdown text; RTF and Word files
/// are converted to Markdown on open and saved back out as Markdown.
struct TypeDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.markdownText, .plainText, .rtf, .wordDocument] }
    static var writableContentTypes: [UTType] { [.markdownText, .plainText] }

    var text: String

    init(text: String = "") {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let type = configuration.contentType
        if type.conforms(to: .rtf) {
            text = try RichTextImporter.markdown(from: data, type: .rtf)
        } else if type.conforms(to: .wordDocument) {
            text = try RichTextImporter.markdown(from: data, type: .officeOpenXML)
        } else {
            text = Self.decode(data)
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }

    static func decode(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        var converted: NSString?
        let enc = NSString.stringEncoding(for: data, encodingOptions: nil, convertedString: &converted, usedLossyConversion: nil)
        if enc != 0, let converted { return converted as String }
        return String(decoding: data, as: UTF8.self)
    }
}
