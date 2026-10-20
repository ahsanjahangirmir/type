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
    private var isLoading = false
    private var saveTask: Task<Void, Never>?
    private(set) var isDeleted = false

    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
    /// Text of the first heading (the page's name in the library).
    var heading: String? { LibraryStore.firstHeading(in: text) }
    var title: String { heading ?? url.deletingPathExtension().lastPathComponent }

    /// Sets the page's name by rewriting its first heading (or adding one at the top).
    func setHeading(_ newTitle: String) {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let ns = text as NSString
        var inFence = false
        var location = 0
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            let content = ns.substring(with: line).trimmingCharacters(in: .newlines)
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
            else if !inFence, let m = try? NSRegularExpression(pattern: #"^(#{1,6})[ \t]*"#).firstMatch(in: content, range: NSRange(location: 0, length: (content as NSString).length)),
                    LibraryStore.firstHeading(in: content) != nil || trimmed.allSatisfy({ $0 == "#" }) {
                let hashes = (content as NSString).substring(with: m.range(at: 1))
                text = ns.replacingCharacters(in: NSRange(location: line.location, length: (content as NSString).length), with: hashes + " " + title)
                return
            }
            location = NSMaxRange(line)
        }
        text = "# " + title + (text.isEmpty ? "" : "\n\n" + text)
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
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            isDirty = false
            lastSavedModification = Self.modificationDate(url)
            return true
        } catch {
            NSLog("Type: failed to save \(url.path): \(error)")
            return false
        }
    }

    /// Picks up edits made by other apps, unless we have unsaved changes.
    func reloadIfChangedOnDisk() {
        guard !isDirty, !isDeleted, let mod = Self.modificationDate(url) else { return }
        if let last = lastSavedModification, abs(mod.timeIntervalSince(last)) < 0.001 { return }
        load()
    }

    func didMove(to newURL: URL) { url = newURL }
    func markDeleted() { isDeleted = true; saveTask?.cancel() }

    static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
