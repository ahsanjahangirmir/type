import Foundation
import AppKit

struct Notebook: Identifiable, Hashable {
    let url: URL
    var pageCount: Int
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

struct PageInfo: Identifiable, Hashable {
    let url: URL
    let modified: Date
    /// Text of the page's first heading, if it has one.
    let heading: String?
    var id: URL { url }
    var fileName: String { url.deletingPathExtension().lastPathComponent }
    /// Pages are named by their first heading (like OneNote), falling back to the file name.
    var title: String { heading ?? fileName }
}

/// The notebook library: a root folder whose subfolders are notebooks and
/// whose Markdown files are pages.
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore(rootURL: URL(fileURLWithPath: AppSettings.shared.libraryPath), watch: true)

    static let pageExtensions: Set<String> = ["md", "markdown", "txt"]

    @Published private(set) var rootURL: URL
    @Published private(set) var notebooks: [Notebook] = []
    @Published private(set) var pages: [URL: [PageInfo]] = [:]

    private let openPages = NSMapTable<NSURL, PageModel>.strongToWeakObjects()
    private var watcher: DirectoryWatcher?
    private let watch: Bool
    private let fm = FileManager.default

    init(rootURL: URL, watch: Bool = false) {
        self.rootURL = rootURL
        self.watch = watch
        prepareRoot()
        refresh()
        startWatching()
    }

    func setRoot(_ url: URL) {
        saveAll()
        rootURL = url
        prepareRoot()
        refresh()
        startWatching()
    }

    private func startWatching() {
        guard watch else { return }
        watcher = DirectoryWatcher(url: rootURL) { [weak self] in
            Task { @MainActor in self?.externalChange() }
        }
    }

    private func externalChange() {
        refresh()
        for case let page as PageModel in openPages.objectEnumerator()?.allObjects ?? [] {
            if fm.fileExists(atPath: page.url.path) { page.reloadIfChangedOnDisk() }
        }
    }

    /// Creates the library folder (with a welcome notebook) on first use.
    private func prepareRoot() {
        guard !fm.fileExists(atPath: rootURL.path) else { return }
        try? fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let nb = rootURL.appendingPathComponent("Getting Started", isDirectory: true)
        try? fm.createDirectory(at: nb, withIntermediateDirectories: true)
        try? Data(Self.welcomeText.utf8).write(to: nb.appendingPathComponent("Welcome.md"))
    }

    // MARK: Listing

