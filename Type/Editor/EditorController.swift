import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SlashState: Equatable {
    var anchor: Int          // location of the "/"
    var query: String = ""
    var rect: CGRect = .zero // caret rect in editor (top-left origin) coordinates
    var selection = 0
    /// Set for the Format menu: the text selection it applies to (`anchor` and `query` then mean nothing
    /// to the text; the query filters the list only).
    var format: NSRange?
    /// Format menu: top line of the selection, where the menu goes when it flips above (`rect` is the last line).
    var aboveRect: CGRect?
    /// Format menu: inline formats the whole selection already has (checkmarked), worked out once on opening.
    var active: Set<InlineFormat> = []
}

struct SlashCommand: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let keywords: [String]
    /// Format menu: key equivalent shown beside the title, and the inline format whose active state gets a checkmark.
    var shortcut: String? = nil
    var format: InlineFormat? = nil
    let run: (EditorController, NSRange) -> Void
}

/// Per-window bridge between SwiftUI (toolbar, menus, overlays) and the text view.
struct EditorViewState {
    var selection: NSRange
    var scrollY: CGFloat
}

@MainActor
final class EditorController: ObservableObject {
    weak var textView: TypeTextView?

    @Published var stats = DocumentStats()
    @Published var outline: [OutlineItem] = []
    @Published var slash: SlashState?
    @Published var chromeVisible = true
    @Published var currentHeading: OutlineItem?

