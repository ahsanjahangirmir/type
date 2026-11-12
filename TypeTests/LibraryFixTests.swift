import XCTest
import SwiftUI
@testable import TypeApp

/// Hosts a library page's editor the way `LibraryPageEditor` does.
private struct PageHost: View {
    @ObservedObject var page: PageModel
    let controller: EditorController
    var body: some View {
        EditorTextView(text: $page.text, config: {
            var c = AppSettings.shared.editorConfig
            c.smoothTyping = false; c.typingSounds = false
            return c
        }(), controller: controller, baseURL: nil, undoManager: page.undoManager, documentID: ObjectIdentifier(page))
    }
}

@MainActor
final class LibraryFixTests: XCTestCase {
    private var dirs: [URL] = []

    override func tearDown() {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
        GoalStore.defaults = .standard
        Motion.overrideReduced = nil
    }

    private func tmp() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("libfix-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        dirs.append(u)
        return u
    }

    /// A store whose "Trash" just deletes, so tests never touch the real one.
    private func makeStore(_ root: URL, watch: Bool = false) -> LibraryStore {
        let store = LibraryStore(rootURL: root, watch: watch)
        store.trash = { try FileManager.default.removeItem(at: $0) }
        return store
    }

    private func spin(_ seconds: TimeInterval = 0.2) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    // MARK: 1, 5 – renaming the open page

    func testSidebarRenameOfOpenPageDropsStaleUndo() {
        let dir = tmp()
        let url = dir.appendingPathComponent("a.md")
        try! "# Title\n\nHello world\n".write(to: url, atomically: true, encoding: .utf8)
        let page = PageModel(url: url)
        let controller = EditorController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PageHost(page: page, controller: controller))
        window.layoutIfNeeded(); spin()
        let tv = controller.textView!
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        for ch in "XYZ" { tv.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        XCTAssertTrue(page.undoManager.canUndo)
        page.setHeading("A much longer new title here")
        spin()
        XCTAssertEqual(tv.string, page.text)
        XCTAssertFalse(page.undoManager.canUndo, "undo steps from before the text was replaced must be dropped")
        page.undoManager.undo()
        spin()
        XCTAssertEqual(tv.string, "# A much longer new title here\n\nHello world\nXYZ")
        window.close()
    }

    func testRenameThroughTextViewIsUndoable() {
        let e = LiveEditor("# Title\n\nHello\n")
        defer { e.close() }
        let ns = e.text as NSString
        XCTAssertTrue(e.tv.replaceUndoably(NSRange(location: 0, length: ns.range(of: "Title").upperBound), with: "# A much longer title"))
        XCTAssertEqual(e.text, "# A much longer title\n\nHello\n")
        e.tv.undoManager?.undo()
        XCTAssertEqual(e.text, "# Title\n\nHello\n")
    }

    func testCommittingUnchangedNameLeavesHeadinglessPageAlone() {
        let dir = tmp()
        let url = dir.appendingPathComponent("notes.txt")
        try! "plain body\n".write(to: url, atomically: true, encoding: .utf8)
        let page = PageModel(url: url)
        XCTAssertNil(page.headingEdit(for: page.title))
        page.setHeading(page.title)
        XCTAssertEqual(page.text, "plain body\n")
        XCTAssertFalse(page.isDirty)
    }

    func testNewHeadingGoesBelowFrontMatter() {
        let dir = tmp()
        let url = dir.appendingPathComponent("fm.md")
        try! "---\ntitle: x\n---\nBody\n".write(to: url, atomically: true, encoding: .utf8)
        let page = PageModel(url: url)
        page.setHeading("Named")
        XCTAssertEqual(page.text, "---\ntitle: x\n---\n# Named\n\nBody\n")
    }

    // MARK: 2, 3 – deleting

