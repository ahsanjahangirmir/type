import AppKit
import SwiftUI

/// The Format menu: `/` typed over a selection offers formatting for that text
/// (the empty-line `/` offers blocks to insert). It reuses the slash menu's state and view.
extension EditorController {
    static let formatCommands: [SlashCommand] = [
        SlashCommand(id: "text", title: "Text", subtitle: "Plain paragraph", symbol: "textformat", keywords: ["plain", "paragraph", "clear", "normal"]) { c, _ in c.plainText() },
        SlashCommand(id: "bold", title: "Bold", subtitle: "Strong emphasis", symbol: "bold", keywords: ["strong", "b"], shortcut: "⌘B", format: .bold) { c, _ in c.bold() },
        SlashCommand(id: "italic", title: "Italic", subtitle: "Emphasis", symbol: "italic", keywords: ["emphasis", "i"], shortcut: "⌘I", format: .italic) { c, _ in c.italic() },
        SlashCommand(id: "strike", title: "Strikethrough", subtitle: "Cross out", symbol: "strikethrough", keywords: ["strike", "delete"], format: .strike) { c, _ in c.strikethrough() },
        SlashCommand(id: "highlight", title: "Highlight", subtitle: "Mark the text", symbol: "highlighter", keywords: ["mark"], format: .highlight) { c, _ in c.highlight() },
        SlashCommand(id: "code", title: "Inline Code", subtitle: "Monospaced", symbol: "chevron.left.forwardslash.chevron.right", keywords: ["code", "mono"], format: .code) { c, _ in c.inlineCode() },
        SlashCommand(id: "link", title: "Link…", subtitle: "Add or edit a link", symbol: "link", keywords: ["url", "href"], shortcut: "⌘K") { c, _ in c.link() },
        SlashCommand(id: "h1", title: "Heading 1", subtitle: "Large section title", symbol: "textformat.size.larger", keywords: ["title", "h1"]) { c, _ in c.heading(1) },
        SlashCommand(id: "h2", title: "Heading 2", subtitle: "Medium section title", symbol: "textformat.size", keywords: ["subtitle", "h2"]) { c, _ in c.heading(2) },
        SlashCommand(id: "h3", title: "Heading 3", subtitle: "Small section title", symbol: "textformat.size.smaller", keywords: ["h3"]) { c, _ in c.heading(3) },
        SlashCommand(id: "quote", title: "Quote", subtitle: "Call out a passage", symbol: "text.quote", keywords: ["blockquote", "cite"]) { c, _ in c.quote() },
        SlashCommand(id: "ul", title: "Bulleted List", subtitle: "Simple bullet points", symbol: "list.bullet", keywords: ["bullet", "unordered", "ul"]) { c, _ in c.bulletList() },
        SlashCommand(id: "ol", title: "Numbered List", subtitle: "Ordered steps", symbol: "list.number", keywords: ["ordered", "ol", "number"]) { c, _ in c.numberedList() },
        SlashCommand(id: "todo", title: "Checklist", subtitle: "Track tasks", symbol: "checklist", keywords: ["task", "todo", "check"]) { c, _ in c.taskList() },
    ]

    /// Removes block prefixes and inline formatting from the selected lines.
    func plainText() { textView?.clearFormatting() }

    /// True when the whole selection already has `command`'s inline format.
    func isActive(_ command: SlashCommand) -> Bool {
        guard let format = command.format, let state = slash, state.format != nil else { return false }
        return state.active.contains(format)
    }

    /// Opens the Format menu for the selection. Returns true when the typed "/" is
    /// consumed: always, even when the selection can't be formatted (code, images,
    /// dividers, table rules), where it beeps rather than replacing the text.
    func beginFormatMenu() -> Bool {
        guard let tv = textView, let scroll = tv.enclosingScrollView else { return false }
        let selection = tv.selectedRange()
        guard selection.length > 0 else { return false }
        guard tv.canFormatSelection else { NSSound.beep(); return true }
        var state = SlashState(anchor: selection.location)
        state.format = selection
        state.active = Set(InlineFormat.allCases.filter { tv.formatCoverage($0).all })
        let ns = tv.string as NSString
        var end = NSMaxRange(selection)
        if ns.character(at: end - 1) == 10, end - 1 > selection.location { end -= 1 }
        state.rect = rectInEditor(tv.caretRect(at: end - 1), tv: tv, scroll: scroll)
        state.aboveRect = rectInEditor(tv.firstLineRect(for: selection), tv: tv, scroll: scroll)
        withAnimation(.snappy(duration: 0.2)) { slash = state }
        watchScrolling(of: scroll.contentView)
        return true
    }

    private func watchScrolling(of clip: NSClipView) {
        if let old = formatScrollObserver { NotificationCenter.default.removeObserver(old) }
        let origin = clip.bounds.origin.y
        formatScrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self, weak clip] _ in
            MainActor.assumeIsolated {
                guard let self, let clip else { return }
                guard self.slash?.format != nil else {
                    if let token = self.formatScrollObserver { NotificationCenter.default.removeObserver(token) }
                    self.formatScrollObserver = nil
                    return
                }
                if abs(clip.bounds.origin.y - origin) > 120 { self.cancelSlash() }
            }
        }
    }

    /// Typed text while the Format menu is open filters its list instead of
    /// entering the document; "/" over a selection opens the menu.
    func handleTypedText(_ typed: String) -> Bool {
        guard var state = slash, state.format != nil else {
            return typed == "/" && beginFormatMenu()
        }
        guard typed.count == 1, typed.first?.isNewline == false else { cancelSlash(); return false }
        if (typed.first?.isWhitespace == true && state.query.isEmpty) || state.query.count >= 20 { return true }
        state.query += typed
        state.selection = 0
        slash = state
        return true
    }

    /// Backspace edits the filter and closes the menu (keeping the selection) when it is empty.
    func backspaceInFormatMenu() -> Bool {
        guard var state = slash, state.format != nil else { return false }
        if state.query.isEmpty { cancelSlash() } else { state.query.removeLast(); state.selection = 0; slash = state }
        return true
    }
}
