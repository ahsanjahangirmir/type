import AppKit

extension TypeTextView {
    /// Replaces `range` through the text view, as a normal user edit: it is
    /// undoable and the owner is told via the usual change notifications.
    @discardableResult
    func replaceUndoably(_ range: NSRange, with string: String) -> Bool {
        guard NSMaxRange(range) <= (self.string as NSString).length, shouldChangeText(in: range, replacementString: string) else { return false }
        replaceCharacters(in: range, with: string)
        didChangeText()
        return true
    }
}