    func testDeletedPageModelIsNotReusedForNewPageWithSameName() throws {
        let store = makeStore(tmp())
        let nb = try store.createNotebook(named: "NB")
        let url = try store.createPage(in: nb)
        let model = store.page(for: url)
        try store.deletePage(url)
        XCTAssertTrue(model.isDeleted)
        let again = try store.createPage(in: nb)
        XCTAssertEqual(again, url)
        let fresh = store.page(for: again)
        XCTAssertFalse(fresh.isDeleted)
        XCTAssertTrue(fresh !== model)
        fresh.text = "# Again"
        fresh.saveNow()
        XCTAssertEqual(try String(contentsOf: again, encoding: .utf8), "# Again")
    }

    func testDeletedNotebookForgetsItsPages() throws {
        let store = makeStore(tmp())
        let nb = try store.createNotebook(named: "NB")
        let url = try store.createPage(in: nb)
        let model = store.page(for: url)
        try store.deleteNotebook(nb)
        XCTAssertTrue(model.isDeleted)
        let nb2 = try store.createNotebook(named: "NB")
        let url2 = try store.createPage(in: nb2)
        XCTAssertEqual(url2, url)
        XCTAssertFalse(store.page(for: url2).isDeleted)
    }

    func testFailedTrashKeepsPageEditable() throws {
        struct Boom: Error {}
        let store = makeStore(tmp())
        let nb = try store.createNotebook(named: "NB")
        let url = try store.createPage(in: nb)
        let model = store.page(for: url)
        store.trash = { _ in throw Boom() }
        XCTAssertThrowsError(try store.deletePage(url))
        XCTAssertFalse(model.isDeleted)
        model.text = "# Still here"
        XCTAssertTrue(model.saveNow())
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Still here")
        XCTAssertThrowsError(try store.deleteNotebook(nb))
        XCTAssertFalse(model.isDeleted)
    }

    // MARK: 4 – outside edits

