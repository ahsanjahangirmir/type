import SwiftUI
import AppKit

/// SwiftUI wrapper around `TypeTextView`.
struct EditorTextView: NSViewRepresentable {
    @Binding var text: String
    var config: EditorConfig
    var controller: EditorController
    /// Folder that relative image paths resolve against.
    var baseURL: URL?
    /// Supplied for library pages so each page keeps its own undo history.
    var undoManager: UndoManager?
    /// Identifies the document shown. When it changes, the text view is reused
    /// and its contents swapped (much faster than building a new editor).
    var documentID: AnyHashable?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.findBarPosition = .aboveContent
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 52, left: 0, bottom: 0, right: 0)

        let tv = TypeTextView(usingTextLayoutManager: false)
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 0
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.smartInsertDeleteEnabled = true
        tv.allowsDocumentBackgroundColorChange = false
        tv.layoutManager?.allowsNonContiguousLayout = true
        tv.config = config
        tv.events = context.coordinator
        tv.delegate = context.coordinator
        tv.textStorage?.delegate = context.coordinator
        tv.installLayoutDelegate()
        tv.documentBaseURL = baseURL
        let coordinator = context.coordinator
        coordinator.styler.imageProvider = { [weak tv] path in tv?.image(for: path) }
        tv.onColumnWidthChange = { [weak tv, weak coordinator] width in
            guard let tv, let coordinator else { return }
            coordinator.styler.columnWidth = width
            if coordinator.hasImages { coordinator.restyle(tv, range: nil) }
        }
        let controller = self.controller
        tv.imagePasteHandler = { pb in MainActor.assumeIsolated { controller.saveImages(from: pb) } }

        scroll.documentView = tv
        controller.textView = tv
        context.coordinator.documentID = documentID
        context.coordinator.load(text, into: tv)
        context.coordinator.placeCaretForNewDocument(tv)
        if let documentID {
            // Rebuilt editor (e.g. after hiding the lists): put the caret and scroll back.
            DispatchQueue.main.async { [weak tv] in
                guard let tv else { return }
                context.coordinator.restoreViewState(for: documentID, in: tv)
            }
        }

        DispatchQueue.main.async {
            tv.window?.makeFirstResponder(tv)
            tv.updateLayoutInsets()
        }
        return scroll
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let tv = scroll.documentView as? TypeTextView else { return }
        coordinator.saveViewState(of: tv)
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let tv = scroll.documentView as? TypeTextView else { return }
        if controller.textView !== tv { controller.textView = tv }
        if coordinator.documentID != documentID {
            coordinator.switchDocument(to: documentID, text: text, baseURL: baseURL, in: tv)
        }
        if tv.documentBaseURL != baseURL {
            tv.documentBaseURL = baseURL
            coordinator.restyle(tv, range: nil)
        }
        if config != coordinator.styler.config {
            coordinator.styler.update(config: config)
            tv.config = config
            coordinator.restyle(tv, range: nil)
            tv.typingAttributes = coordinator.styler.baseAttributes
            tv.centerCaretIfNeeded(animated: false)
        }
        // External change (revert, versions browser, etc.)
        if !coordinator.isEditing && tv.string != text {
            // The old undo steps refer to text that is gone; replaying them would hit the wrong offsets.
            tv.undoManager?.removeAllActions()
            coordinator.load(text, into: tv)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate, TypeTextViewEvents {
        var parent: EditorTextView
        let styler: MarkdownStyler
        var isEditing = false
        private(set) var hasImages = false
        private var blocks = BlockRanges()
        private var pendingEdit: NSRange?

        init(_ parent: EditorTextView) {
            self.parent = parent
            self.styler = MarkdownStyler(config: parent.config)
        }

        var documentID: AnyHashable?

        private var viewStates: [AnyHashable: EditorViewState] {
            get { MainActor.assumeIsolated { parent.controller.viewStates } }
            set { MainActor.assumeIsolated { parent.controller.viewStates = newValue } }
        }

        func saveViewState(of tv: TypeTextView) {
            guard let id = documentID, let clip = tv.enclosingScrollView?.contentView else { return }
            viewStates[id] = EditorViewState(selection: tv.selectedRange(), scrollY: clip.bounds.origin.y)
        }

        /// Restores the caret and scroll position saved for `id`; false if none was saved.
        @discardableResult
        func restoreViewState(for id: AnyHashable, in tv: TypeTextView) -> Bool {
            guard let saved = viewStates[id], let scroll = tv.enclosingScrollView else { return false }
            let clip = scroll.contentView
            let len = (tv.string as NSString).length
            let loc = min(saved.selection.location, len)
            tv.setSelectedRange(NSRange(location: loc, length: min(saved.selection.length, len - loc)))
            tv.layoutManager?.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(len, loc + 1)))
            let top = -scroll.contentInsets.top
            clip.scroll(to: NSPoint(x: 0, y: max(top, min(saved.scrollY, tv.frame.height - clip.bounds.height))))
            scroll.reflectScrolledClipView(clip)
            return true
        }

        /// Shows another document in the same text view, remembering where the
        /// caret and scroll position were in the previous one.
        func switchDocument(to id: AnyHashable?, text: String, baseURL: URL?, in tv: TypeTextView) {
            guard let scroll = tv.enclosingScrollView else { return }
            saveViewState(of: tv)
            documentID = id
            tv.breakUndoCoalescing()
            MainActor.assumeIsolated { parent.controller.cancelSlash() }
            tv.documentBaseURL = baseURL
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            load(text, into: tv)
            if id == nil || !restoreViewState(for: id!, in: tv) {
                placeCaretForNewDocument(tv)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: -scroll.contentInsets.top))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            tv.window?.invalidateCursorRects(for: tv)
        }

        /// A fresh page starts with an empty "# " title line: put the caret on it.
        func placeCaretForNewDocument(_ tv: TypeTextView) {
            let ns = tv.string as NSString
            let first = ns.lineRange(for: NSRange(location: 0, length: 0))
            let line = ns.substring(with: first).trimmingCharacters(in: .newlines)
            if line.trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == "#" }), !line.isEmpty {
                tv.setSelectedRange(NSRange(location: (line as NSString).length, length: 0))
            }
        }

        func load(_ text: String, into tv: TypeTextView) {
            let selection = tv.selectedRange()
            tv.resetTypingEffects()
            tv.string = text
            restyle(tv, range: nil)
            tv.typingAttributes = styler.baseAttributes
            let len = (text as NSString).length
            tv.setSelectedRange(NSRange(location: min(selection.location, len), length: 0))
            Task { @MainActor in self.parent.controller.scheduleAnalysis(text) }
        }

        func restyle(_ tv: TypeTextView, range: NSRange?) {
            guard let storage = tv.textStorage else { return }
            let newBlocks = MarkdownStyler.scanBlocks(storage.string as NSString)
            var target = range
            if let r = range, newBlocks.code.count != blocks.code.count || newBlocks.comments.count != blocks.comments.count
                || newBlocks.intersects(r) || blocks.intersects(r) {
                target = nil
            }
            blocks = newBlocks
            styler.columnWidth = tv.columnWidth
            styler.style(storage, range: target, blocks: newBlocks)
            if tv.hasMarkedText() {
                // Keep the input method's underline on text still being composed.
                let marked = tv.markedRange()
                if NSMaxRange(marked) <= storage.length { storage.addAttributes(tv.markedTextAttributes ?? [:], range: marked) }
            }
            tv.scheduleCaretUpdate(animated: false)
            hasImages = (storage.string as NSString).range(of: "![").location != NSNotFound
            tv.refreshFocusDimming(force: true)
            tv.scheduleImageLayout()
            tv.needsDisplay = true
            tv.window?.invalidateCursorRects(for: tv)
        }

        // MARK: NSTextStorageDelegate

        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            pendingEdit = pendingEdit.map { NSUnionRange($0, editedRange) } ?? editedRange
        }

        // MARK: NSTextViewDelegate

        func undoManager(for view: NSTextView) -> UndoManager? {
            parent.undoManager
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? TypeTextView else { return }
            let edit = pendingEdit
            pendingEdit = nil
            if let edit {
                let len = (tv.string as NSString).length
                let clamped = NSRange(location: min(edit.location, len), length: min(edit.length, len - min(edit.location, len)))
                restyle(tv, range: clamped)
            }
            isEditing = true
            parent.text = tv.string
            isEditing = false
            let text = tv.string
            Task { @MainActor in
                self.parent.controller.scheduleAnalysis(text)
                self.parent.controller.updateSlash()
            }
            tv.centerCaretIfNeeded()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? TypeTextView else { return }
            tv.refreshFocusDimming()
            Task { @MainActor in
                let c = self.parent.controller
                if let slash = c.slash {
                    if slash.format != nil { c.updateSlash() } // closes the Format menu once the selection differs
                    else if tv.selectedRange().location <= slash.anchor { c.cancelSlash() }
                }
                c.updateCurrentHeading()
            }
            if NSApp.currentEvent?.type == .keyDown { tv.centerCaretIfNeeded() }
        }

        func textView(_ textView: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            let c = parent.controller
            let format = NSMenu(title: "Format")
            func add(_ title: String, _ action: @escaping () -> Void) {
                let item = ClosureMenuItem(title: title, action: action)
                format.addItem(item)
            }
            add("Bold") { c.bold() }
            add("Italic") { c.italic() }
            add("Strikethrough") { c.strikethrough() }
            add("Highlight") { c.highlight() }
            add("Inline Code") { c.inlineCode() }
            add("Link") { c.link() }
            add("Comment") { c.comment() }
            let item = NSMenuItem(title: "Markdown", action: nil, keyEquivalent: "")
            item.submenu = format
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
            if let tv = textView as? TypeTextView, tv.tableContext(at: charIndex) != nil {
                let table = NSMenu(title: "Table")
                let edits: [(String, TypeTextView.TableEdit)] = [
                    ("Insert Row Above", .rowAbove), ("Insert Row Below", .rowBelow),
                    ("Insert Column Left", .columnLeft), ("Insert Column Right", .columnRight),
                    ("Delete Row", .deleteRow), ("Delete Column", .deleteColumn), ("Delete Table", .deleteTable),
                ]
                for (n, (title, edit)) in edits.enumerated() {
                    if n == 4 || n == 6 { table.addItem(.separator()) }
                    table.addItem(ClosureMenuItem(title: title) { [weak tv] in tv?.editTable(edit, at: charIndex) })
                }
                let tableItem = NSMenuItem(title: "Table", action: nil, keyEquivalent: "")
                tableItem.submenu = table
                menu.insertItem(tableItem, at: 1)
            }
            return menu
        }

        // MARK: TypeTextViewEvents

        // Events arrive on the main thread in order, so handle them synchronously.
        func textViewDidType(_ textView: TypeTextView) {
            MainActor.assumeIsolated { parent.controller.userTyped() }
        }

        func textViewMouseMoved(_ textView: TypeTextView) {
            MainActor.assumeIsolated { parent.controller.mouseMoved() }
        }

        func textView(_ textView: TypeTextView, didBeginSlashAt location: Int) {
            MainActor.assumeIsolated { parent.controller.beginSlash(at: location) }
        }

        func textView(_ textView: TypeTextView, handleSlashCommand selector: Selector) -> Bool {
            MainActor.assumeIsolated { parent.controller.handleSlashKey(selector) }
        }

        func textView(_ textView: TypeTextView, handleTypedText typed: String) -> Bool {
            MainActor.assumeIsolated { parent.controller.handleTypedText(typed) }
        }

        func textViewWillMouseDown(_ textView: TypeTextView) {
            MainActor.assumeIsolated { if parent.controller.slash?.format != nil { parent.controller.cancelSlash() } }
        }
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}
