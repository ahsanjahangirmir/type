import SwiftUI

/// Per-file writing goals, persisted by path.
enum GoalStore {
    static let key = "writingGoals"
    /// Where goals are kept (replaced in tests).
    nonisolated(unsafe) static var defaults = UserDefaults.standard
    static func goal(for url: URL?) -> Int {
        guard let url else { return 0 }
        return (defaults.dictionary(forKey: key)?[url.standardizedFileURL.path] as? Int) ?? 0
    }
    static func set(_ goal: Int, for url: URL?) {
        guard let url else { return }
        var all = defaults.dictionary(forKey: key) ?? [:]
        all[url.standardizedFileURL.path] = goal > 0 ? goal : nil
        defaults.set(all, forKey: key)
    }
}

/// The complete writing surface: editor, slash menu, stats pill, goal toast,
/// glass toolbar and outline inspector. Shared by library pages and standalone documents.
struct EditorPane: View {
    @Binding var text: String
    @ObservedObject var controller: EditorController
    let fileURL: URL?
    var undoManager: UndoManager? = nil
    /// Identifies the document shown; when it changes the editor swaps its text in place.
    var documentID: AnyHashable? = nil
    var inLibrary = false
    @Binding var showOutline: Bool

    @EnvironmentObject private var settings: AppSettings
    @State private var goal = 0
    @State private var celebration = GoalCelebration()
    @State private var showGoalToast = false
    @State private var toastHide: Task<Void, Never>?
    @State private var editorSize: CGSize = .zero

    private var chromeShown: Bool { controller.chromeVisible || !settings.autoHideChrome }

    var body: some View {
        EditorTextView(text: $text, config: settings.editorConfig, controller: controller,
                       baseURL: fileURL?.deletingLastPathComponent(), undoManager: undoManager, documentID: documentID)
            .ignoresSafeArea(.container, edges: .top)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { editorSize = $0 }
            .overlay(alignment: .topLeading) { slashOverlay }
            .overlay(alignment: .bottom) {
                VStack(spacing: 10) {
                    if showGoalToast { GoalToast(goal: goal).transition(Motion.transition(.move(edge: .bottom).combined(with: .opacity))) }
                    if settings.showStats {
                        StatusPill(controller: controller, goal: $goal)
                            .opacity(chromeShown ? 1 : 0.55)
                    }
                }
                .padding(.bottom, 18)
            }
            .background(settings.theme.color.ignoresSafeArea())
            .toolbar { EditorToolbar(controller: controller, showOutline: $showOutline) }
            .toolbarVisibility(chromeShown ? .visible : .hidden, for: .windowToolbar)
            .onContinuousHover { phase in
                if case .active = phase { controller.mouseMoved() }
            }
            .animation(Motion.animation(.smooth(duration: 0.3)), value: chromeShown)
            .inspector(isPresented: $showOutline) {
                OutlineSidebar(controller: controller)
                    .inspectorColumnWidth(min: 200, ideal: 240, max: 360)
            }
            .onAppear {
                controller.fileURL = fileURL
                controller.inLibrary = inLibrary
                goal = GoalStore.goal(for: fileURL)
            }
            .onChange(of: fileURL) { _, url in
                controller.fileURL = url
                goal = GoalStore.goal(for: url)
                // `controller.stats` still describes the previous page here, so count this page's text.
                celebration.reset(goal: goal, words: goal > 0 ? DocumentAnalysis.analyze(text).0.words : 0)
                toastHide?.cancel()
                showGoalToast = false
            }
            .onChange(of: controller.stats.words) { _, words in checkGoal(words) }
            .onChange(of: goal) { _, newGoal in
                GoalStore.set(newGoal, for: fileURL)
                celebration.reset(goal: newGoal, words: newGoal > 0 ? DocumentAnalysis.analyze(text).0.words : 0)
            }
    }

    /// The slash and Format menus open below the caret (or the selection's last line), or above it when there isn't room
    /// (near the bottom of the window, above the statistics pill).
    @ViewBuilder
    private var slashOverlay: some View {
        if let slash = controller.slash {
            let height = SlashMenu.height(for: controller.filteredSlashCommands.count)
            let bottomLimit = editorSize.height - (settings.showStats ? 64 : 16)
            let below = editorSize.height == 0 || slash.rect.maxY + 8 + height <= bottomLimit || (slash.aboveRect ?? slash.rect).minY - 8 - height < 8
            let x = min(max(12, slash.rect.minX - 10), max(12, editorSize.width - SlashMenu.width - 12))
            let y = below ? slash.rect.maxY + 8 : (slash.aboveRect ?? slash.rect).minY - 8 - height
            SlashMenu(controller: controller, state: slash)
                .offset(x: x, y: max(8, y))
                .transition(Motion.transition(.scale(scale: 0.92, anchor: below ? .topLeading : .bottomLeading).combined(with: .opacity)))
        }
    }