    func testOutsideEditToDirtyPageIsKeptAsConflictCopy() throws {
        let dir = tmp()
        let url = dir.appendingPathComponent("a.md")
        try "one\n".write(to: url, atomically: true, encoding: .utf8)
        let page = PageModel(url: url)
        page.text = "one mine\n"
        try "one theirs\n".write(to: url, atomically: true, encoding: .utf8)
        page.reloadIfChangedOnDisk()
        XCTAssertTrue(page.saveNow())
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one mine\n")
        let copy = try XCTUnwrap(page.conflict?.copy)
        XCTAssertEqual(copy.deletingLastPathComponent().standardizedFileURL, dir.standardizedFileURL)
        XCTAssertTrue(copy.lastPathComponent.hasPrefix("a (conflict "), copy.lastPathComponent)
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "one theirs\n")
        // The next save is ours again: no second copy.
        page.text = "one mine, more\n"
        page.saveNow()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 2)
    }

    func testPlainSavesMakeNoConflictCopy() throws {
        let dir = tmp()
        let url = dir.appendingPathComponent("a.md")
        try "one\n".write(to: url, atomically: true, encoding: .utf8)
        let page = PageModel(url: url)
        page.text = "two\n"; page.saveNow()
        page.text = "three\n"; page.saveNow()
        XCTAssertNil(page.conflict)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["a.md"])
    }

    func testTouchedButIdenticalFileIsNotAConflict() throws {
        let dir = tmp()
        let url = dir.appendingPathComponent("a.md")
        try "one\n".write(to: url, atomically: true, encoding: .utf8)
        let page = PageModel(url: url)
        page.text = "mine\n"
        try "one\n".write(to: url, atomically: true, encoding: .utf8) // new mtime, same content
        page.saveNow()
        XCTAssertNil(page.conflict)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["a.md"])
    }

    // MARK: 6 – assets

    func testMovedPageKeepsItsOwnImageWhenNameCollides() throws {
        let store = makeStore(tmp())
        let a = try store.createNotebook(named: "A"), b = try store.createNotebook(named: "B")
        let fm = FileManager.default
        for nb in [a, b] { try fm.createDirectory(at: nb.appendingPathComponent(".assets"), withIntermediateDirectories: true) }
        try Data("AAA".utf8).write(to: a.appendingPathComponent(".assets/image.png"))
        try Data("BBB".utf8).write(to: b.appendingPathComponent(".assets/image.png"))
        try Data("SAME".utf8).write(to: a.appendingPathComponent(".assets/same.png"))
        try Data("SAME".utf8).write(to: b.appendingPathComponent(".assets/same.png"))
        let p = try store.createPage(in: a, title: "P", text: "# P\n\n![image](.assets/image.png)\n\n![again](.assets/image.png)\n\n![s](.assets/same.png)\n")
        let moved = try store.movePage(p, to: b)
        let content = try String(contentsOf: moved, encoding: .utf8)
        XCTAssertEqual(content, "# P\n\n![image](.assets/image 2.png)\n\n![again](.assets/image 2.png)\n\n![s](.assets/same.png)\n".replacingOccurrences(of: " 2", with: "%202"))
        XCTAssertEqual(try String(contentsOf: b.appendingPathComponent(".assets/image.png"), encoding: .utf8), "BBB")
        XCTAssertEqual(try String(contentsOf: b.appendingPathComponent(".assets/image 2.png"), encoding: .utf8), "AAA")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: b.appendingPathComponent(".assets").path).count, 3)
    }

    func testMovedOpenPageReloadsRewrittenReferences() throws {
        let store = makeStore(tmp())
        let a = try store.createNotebook(named: "A"), b = try store.createNotebook(named: "B")
        let fm = FileManager.default
        for (nb, data) in [(a, "AAA"), (b, "BBB")] {
            try fm.createDirectory(at: nb.appendingPathComponent(".assets"), withIntermediateDirectories: true)
            try Data(data.utf8).write(to: nb.appendingPathComponent(".assets/i.png"))
        }
        let p = try store.createPage(in: a, title: "P", text: "# P\n![i](.assets/i.png)\n")
        let model = store.page(for: p)
        let moved = try store.movePage(p, to: b)
        XCTAssertEqual(model.url, moved)
        XCTAssertTrue(model.text.contains(".assets/i%202.png"), model.text)
    }

    // MARK: 7, 18 – image block view

    func testImageViewDropsPreviousImageWhenMissing() {
        let v = ImageBlockView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let spec = ImageSpec(alt: "", path: ".assets/my%20shot.png", width: nil, displaySize: CGSize(width: 10, height: 10))
        v.configure(image: NSImage(size: NSSize(width: 10, height: 10)), spec: spec, range: NSRange(location: 0, length: 5))
        XCTAssertNotNil(v.layer!.sublayers!.first!.contents)
        v.configure(image: nil, spec: spec, range: NSRange(location: 0, length: 5))
        XCTAssertNil(v.layer!.sublayers!.first!.contents, "missing image must not show a previous image")
        let names = allTextFields(in: v).map(\.stringValue)
        XCTAssertTrue(names.contains("my shot.png"), "\(names)")
    }

    func testImageViewIsAnAccessibleImage() {
        let v = ImageBlockView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let spec = ImageSpec(alt: "A red door", path: ".assets/door.png", width: nil, displaySize: CGSize(width: 10, height: 10))
        v.configure(image: NSImage(size: NSSize(width: 10, height: 10)), spec: spec, range: NSRange(location: 0, length: 5))
        XCTAssertEqual(v.accessibilityRole(), .image)
        XCTAssertEqual(v.accessibilityLabel(), "A red door")
        let auto = ImageSpec(alt: "", path: ".assets/door.png", width: nil, displaySize: CGSize(width: 10, height: 10))
        v.configure(image: NSImage(size: NSSize(width: 10, height: 10)), spec: auto, range: NSRange(location: 0, length: 5))
        XCTAssertEqual(v.accessibilityLabel(), "door.png")
    }

    private func allTextFields(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? [] + allTextFields(in: $0) }
    }

    // MARK: 8 – goals follow renames

    func testGoalsFollowRenamedAndMovedPages() throws {
        GoalStore.defaults = UserDefaults(suiteName: "libfix-\(UUID().uuidString)")!
        let store = makeStore(tmp())
        let a = try store.createNotebook(named: "A"), b = try store.createNotebook(named: "B")
        let p = try store.createPage(in: a, title: "P")
        GoalStore.set(500, for: p)
        let renamed = try store.renamePage(p, to: "Q")
        XCTAssertEqual(GoalStore.goal(for: renamed), 500)
        XCTAssertEqual(GoalStore.goal(for: p), 0)
        let moved = try store.movePage(renamed, to: b)
        XCTAssertEqual(GoalStore.goal(for: moved), 500)
        let nb = try store.renameNotebook(b, to: "B2")
        XCTAssertEqual(GoalStore.goal(for: nb.appendingPathComponent(moved.lastPathComponent)), 500)
        XCTAssertEqual(GoalStore.goal(for: moved), 0)
    }

    // MARK: 9 – goal toast

    func testNoCelebrationForPageAlreadyOverGoal() {
        var c = GoalCelebration()
        c.reset(goal: 100, words: 250)
        XCTAssertFalse(c.update(goal: 100, words: 251))
        XCTAssertFalse(c.update(goal: 100, words: 260))
        XCTAssertFalse(c.update(goal: 100, words: 90))
        XCTAssertTrue(c.update(goal: 100, words: 100), "crossing the goal after dipping below celebrates again")
        XCTAssertFalse(c.update(goal: 100, words: 101))
    }

    func testCelebrationWhenCrossingGoal() {
        var c = GoalCelebration()
        c.reset(goal: 100, words: 40)
        XCTAssertFalse(c.update(goal: 100, words: 99))
        XCTAssertTrue(c.update(goal: 100, words: 100))
        c.reset(goal: 0, words: 0)
        XCTAssertFalse(c.update(goal: 0, words: 10))
    }

    // MARK: 11 – outline

    func testRevealWithStaleOutlineClamps() {
        let e = LiveEditor("# Short\n")
        defer { e.close() }
        e.controller.reveal(OutlineItem(id: 9_999, level: 2, title: "Gone"))
        XCTAssertEqual(e.tv.selectedRange(), NSRange(location: (e.text as NSString).length, length: 0))
    }

    // MARK: 12 – typewriter insets

    func testTypewriterInsetsFollowWindowHeight() {
        let controller = EditorController()
        var config = AppSettings.shared.editorConfig
        config.typewriterScrolling = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorTextView(text: .constant("hello\n"), config: config, controller: controller, baseURL: nil))
        window.layoutIfNeeded(); spin()
        defer { window.close() }
        let tv = controller.textView!
        let before = tv.textContainerInset.height
        window.setContentSize(NSSize(width: 800, height: 400))
        window.layoutIfNeeded(); spin()
        XCTAssertNotEqual(tv.textContainerInset.height, before, "inset should follow window height (before \(before))")
    }

    // MARK: 14 – statistics

    func testImagesAreNotWords() {
        let (stats, _) = DocumentAnalysis.analyze("![Screenshot-20261112-103122](.assets/Screenshot-20261112-103122.png =300x)\n\nHello ![alt words](a.png) world\n")
        XCTAssertEqual(stats.words, 2)
        XCTAssertEqual(stats.paragraphs, 1)
    }

    func testStatusPillSingularAndPlural() {
        func summary(words: Int, chars: Int) -> String {
            DocumentStats(words: words, characters: chars, charactersNoSpaces: chars, paragraphs: 1)
                .summary(goal: 0, showCharacters: true, countSpaces: true, showReadingTime: false, wordsPerMinute: 230)
        }
        XCTAssertEqual(summary(words: 1, chars: 1), "1 word  ·  1 character")
        XCTAssertEqual(summary(words: 0, chars: 0), "0 words  ·  0 characters")
        XCTAssertEqual(summary(words: 1_234, chars: 5_000), "1,234 words  ·  5,000 characters")
        XCTAssertEqual(DocumentStats.count(1, "word"), "1 word")
    }

    // MARK: 15 – watching

    func testOwnAutosavesDoNotRescanTheLibrary() throws {
        let root = tmp()
        let store = makeStore(root, watch: true)
        let nb = try store.createNotebook(named: "NB")
        let url = try store.createPage(in: nb, title: "P", text: "# P\n")
        let page = store.page(for: url)
        spin(1.5)
        let before = store.scanCount
        for i in 0..<3 {
            page.text = "# P\n\nedit \(i)"
            page.saveNow()
            spin(0.1)
        }
        spin(1.5)
        XCTAssertEqual(store.scanCount, before, "our own saves must not trigger a rescan")

        try "# Other\n".write(to: nb.appendingPathComponent("Other.md"), atomically: true, encoding: .utf8)
        spin(2)
        XCTAssertGreaterThan(store.scanCount, before)
        XCTAssertTrue(store.pages[nb.standardizedFileURL]?.contains { $0.title == "Other" } == true)
    }

    func testOutsideEditToOpenPageStillReloads() throws {
        let root = tmp()
        let store = makeStore(root, watch: true)
        let nb = try store.createNotebook(named: "NB")
        let url = try store.createPage(in: nb, title: "P", text: "# P\n")
        let page = store.page(for: url)
        spin(1.5)
        try "# P renamed outside\n".write(to: url, atomically: true, encoding: .utf8)
        spin(2)
        XCTAssertEqual(page.text, "# P renamed outside\n")
        XCTAssertEqual(store.pages[nb.standardizedFileURL]?.first?.title, "P renamed outside")
    }

    // MARK: 16 – headings

    func testHeadingLookupNeverCutsAUTF8Sequence() throws {
        let dir = tmp()
        let url = dir.appendingPathComponent("long.md")
        // "# " + a title long enough that the 4096-byte read ends inside a 3-byte character.
        try ("# " + String(repeating: "日", count: 2000) + "\n").write(to: url, atomically: true, encoding: .utf8)
        let title = try XCTUnwrap(LibraryStore.heading(of: url))
        XCTAssertFalse(title.contains("\u{FFFD}"))
        XCTAssertTrue(title.allSatisfy { $0 == "日" })
        XCTAssertEqual(LibraryStore.validUTF8Prefix(Data([0x61, 0xE6, 0x97])), Data([0x61]))
        XCTAssertEqual(LibraryStore.validUTF8Prefix(Data([0x61, 0xE6, 0x97, 0xA5])), Data([0x61, 0xE6, 0x97, 0xA5]))
        XCTAssertEqual(LibraryStore.validUTF8Prefix(Data([0x61, 0xF0, 0x9F])), Data([0x61]))
        XCTAssertEqual(LibraryStore.validUTF8Prefix(Data("abc".utf8)), Data("abc".utf8))
    }

    func testHeadingSkipsFrontMatter() throws {
        XCTAssertEqual(LibraryStore.firstHeading(in: "---\n# not a title\ntags: x\n---\n\n# Real\n"), "Real")
        XCTAssertNil(LibraryStore.firstHeading(in: "---\n# inside\n---\nbody\n"))
        XCTAssertEqual(LibraryStore.firstHeading(in: "---\nnot closed\n# Heading\n"), "Heading")
        let dir = tmp()
        let url = dir.appendingPathComponent("fm.md")
        let front = "---\n" + String(repeating: "tag: value\n", count: 600) + "---\n# After long front matter\n"
        try front.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(LibraryStore.heading(of: url), "After long front matter")
    }

    // MARK: 18 – reduce motion

    func testReduceMotionReplacesMovementWithAFade() {
        Motion.overrideReduced = false
        XCTAssertEqual(Motion.animation(.bouncy), .bouncy)
        Motion.overrideReduced = true
        XCTAssertEqual(Motion.animation(.bouncy), .easeInOut(duration: 0.12))
    }
}