    var fileURL: URL?
    var title: String { fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled" }

    private var analysisTask: Task<Void, Never>?
    /// Closes the Format menu when the editor scrolls away from the selection it was opened on.
    var formatScrollObserver: NSObjectProtocol?
    private var chrome = ChromeVisibility()

    // MARK: Activity

    /// Hides the chrome on a keystroke (once; repeated keys don't re-run the animation).
    func userTyped() {
        guard AppSettings.shared.autoHideChrome else { return }
        guard chrome.hide(at: ProcessInfo.processInfo.systemUptime) else { return }
        withAnimation(.smooth(duration: 0.35)) { chromeVisible = false }
    }

    /// Shows the chrome only for real pointer movement (see `ChromeVisibility`).
    /// Reads the screen position, so it is safe to call from hover and mouse-move
    /// callbacks that fire while the content shifts under a still pointer.
    func mouseMoved() {
        guard chrome.pointerMoved(to: NSEvent.mouseLocation, at: ProcessInfo.processInfo.systemUptime) else { return }
        withAnimation(.smooth(duration: 0.25)) { chromeVisible = true }
    }

    // MARK: Analysis

    func scheduleAnalysis(_ text: String) {
        analysisTask?.cancel()
        analysisTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .utility) { DocumentAnalysis.analyze(text) }.value
            guard !Task.isCancelled, let self else { return }
            if self.stats != result.0 { self.stats = result.0 }
            if self.outline != result.1 { self.outline = result.1 }
            self.updateCurrentHeading()
        }
    }

    func updateCurrentHeading() {
        guard let tv = textView else { return }
        let loc = tv.selectedRange().location
        let h = outline.last { $0.location <= loc }
        if h != currentHeading { currentHeading = h }
    }

    // MARK: Formatting

    func bold() { textView?.toggleFormat(.bold) }
    func italic() { textView?.toggleFormat(.italic) }
    func strikethrough() { textView?.toggleFormat(.strike) }
    func highlight() { textView?.toggleFormat(.highlight) }
    func inlineCode() { textView?.toggleFormat(.code) }
    func heading(_ level: Int) {
        if level == 0 { textView?.setLinePrefix("", kind: .heading) }
        else { textView?.setLinePrefix(String(repeating: "#", count: level) + " ", kind: .heading) }
    }
    func bulletList() { textView?.setLinePrefix("- ", kind: .list) }
    func numberedList() { textView?.setLinePrefix("1. ", kind: .numbered) }
    func taskList() { textView?.setLinePrefix("- [ ] ", kind: .task) }
    func quote() { textView?.setLinePrefix("> ", kind: .quote) }

    private var linkPopover: NSPopover?

    /// ⌘K: a small popover to add, edit or remove the link at the selection.
    func link() {
        guard let tv = textView, tv.window != nil else { return }
        linkPopover?.close()
        let target = tv.linkTarget()
        let clipboard = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let clipURL = clipboard.flatMap { URL(string: $0) }?.scheme?.hasPrefix("http") == true ? clipboard : nil
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let finish: () -> Void = { [weak popover, weak tv] in
            popover?.close()
            if let tv { tv.window?.makeFirstResponder(tv) }
        }
        let editor = LinkEditorView(
            label: target.label, url: target.isExisting ? target.url : (clipURL ?? ""),
            needsLabel: target.label.isEmpty, isExisting: target.isExisting,
            onApply: { [weak tv] label, url in finish(); tv?.applyLink(target, label: label, url: url) },
            onRemove: { [weak tv] in finish(); tv?.removeLink(target) },
            onCancel: finish)
        let host = NSHostingController(rootView: editor)
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: tv.firstLineRect(for: target.range).insetBy(dx: 0, dy: -2), of: tv, preferredEdge: .maxY)
        linkPopover = popover
    }

    func comment() {
        guard let tv = textView else { return }
        let sel = tv.selectedRange()
        if sel.length > 0 {
            let inner = (tv.string as NSString).substring(with: sel)
            tv.replace(sel, with: "<!-- \(inner) -->", caret: nil, select: NSRange(location: sel.location + 5, length: (inner as NSString).length))
        } else {
            tv.replace(sel, with: "<!--  -->", caret: sel.location + 5)
        }
    }

    func codeBlock() { textView?.insertSnippet("```\n\n```\n", caretOffset: 4) }
    func divider() { textView?.insertSnippet("\n---\n") }
    static let tableSnippet = "|  |  |  |\n| --- | --- | --- |\n|  |  |  |"
    func table() {
        textView?.insertSnippet(Self.tableSnippet + "\n", caretOffset: 2)
    }
    func insertDate() {
        let f = DateFormatter()
        f.dateStyle = .long
        textView?.insertText(f.string(from: .now), replacementRange: textView?.selectedRange() ?? NSRange(location: 0, length: 0))
    }

    func insertImage() {
        guard let tv = textView, let window = tv.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let tv = self.textView else { return }
            let pb = NSPasteboard(name: NSPasteboard.Name("TypeImagePick-\(UUID().uuidString)"))
            pb.clearContents()
            pb.writeObjects(panel.urls as [NSURL])
            if let saved = self.saveImages(from: pb) { tv.insertImages(saved) }
            pb.releaseGlobally()
        }
    }

    /// True for pages inside the notebook library (images go to the notebook's `.assets`).
    var inLibrary = false
    /// Caret and scroll position per document shown in this window, so they
    /// survive switching pages and rebuilding the editor.
    var viewStates: [AnyHashable: EditorViewState] = [:]

    /// Copies pasteboard images into the document's assets folder.
    func saveImages(from pb: NSPasteboard) -> [ImageStore.Saved]? {
        do {
            return try ImageStore.saveImages(from: pb, documentURL: fileURL, inLibrary: inLibrary)
        } catch {
            if let window = textView?.window { NSAlert(error: error).beginSheetModal(for: window) }
            return nil
        }
    }

    // MARK: Navigation

    func reveal(_ item: OutlineItem) {
        guard let tv = textView else { return }
        // The outline can lag behind the text, so its offsets may be past the end.
        let length = (tv.string as NSString).length
        let location = min(max(0, item.location), length)
        tv.setSelectedRange(NSRange(location: location, length: 0))
        tv.window?.makeFirstResponder(tv)
        if let clip = tv.enclosingScrollView?.contentView {
            let caret = tv.caretRect(at: location)
            let y = max(0, caret.minY - clip.bounds.height * 0.25)
            if Motion.reduced {
                clip.setBoundsOrigin(NSPoint(x: 0, y: y))
            } else {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.3
                    ctx.allowsImplicitAnimation = true
                    clip.animator().setBoundsOrigin(NSPoint(x: 0, y: y))
                }
            }
            tv.enclosingScrollView?.reflectScrolledClipView(clip)
        }
        tv.showFindIndicator(for: NSRange(location: location, length: min(item.title.utf16.count + item.level + 1, length - location)))
    }

    func showFind(replace: Bool = false) {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
        let item = NSMenuItem()
        item.tag = Int((replace ? NSTextFinder.Action.showReplaceInterface : .showFindInterface).rawValue)
        tv.performTextFinderAction(item)
    }

    // MARK: Slash menu

    static let slashCommands: [SlashCommand] = [
        SlashCommand(id: "h1", title: "Heading 1", subtitle: "Large section title", symbol: "textformat.size.larger", keywords: ["title", "h1"]) { c, r in c.applySlash(r, "# ") },
        SlashCommand(id: "h2", title: "Heading 2", subtitle: "Medium section title", symbol: "textformat.size", keywords: ["subtitle", "h2"]) { c, r in c.applySlash(r, "## ") },
        SlashCommand(id: "h3", title: "Heading 3", subtitle: "Small section title", symbol: "textformat.size.smaller", keywords: ["h3"]) { c, r in c.applySlash(r, "### ") },
        SlashCommand(id: "ul", title: "Bulleted List", subtitle: "Simple bullet points", symbol: "list.bullet", keywords: ["bullet", "unordered", "ul"]) { c, r in c.applySlash(r, "- ") },
        SlashCommand(id: "ol", title: "Numbered List", subtitle: "Ordered steps", symbol: "list.number", keywords: ["ordered", "ol", "number"]) { c, r in c.applySlash(r, "1. ") },
        SlashCommand(id: "todo", title: "Checklist", subtitle: "Track tasks", symbol: "checklist", keywords: ["task", "todo", "check"]) { c, r in c.applySlash(r, "- [ ] ") },
        SlashCommand(id: "quote", title: "Quote", subtitle: "Call out a passage", symbol: "text.quote", keywords: ["blockquote", "cite"]) { c, r in c.applySlash(r, "> ") },
        SlashCommand(id: "code", title: "Code Block", subtitle: "Monospaced code", symbol: "chevron.left.forwardslash.chevron.right", keywords: ["code", "pre", "snippet"]) { c, r in c.applySlash(r, "```\n\n```", caret: 4) },
        SlashCommand(id: "table", title: "Table", subtitle: "3 × 3 grid", symbol: "tablecells", keywords: ["grid", "table"]) { c, r in
            c.applySlash(r, EditorController.tableSnippet, caret: 2)
        },
        SlashCommand(id: "image", title: "Image…", subtitle: "Insert a picture", symbol: "photo", keywords: ["picture", "img", "photo"]) { c, r in c.applySlash(r, ""); c.insertImage() },
        SlashCommand(id: "hr", title: "Divider", subtitle: "Separate sections", symbol: "minus", keywords: ["rule", "hr", "line", "separator"]) { c, r in c.applySlash(r, "---\n") },
        SlashCommand(id: "comment", title: "Comment", subtitle: "Private note, not counted", symbol: "text.bubble", keywords: ["note", "comment"]) { c, r in c.applySlash(r, "<!--  -->", caret: 5) },
        SlashCommand(id: "date", title: "Today’s Date", subtitle: "Insert the current date", symbol: "calendar", keywords: ["date", "today", "time"]) { c, r in
            let f = DateFormatter(); f.dateStyle = .long
            c.applySlash(r, f.string(from: .now))
        },
    ]

    var filteredSlashCommands: [SlashCommand] {
        filteredCommands(slash?.format != nil ? Self.formatCommands : Self.slashCommands, query: slash?.query ?? "")
    }

    private func filteredCommands(_ all: [SlashCommand], query: String) -> [SlashCommand] {
        let q = query.lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.title.lowercased().contains(q) || $0.keywords.contains { $0.hasPrefix(q) } }
    }

    func beginSlash(at location: Int) {
        guard let tv = textView, let scroll = tv.enclosingScrollView else { return }
        var state = SlashState(anchor: location)
        state.rect = rectInEditor(tv.caretRect(at: location), tv: tv, scroll: scroll)
        withAnimation(.snappy(duration: 0.2)) { slash = state }
    }

    func updateSlash() {
        guard var state = slash, let tv = textView else { return }
        if let selection = state.format {
            if tv.selectedRange() != selection { cancelSlash() }
            return
        }
        let ns = tv.string as NSString
        let caret = tv.selectedRange().location
        guard state.anchor < ns.length, ns.character(at: state.anchor) == 47 /* "/" */, caret > state.anchor else { cancelSlash(); return }
        let query = ns.substring(with: NSRange(location: state.anchor + 1, length: caret - state.anchor - 1))
        if query.contains(where: { $0.isWhitespace }) || query.count > 20 { cancelSlash(); return }
        state.query = query
        let count = filteredCommands(Self.slashCommands, query: query).count
        if count == 0 && query.count > 3 { cancelSlash(); return }
        state.selection = min(state.selection, max(0, count - 1))
        slash = state
    }

    func cancelSlash() {
        if slash != nil { withAnimation(.snappy(duration: 0.15)) { slash = nil } }
    }

    func handleSlashKey(_ selector: Selector) -> Bool {
        guard var state = slash else { return false }
        if state.format != nil, NSStringFromSelector(selector).hasPrefix("delete") { return backspaceInFormatMenu() }
        let items = filteredSlashCommands
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            state.selection = items.isEmpty ? 0 : (state.selection + 1) % items.count
            slash = state
            return true
        case #selector(NSResponder.moveUp(_:)):
            state.selection = items.isEmpty ? 0 : (state.selection - 1 + items.count) % items.count
            slash = state
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            if state.format != nil, items.isEmpty { NSSound.beep(); return true }
            guard !items.isEmpty else { cancelSlash(); return false }
            runSlash(items[state.selection])
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelSlash()
            return true
        case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)):
            cancelSlash()
            return false
        default:
            // Any other command (selection moves, ⌘A...) leaves the Format menu; the selection stays as the command leaves it.
            if state.format != nil { cancelSlash() }
            return false
        }
    }

    func runSlash(_ command: SlashCommand) {
        guard let state = slash, let tv = textView else { return }
        if state.format != nil {
            slash = nil
            tv.window?.makeFirstResponder(tv)
            command.run(self, tv.selectedRange())
            return
        }
        let caret = tv.selectedRange().location
        let range = NSRange(location: state.anchor, length: max(1, caret - state.anchor))
        slash = nil
        command.run(self, range)
    }

    fileprivate func applySlash(_ range: NSRange, _ text: String, caret: Int? = nil) {
        guard let tv = textView else { return }
        tv.replace(range, with: text, caret: range.location + (caret ?? (text as NSString).length))
    }

    func rectInEditor(_ r: NSRect, tv: NSTextView, scroll: NSScrollView) -> CGRect {
        let inScroll = tv.convert(r, to: scroll)
        let y = scroll.isFlipped ? inScroll.minY : scroll.bounds.height - inScroll.maxY
        return CGRect(x: inScroll.minX, y: y, width: inScroll.width, height: inScroll.height)
    }

    // MARK: Export & print

    func export(_ format: ExportFormat, fontChoice: FontChoice, customFamily: String) {
        guard let tv = textView, let window = tv.window else { return }
        Exporter.export(markdown: tv.string, title: title, baseURL: fileURL?.deletingLastPathComponent(), format: format,
                        fontChoice: fontChoice, customFamily: customFamily, window: window)
    }

    func printDocument(fontChoice: FontChoice, customFamily: String) {
        guard let tv = textView else { return }
        Exporter.print(markdown: tv.string, title: title, baseURL: fileURL?.deletingLastPathComponent(),
                       fontChoice: fontChoice, customFamily: customFamily, window: tv.window)
    }
}
