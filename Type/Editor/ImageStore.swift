import AppKit
import UniformTypeIdentifiers

/// Saves pasted / dropped images next to the document and builds the Markdown for them.
enum ImageStore {
    struct Saved {
        let fileURL: URL
        let markdownPath: String
        let size: NSSize
    }

    /// Where images for a document live.
    /// - Library pages: `<Notebook>/.assets/`
    /// - Saved standalone documents: `<Name>.assets/` beside the file
    /// - Untitled documents: Application Support
    static func assetsDirectory(for documentURL: URL?, inLibrary: Bool) -> URL {
        if let documentURL {
            let dir = documentURL.deletingLastPathComponent()
            if inLibrary { return dir.appendingPathComponent(".assets", isDirectory: true) }
            return dir.appendingPathComponent(documentURL.deletingPathExtension().lastPathComponent + ".assets", isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Type/Images", isDirectory: true)
    }

    /// True when the pasteboard holds an image we should paste as a picture rather than text.
    static func hasImage(_ pb: NSPasteboard) -> Bool {
        if !imageFileURLs(pb).isEmpty { return true }
        let hasText = pb.availableType(from: [.string]) != nil
        return !hasText && pb.availableType(from: [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")]) != nil
    }

    static func imageFileURLs(_ pb: NSPasteboard) -> [URL] {
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { (UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image)) == true }
    }

    /// Saves every image on the pasteboard; returns what was written.
    static func saveImages(from pb: NSPasteboard, documentURL: URL?, inLibrary: Bool) throws -> [Saved] {
        let dir = assetsDirectory(for: documentURL, inLibrary: inLibrary)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let files = imageFileURLs(pb)
        if !files.isEmpty {
            return try files.map { src in
                let dest = uniqueURL(in: dir, base: sanitize(src.deletingPathExtension().lastPathComponent), ext: src.pathExtension.lowercased())
                try FileManager.default.copyItem(at: src, to: dest)
                return Saved(fileURL: dest, markdownPath: markdownPath(for: dest, documentURL: documentURL), size: NSImage(contentsOf: dest)?.size ?? .zero)
            }
        }
        guard let image = NSImage(pasteboard: pb), let png = pngData(image) else { return [] }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let dest = uniqueURL(in: dir, base: "Screenshot-\(f.string(from: .now))", ext: "png")
        try png.write(to: dest, options: .atomic)
        return [Saved(fileURL: dest, markdownPath: markdownPath(for: dest, documentURL: documentURL), size: image.size)]
    }

    static func pngData(_ image: NSImage) -> Data? {
        if let rep = image.representations.first as? NSBitmapImageRep, let data = rep.representation(using: .png, properties: [:]) {
            return data
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Path relative to the document folder when possible (percent-encoded for Markdown).
    static func markdownPath(for file: URL, documentURL: URL?) -> String {
        let encode: (String) -> String = { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "()"))) ?? $0 }
        if let docDir = documentURL?.deletingLastPathComponent().standardizedFileURL.path {
            let path = file.standardizedFileURL.path
            if path.hasPrefix(docDir + "/") {
                return String(path.dropFirst(docDir.count + 1)).split(separator: "/").map { encode(String($0)) }.joined(separator: "/")
            }
        }
        return file.absoluteString
    }

    /// Resolves a Markdown image path against the document's folder.
    static func resolve(_ path: String, baseURL: URL?) -> URL? {
        if let url = URL(string: path), let scheme = url.scheme {
            return scheme == "file" ? url : nil // remote images aren't fetched inline
        }
        let decoded = path.removingPercentEncoding ?? path
        if decoded.hasPrefix("/") { return URL(fileURLWithPath: decoded) }
        if decoded.hasPrefix("~") { return URL(fileURLWithPath: (decoded as NSString).expandingTildeInPath) }
        return baseURL?.appendingPathComponent(decoded)
    }

    /// Default display width: natural size, capped to the text column.
    static func defaultWidth(for size: NSSize, column: CGFloat) -> Int? {
        guard size.width > 0 else { return nil }
        return size.width > column ? Int(column.rounded()) : nil
    }

    private static func sanitize(_ s: String) -> String {
        let cleaned = s.components(separatedBy: CharacterSet(charactersIn: "/:\\()[]")).joined(separator: "-")
        return cleaned.isEmpty ? "Image" : cleaned
    }

    private static func uniqueURL(in dir: URL, base: String, ext: String) -> URL {
        var url = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }
}

/// Small image cache keyed by file URL, invalidated by modification date.
final class ImageCache {
    static let shared = ImageCache()
    private var store: [URL: (Date, NSImage)] = [:]

    func image(at url: URL) -> NSImage? {
        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if let (date, img) = store[url], date == mod { return img }
        guard let img = NSImage(contentsOf: url) else { return nil }
        store[url] = (mod, img)
        return img
    }
}