    private func checkGoal(_ words: Int) {
        guard celebration.update(goal: goal, words: words) else { return }
        withAnimation(.bouncy) { showGoalToast = true }
        toastHide?.cancel()
        toastHide = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) { showGoalToast = false }
        }
    }
}

// MARK: - Toolbar

struct EditorToolbar: ToolbarContent {
    @ObservedObject var controller: EditorController
    @Binding var showOutline: Bool
    @EnvironmentObject private var settings: AppSettings

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            Menu {
                Button("Heading 1") { controller.heading(1) }
                Button("Heading 2") { controller.heading(2) }
                Button("Heading 3") { controller.heading(3) }
                Divider()
                Button("Body Text") { controller.heading(0) }
            } label: {
                Label("Heading", systemImage: "textformat.size")
            }
            .help("Heading")

            Button { controller.bold() } label: { Label("Bold", systemImage: "bold") }.help("Bold (⌘B)")
            Button { controller.italic() } label: { Label("Italic", systemImage: "italic") }.help("Italic (⌘I)")
            Button { controller.strikethrough() } label: { Label("Strikethrough", systemImage: "strikethrough") }.help("Strikethrough")
            Button { controller.highlight() } label: { Label("Highlight", systemImage: "highlighter") }.help("Highlight")
            Button { controller.link() } label: { Label("Link", systemImage: "link") }.help("Link (⌘K)")
        }

        ToolbarSpacer(.fixed, placement: .principal)

        ToolbarItemGroup(placement: .principal) {
            Button { controller.bulletList() } label: { Label("Bulleted List", systemImage: "list.bullet") }.help("Bulleted List")
            Button { controller.numberedList() } label: { Label("Numbered List", systemImage: "list.number") }.help("Numbered List")
            Button { controller.taskList() } label: { Label("Checklist", systemImage: "checklist") }.help("Checklist")
            Button { controller.quote() } label: { Label("Quote", systemImage: "text.quote") }.help("Quote")
            Menu {
                Button("Image…", systemImage: "photo") { controller.insertImage() }
                Button("Table", systemImage: "tablecells") { controller.table() }
                Button("Code Block", systemImage: "chevron.left.forwardslash.chevron.right") { controller.codeBlock() }
                Button("Comment", systemImage: "text.bubble") { controller.comment() }
                Button("Divider", systemImage: "minus") { controller.divider() }
                Button("Today’s Date", systemImage: "calendar") { controller.insertDate() }
            } label: {
                Label("Insert", systemImage: "plus")
            }
            .help("Insert")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $settings.focusMode) { Label("Focus", systemImage: "scope") }
                .help("Focus Mode (⇧⌘F)")
            Toggle(isOn: $settings.typewriterScrolling) { Label("Typewriter", systemImage: "character.cursor.ibeam") }
                .help("Typewriter Scrolling (⌃⌘T)")
            Menu {
                Toggle("Typing Sounds", isOn: $settings.typingSounds)
                Divider()
                Picker("Sound", selection: $settings.soundProfile) {
                    ForEach(SoundProfile.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sounds", systemImage: settings.typingSounds ? "speaker.wave.2.fill" : "speaker.slash")
            } primaryAction: {
                settings.typingSounds.toggle()
            }
            .help("Typing Sounds (⌥⌘S) — hold for sound choices")
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            Menu {
                ForEach(ExportFormat.allCases) { format in
                    Button(format.label, systemImage: format.symbol) {
                        controller.export(format, fontChoice: settings.fontChoice, customFamily: settings.customFontFamily)
                    }
                }
                Divider()
                Button("Print…", systemImage: "printer") {
                    controller.printDocument(fontChoice: settings.fontChoice, customFamily: settings.customFontFamily)
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export")
        }

        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $showOutline) { Label("Outline", systemImage: "sidebar.right") }
                .help("Show Outline (⌥⌘O)")
        }
    }
}
