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

    nonisolated static let pageExtensions: Set<String> = ["md", "markdown", "txt"]

    @Published private(set) var rootURL: URL
    @Published private(set) var notebooks: [Notebook] = []
    @Published private(set) var pages: [URL: [PageInfo]] = [:]

    private let openPages = NSMapTable<NSURL, PageModel>.strongToWeakObjects()
    private var watcher: DirectoryWatcher?
    private let watch: Bool
    private let fm = FileManager.default
    private let scanner = LibraryScanner()
    private var scanGeneration = 0
    /// How many times the listing was rebuilt (for tests).
    private(set) var scanCount = 0
    /// Moves an item to the Trash (replaceable in tests so they don't fill the real Trash).
    var trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

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
        watcher = DirectoryWatcher(url: rootURL) { [weak self] paths in
            Task { @MainActor in self?.externalChange(paths) }
        }
    }

    /// Reacts to file system events. Our own autosaves are skipped (they would
    /// otherwise rescan the whole library on every pause in typing, and re-sort
    /// the open page to the top of the list while it is being written).
    func externalChange(_ paths: [String]) {
        guard paths.contains(where: { !isOwnWrite($0) }) else { return }
        refreshInBackground()
        for case let page as PageModel in openPages.objectEnumerator()?.allObjects ?? [] {
            if fm.fileExists(atPath: page.url.path) { page.reloadIfChangedOnDisk() }
        }
    }

    /// Whether an event at `path` is the echo of a page saving itself: the
    /// atomic write's temporary file, or the page file with the date we wrote.
    private func isOwnWrite(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if url.lastPathComponent.contains(".sb-"), !fm.fileExists(atPath: path) { return true }
        guard let page = openPages.object(forKey: url as NSURL), let saved = page.lastSavedModification else { return false }
        return PageModel.modificationDate(url) == saved
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
        scanGeneration += 1
        apply(scanner.scan(root: rootURL))
    }

    /// Rebuilds the listing off the main thread (headings are read from disk).
    private func refreshInBackground() {
        scanGeneration += 1
        let generation = scanGeneration, root = rootURL, scanner = scanner
        Task.detached(priority: .utility) {
            let result = scanner.scan(root: root)
            await MainActor.run { [weak self] in
                guard let self, generation == self.scanGeneration else { return }
                self.apply(result)
            }
        }
    }

    private func apply(_ result: LibraryScanner.Result) {
        scanCount += 1
        if result.notebooks != notebooks { notebooks = result.notebooks }
        if result.pages != pages { pages = result.pages }
    }

    func pages(in notebook: URL?, sort: PageSort) -> [PageInfo] {
        guard let notebook, let list = pages[notebook.standardizedFileURL] else { return [] }
        switch sort {
        case .modified: return list.sorted { $0.modified > $1.modified }
        case .name: return list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    nonisolated private static let headingLine = try! NSRegularExpression(pattern: #"^#{1,6}[ \t]+(.*\S)[ \t#]*$"#, options: [.anchorsMatchLines])

    /// UTF-16 length of the YAML front matter at the top of `text` (through its
    /// closing `---` line), or 0 if there is none.
    nonisolated static func frontMatterLength(in text: NSString) -> Int {
        guard text.hasPrefix("---") else { return 0 }
        var location = 0
        var first = true
        while location < text.length {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            let content = text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if first {
                guard content == "---" else { return 0 }
                first = false
            } else if content == "---" || content == "..." {
                return NSMaxRange(line)
            }
            location = NSMaxRange(line)
        }
        return 0
    }

    /// Text of the first ATX heading outside code fences and front matter, without inline markup.
    nonisolated static func firstHeading(in text: String) -> String? {
        var inFence = false
        var body = Substring(text)
        if text.hasPrefix("---") {
            let skip = frontMatterLength(in: text as NSString)
            if skip > 0 { body = Substring((text as NSString).substring(from: skip)) }
        }
        for line in body.split(separator: "\n", omittingEmptySubsequences: false).prefix(400) {
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

    /// `data` without a trailing, cut-off UTF-8 sequence.
    nonisolated static func validUTF8Prefix(_ data: Data) -> Data {
        var back = 0
        while back < 3, back < data.count {
            let b = data[data.endIndex - 1 - back]
            if b & 0xC0 == 0x80 { back += 1; continue }
            let needed = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1
            return needed > back + 1 ? data.dropLast(back + 1) : data
        }
        return data
    }

    /// The first heading in the start of a file (reading more if front matter pushes it down).
    nonisolated static func heading(of url: URL, chunk: Int = 4096) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var size = chunk
        while true {
            try? handle.seek(toOffset: 0)
            let data = (try? handle.read(upToCount: size)) ?? Data()
            let text = String(decoding: validUTF8Prefix(data), as: UTF8.self)
            let unfinishedFrontMatter = data.count == size && text.hasPrefix("---") && frontMatterLength(in: text as NSString) == 0
            if unfinishedFrontMatter, size < 128 * chunk { size *= 4; continue }
            return firstHeading(in: text)
        }
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
        GoalStore.moveGoals(from: url, to: dest)
        reassignOpenPages(from: url, to: dest)
        refresh()
        return dest.standardizedFileURL
    }

    func deleteNotebook(_ url: URL) throws {
        let doomed = openModels.filter { $0.url.path.hasPrefix(url.standardizedFileURL.path + "/") }
        try trash(url)
        forget(doomed)
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
        GoalStore.moveGoals(from: url, to: dest)
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
        let rewritten = copyReferencedAssets(of: url, to: notebook)
        try fm.moveItem(at: url, to: dest)
        GoalStore.moveGoals(from: url, to: dest)
        reassignOpenPages(from: url, to: dest)
        if let rewritten {
            try? Data(rewritten.utf8).write(to: dest, options: .atomic)
            openPages.object(forKey: dest.standardizedFileURL as NSURL)?.load()
        }
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
        let doomed = openPages.object(forKey: url.standardizedFileURL as NSURL).map { [$0] } ?? []
        try trash(url)
        forget(doomed)
        refresh()
    }

    /// Retires models of trashed pages, so a new page created at the same path gets a fresh one.
    private func forget(_ models: [PageModel]) {
        for model in models {
            model.markDeleted()
            openPages.removeObject(forKey: model.url as NSURL)
        }
    }

    private var openModels: [PageModel] {
        (openPages.objectEnumerator()?.allObjects ?? []).compactMap { $0 as? PageModel }
    }

    private static let assetRef = try! NSRegularExpression(pattern: #"\]\((\.assets/[^)\s]+)"#)

    /// Copies the images a page references into the destination notebook. A
    /// same-named image that differs from ours is kept alongside under a new name;
    /// returns the page's Markdown with those references updated, or nil if none changed.
    private func copyReferencedAssets(of page: URL, to notebook: URL) -> String? {
        guard let text = try? String(contentsOf: page, encoding: .utf8) else { return nil }
        let ns = text as NSString
        let srcDir = page.deletingLastPathComponent()
        var renamed: [String: String] = [:]
        var edits: [(NSRange, String)] = []
        for m in Self.assetRef.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let rel = ns.substring(with: m.range(at: 1))
            if let target = renamed[rel] { edits.append((m.range(at: 1), target)); continue }
            let decoded = rel.removingPercentEncoding ?? rel
            let src = srcDir.appendingPathComponent(decoded)
            guard fm.fileExists(atPath: src.path) else { continue }
            var dst = notebook.appendingPathComponent(decoded)
            var n = 2
            while fm.fileExists(atPath: dst.path), !fm.contentsEqual(atPath: src.path, andPath: dst.path) {
                let base = ((decoded as NSString).deletingPathExtension) + " \(n)"
                let name = (decoded as NSString).pathExtension.isEmpty ? base : base + "." + (decoded as NSString).pathExtension
                dst = notebook.appendingPathComponent(name)
                n += 1
            }
            if !fm.fileExists(atPath: dst.path) {
                try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.copyItem(at: src, to: dst)
            }
            let newRel = String(dst.standardizedFileURL.path.dropFirst(notebook.standardizedFileURL.path.count + 1))
            guard newRel != decoded else { continue }
            let encoded = newRel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? newRel
            renamed[rel] = encoded
            edits.append((m.range(at: 1), encoded))
        }
        guard !edits.isEmpty else { return nil }
        var out = ns
        for (range, replacement) in edits.sorted(by: { $0.0.location > $1.0.location }) {
            out = out.replacingCharacters(in: range, with: replacement) as NSString
        }
        return out as String
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
    - Press ⇧⌘F for **focus mode** and ⌃⌘T for *typewriter scrolling*
    - [ ] Try turning on **Hide Markdown syntax** in Settings ▸ Typography
    - [ ] Pick a typing sound in Settings ▸ Sound

    > Show the outline of this page with the button at the top right.
    """
}

/// Reads the library's folders and pages. Safe to call from any thread; headings
/// are cached by modification date so a rescan mostly just stats files.
final class LibraryScanner: @unchecked Sendable {
    struct Result {
        var notebooks: [Notebook]
        var pages: [URL: [PageInfo]]
    }

    private var headings: [URL: (modified: Date, heading: String?)] = [:]
    private let lock = NSLock()

    func scan(root: URL) -> Result {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles])) ?? []
        var pages: [URL: [PageInfo]] = [:]
        var notebooks: [Notebook] = []
        var seen: [URL: (modified: Date, heading: String?)] = [:]
        for dir in dirs {
            let values = try? dir.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            guard values?.isDirectory == true, values?.isPackage != true else { continue }
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
            let list = files.filter { LibraryStore.pageExtensions.contains($0.pathExtension.lowercased()) }.map { file -> PageInfo in
                let url = file.standardizedFileURL
                let modified = PageModel.modificationDate(url) ?? .distantPast
                lock.lock(); let cached = headings[url]; lock.unlock()
                let heading = cached?.modified == modified ? cached?.heading : LibraryStore.heading(of: url)
                seen[url] = (modified, heading)
                return PageInfo(url: url, modified: modified, heading: heading)
            }
            pages[dir.standardizedFileURL] = list
            notebooks.append(Notebook(url: dir.standardizedFileURL, pageCount: list.count))
        }
        notebooks.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        lock.lock(); headings = seen; lock.unlock()
        return Result(notebooks: notebooks, pages: pages)
    }
}
