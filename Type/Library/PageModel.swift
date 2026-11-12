import Foundation
import AppKit

/// One page (a Markdown file) open for editing. Shared between windows showing
/// the same page; saves itself shortly after typing stops.
@MainActor
final class PageModel: ObservableObject, Identifiable {
    @Published private(set) var url: URL
    @Published var text: String {
        didSet {
            guard !isLoading, text != oldValue else { return }
            isDirty = true
            scheduleSave()
        }
    }
    let undoManager = UndoManager()
    private(set) var isDirty = false
    private(set) var lastSavedModification: Date?
    /// The text as last read from or written to disk (to tell an outside edit from our own save).
    private var lastSavedText = ""
    /// Set when an outside edit was found at save time; the outside version was kept as a copy.
    @Published private(set) var conflict: Conflict?
    private var isLoading = false
    private var saveTask: Task<Void, Never>?
    private(set) var isDeleted = false

    /// An outside edit that collided with unsaved changes: the page keeps the
    /// in-editor text and the outside version was saved next to it as `copy`.
    struct Conflict: Equatable {
        let copy: URL
    }

    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
    /// Text of the first heading (the page's name in the library).
    var heading: String? { LibraryStore.firstHeading(in: text) }
    var title: String { heading ?? url.deletingPathExtension().lastPathComponent }

    /// The edit that gives the page the name `newTitle`: rewrites the first heading,
    /// or adds one (below any YAML front matter). Nil when the name is unchanged,
    /// so committing an untouched rename never touches the text.
    func headingEdit(for newTitle: String) -> (range: NSRange, replacement: String)? {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != self.title else { return nil }
        let ns = text as NSString
        var inFence = false
        var location = LibraryStore.frontMatterLength(in: ns)
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            let content = ns.substring(with: line).trimmingCharacters(in: .newlines)
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
            else if !inFence, let m = try? NSRegularExpression(pattern: #"^(#{1,6})[ \t]*"#).firstMatch(in: content, range: NSRange(location: 0, length: (content as NSString).length)),
                    LibraryStore.firstHeading(in: content) != nil || trimmed.allSatisfy({ $0 == "#" }) {
                let hashes = (content as NSString).substring(with: m.range(at: 1))
                return (NSRange(location: line.location, length: (content as NSString).length), hashes + " " + title)
            }
            location = NSMaxRange(line)
        }
        let at = LibraryStore.frontMatterLength(in: ns)
        let rest = ns.length > at
        return (NSRange(location: at, length: 0), "# " + title + (rest ? "\n\n" : ""))
    }

    /// Sets the page's name by rewriting its first heading (or adding one at the top).
    /// Use `headingEdit` to route the change through a live editor as an undoable edit.
    func setHeading(_ newTitle: String) {
        guard let edit = headingEdit(for: newTitle) else { return }
        text = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    init(url: URL) {
        self.url = url
        self.text = ""
        load()
    }

    func load() {
        isLoading = true
        defer { isLoading = false }
        if let data = try? Data(contentsOf: url) {
            let decoded = TypeDocument.decode(data)
            // An outside edit invalidates this page's undo history.
            if decoded != text, !text.isEmpty { undoManager.removeAllActions() }
            text = decoded
        }
        isDirty = false
        lastSavedText = text
        lastSavedModification = Self.modificationDate(url)
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes pending changes immediately.
    @discardableResult
    func saveNow() -> Bool {
        saveTask?.cancel()
        guard isDirty, !isDeleted else { return true }
        guard keepOutsideEdit() else { return false }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            isDirty = false
            lastSavedText = text
            lastSavedModification = Self.modificationDate(url)
            return true
        } catch {
            NSLog("Type: failed to save \(url.path): \(error)")
            return false
        }
    }

    /// If another app changed the file since we last read or wrote it, saves that
    /// version as "<name> (conflict <date>)" beside the page, so overwriting the
    /// file with the editor's text never loses it.
    /// Returns false (don't write) if that copy couldn't be made.
    private func keepOutsideEdit() -> Bool {
        guard let mod = Self.modificationDate(url), mod != lastSavedModification,
              let data = try? Data(contentsOf: url), TypeDocument.decode(data) != lastSavedText else { return true }
        let stamp = Self.conflictStamp.string(from: Date())
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "md" : url.pathExtension
        var copy = url.deletingLastPathComponent().appendingPathComponent("\(name) (conflict \(stamp)).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: copy.path) {
            copy = url.deletingLastPathComponent().appendingPathComponent("\(name) (conflict \(stamp) \(n)).\(ext)")
            n += 1
        }
        do {
            try data.write(to: copy, options: .withoutOverwriting)
            conflict = Conflict(copy: copy)
            return true
        } catch {
            NSLog("Type: couldn't keep the outside version of \(url.path): \(error)")
            return false
        }
    }

    func dismissConflict() { conflict = nil }

    private static let conflictStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return f
    }()

    /// Picks up edits made by other apps, unless we have unsaved changes.
    func reloadIfChangedOnDisk() {
        guard !isDirty, !isDeleted, let mod = Self.modificationDate(url) else { return }
        if let last = lastSavedModification, abs(mod.timeIntervalSince(last)) < 0.001 { return }
        load()
    }

    func didMove(to newURL: URL) { url = newURL }
    func markDeleted() { isDeleted = true; saveTask?.cancel() }

    /// The file's modification date, read fresh (a `URL`'s resource values are cached).
    nonisolated static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