    func refresh() {
        let dirs = (try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles])) ?? []
        var newPages: [URL: [PageInfo]] = [:]
        var newNotebooks: [Notebook] = []
        for dir in dirs {
            let values = try? dir.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            guard values?.isDirectory == true, values?.isPackage != true else { continue }
            let list = listPages(in: dir)
            newPages[dir.standardizedFileURL] = list
            newNotebooks.append(Notebook(url: dir.standardizedFileURL, pageCount: list.count))
        }
        newNotebooks.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if newNotebooks != notebooks { notebooks = newNotebooks }
        if newPages != pages { pages = newPages }
    }

    private func listPages(in dir: URL) -> [PageInfo] {
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        return files.filter { Self.pageExtensions.contains($0.pathExtension.lowercased()) }.map { url in
            PageInfo(url: url.standardizedFileURL,
                     modified: PageModel.modificationDate(url) ?? .distantPast,
                     heading: Self.heading(of: url))
        }
    }

    func pages(in notebook: URL?, sort: PageSort) -> [PageInfo] {
        guard let notebook, let list = pages[notebook.standardizedFileURL] else { return [] }
        switch sort {
        case .modified: return list.sorted { $0.modified > $1.modified }
        case .name: return list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    /// The first heading in the start of a file.
    private static func heading(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 4096)) ?? Data()
        return firstHeading(in: String(decoding: data, as: UTF8.self))
    }

    private static let headingLine = try! NSRegularExpression(pattern: #"^#{1,6}[ \t]+(.*\S)[ \t#]*$"#, options: [.anchorsMatchLines])

    /// Text of the first ATX heading outside code fences, without inline markup.
    static func firstHeading(in text: String) -> String? {
        var inFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(400) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); continue }
            guard !inFence, trimmed.hasPrefix("#") else { continue }
            let str = String(line)
            guard let m = headingLine.firstMatch(in: str, range: NSRange(location: 0, length: (str as NSString).length)) else { continue }
            var title = DocumentAnalysis.stripInline((str as NSString).substring(with: m.range(at: 1)))
            while title.hasSuffix("#") { title.removeLast() }
            title = title.trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return title }
        }
        return nil
    }

    // MARK: Open pages

    /// The shared model for a page (one per file, across all windows).
    func page(for url: URL) -> PageModel {
        let key = url.standardizedFileURL as NSURL
        if let existing = openPages.object(forKey: key) { return existing }
        let model = PageModel(url: url.standardizedFileURL)
        openPages.setObject(model, forKey: key)
        return model
    }

    func saveAll() {
        for case let page as PageModel in openPages.objectEnumerator()?.allObjects ?? [] { page.saveNow() }
    }

    private func reassignOpenPages(from old: URL, to new: URL) {
        let oldPath = old.standardizedFileURL.path
        for case let page as PageModel in openPages.objectEnumerator()?.allObjects ?? [] {
            let path = page.url.path
            guard path == oldPath || path.hasPrefix(oldPath + "/") else { continue }
            let moved = URL(fileURLWithPath: new.standardizedFileURL.path + path.dropFirst(oldPath.count))
            openPages.removeObject(forKey: page.url as NSURL)
            page.didMove(to: moved)
            openPages.setObject(page, forKey: moved as NSURL)
        }
    }

    // MARK: Notebooks

    @discardableResult
    func createNotebook(named name: String = "Untitled Notebook") throws -> URL {
        let url = uniqueURL(in: rootURL, base: Self.sanitize(name, fallback: "Untitled Notebook"), ext: nil)
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        refresh()
        return url.standardizedFileURL
    }

    @discardableResult
    func renameNotebook(_ url: URL, to name: String) throws -> URL {
        let base = Self.sanitize(name, fallback: url.lastPathComponent)
        guard base != url.lastPathComponent else { return url }
        saveAll()
        let dest = uniqueURL(in: rootURL, base: base, ext: nil, excluding: url)
        try fm.moveItem(at: url, to: dest)
        reassignOpenPages(from: url, to: dest)
        refresh()
        return dest.standardizedFileURL
    }

    func deleteNotebook(_ url: URL) throws {
        for case let page as PageModel in openPages.objectEnumerator()?.allObjects ?? [] where page.url.path.hasPrefix(url.path + "/") {
            page.markDeleted()
        }
        try fm.trashItem(at: url, resultingItemURL: nil)
        refresh()
    }

    // MARK: Pages

    @discardableResult
    func createPage(in notebook: URL, title: String = "Untitled", text: String = "# ") throws -> URL {
        let url = uniqueURL(in: notebook, base: Self.sanitize(title, fallback: "Untitled"), ext: "md")
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        refresh()
        return url.standardizedFileURL
    }

    @discardableResult
    func renamePage(_ url: URL, to title: String) throws -> URL {
        let base = Self.sanitize(title, fallback: url.deletingPathExtension().lastPathComponent)
        guard base != url.deletingPathExtension().lastPathComponent else { return url }
        page(for: url).saveNow()
        let dest = uniqueURL(in: url.deletingLastPathComponent(), base: base, ext: url.pathExtension.isEmpty ? "md" : url.pathExtension, excluding: url)
        guard dest.standardizedFileURL.path != url.standardizedFileURL.path else { return url }
        try fm.moveItem(at: url, to: dest)
        reassignOpenPages(from: url, to: dest)
        refresh()
        return dest.standardizedFileURL
    }

    /// Moves a page to another notebook, bringing along the images it references.
    @discardableResult
    func movePage(_ url: URL, to notebook: URL) throws -> URL {
        guard url.deletingLastPathComponent().standardizedFileURL != notebook.standardizedFileURL else { return url }
        page(for: url).saveNow()
        let dest = uniqueURL(in: notebook, base: url.deletingPathExtension().lastPathComponent, ext: url.pathExtension.isEmpty ? "md" : url.pathExtension)
        copyReferencedAssets(of: url, to: notebook)
        try fm.moveItem(at: url, to: dest)
        reassignOpenPages(from: url, to: dest)
        refresh()
        return dest.standardizedFileURL
    }

    @discardableResult
    func duplicatePage(_ url: URL) throws -> URL {
        page(for: url).saveNow()
        let dest = uniqueURL(in: url.deletingLastPathComponent(), base: url.deletingPathExtension().lastPathComponent + " copy", ext: url.pathExtension.isEmpty ? "md" : url.pathExtension)
        try fm.copyItem(at: url, to: dest)
        refresh()
        return dest.standardizedFileURL
    }

    func deletePage(_ url: URL) throws {
        if let open = openPages.object(forKey: url.standardizedFileURL as NSURL) { open.markDeleted() }
        try fm.trashItem(at: url, resultingItemURL: nil)
        refresh()
    }

    private static let assetRef = try! NSRegularExpression(pattern: #"\]\((\.assets/[^)\s]+)"#)

    private func copyReferencedAssets(of page: URL, to notebook: URL) {
        guard let text = try? String(contentsOf: page, encoding: .utf8) else { return }
        let ns = text as NSString
        let srcDir = page.deletingLastPathComponent()
        for m in Self.assetRef.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let rel = ns.substring(with: m.range(at: 1))
            let decoded = rel.removingPercentEncoding ?? rel
            let src = srcDir.appendingPathComponent(decoded)
            let dst = notebook.appendingPathComponent(decoded)
            guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { continue }
            try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: src, to: dst)
        }
    }

    // MARK: Names

    static func sanitize(_ name: String, fallback: String) -> String {
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? fallback : String(s.prefix(200))
    }

    private func uniqueURL(in dir: URL, base: String, ext: String?, excluding: URL? = nil) -> URL {
        func make(_ name: String) -> URL {
            let u = dir.appendingPathComponent(name, isDirectory: ext == nil)
            return ext.map { u.appendingPathExtension($0) } ?? u
        }
        var url = make(base)
        var n = 2
        while fm.fileExists(atPath: url.path), url.standardizedFileURL.path.lowercased() != excluding?.standardizedFileURL.path.lowercased() {
            url = make("\(base) \(n)")
            n += 1
        }
        return url
    }

    static let welcomeText = """
    # Welcome to Type

    Type is a calm place to write. Your notebooks live in the sidebar, and each notebook holds pages like this one.

    ## Notebooks & pages

    - Create a notebook with ⇧⌘N and a page with ⌘N
    - A page is named after its first heading; drag a page onto another notebook to move it
    - Everything is saved automatically as plain Markdown files in your library folder

    ## Writing

    - Type `/` on an empty line for the insert menu
    - Paste a screenshot with ⌘V, then drag its corner to resize it
    - Press ⇧⌘F for **focus mode** and ⌥⌘T for *typewriter scrolling*
    - [ ] Try turning on **Hide Markdown syntax** in Settings ▸ Typography
    - [ ] Pick a typing sound in Settings ▸ Sound

    > Show the outline of this page with the button at the top right.
    """
}
