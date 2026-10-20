import SwiftUI
import UniformTypeIdentifiers

/// Per-window selection and actions for the library (exposed to menu commands).
@MainActor
final class LibraryWindowState: ObservableObject {
    @Published var notebook: URL?
    @Published var page: URL? {
        didSet { if page != oldValue { model = page.map { library.page(for: $0) } } }
    }
    @Published var renaming: URL?
    /// The open page. Held here so the editor can be reused (not rebuilt) when switching pages.
    @Published private(set) var model: PageModel?
    /// Bumped to move keyboard focus into the editor (e.g. after creating a page).
    @Published var focusEditorRequest = 0
    /// Whether the sidebar shows (toggled with the toolbar button or View ▸ Hide Sidebar).
    @Published var columns: NavigationSplitViewVisibility = .all

    private var library: LibraryStore { .shared }

    func newNotebook() {
        do {
            let url = try library.createNotebook()
            notebook = url
            page = nil
            renaming = url
        } catch { present(error) }
    }

    func newPage() {
        if notebook == nil { notebook = library.notebooks.first?.url }
        if notebook == nil { newNotebook() }
        guard let notebook else { return }
        do {
            page = try library.createPage(in: notebook)
            focusEditorRequest += 1
        } catch { present(error) }
    }

    func rename(_ url: URL, to name: String, isNotebook: Bool) {
        renaming = nil
        do {
            if isNotebook {
                let new = try library.renameNotebook(url, to: name)
                if notebook == url { notebook = new }
                if let p = page, p.path.hasPrefix(url.path + "/") {
                    page = new.appendingPathComponent(p.lastPathComponent).standardizedFileURL
                }
            } else {
                // A page's name is its first heading; the file follows it.
                let model = library.page(for: url)
                model.setHeading(name)
                model.saveNow()
                syncFileName(url)
            }
        } catch { present(error) }
    }

    /// Renames a page's file to match its first heading (done when leaving the
    /// page, so the file never moves underneath the editor).
    func syncFileName(_ url: URL) {
        let model = library.page(for: url)
        guard !model.isDeleted, FileManager.default.fileExists(atPath: model.url.path), let heading = model.heading,
              LibraryStore.sanitize(heading, fallback: "") != model.url.deletingPathExtension().lastPathComponent else { return }
        do {
            let old = model.url
            let new = try library.renamePage(old, to: heading)
            if page == old { page = new }
        } catch { NSLog("Type: couldn't rename \(url.path): \(error)") }
    }

    func move(_ pageURL: URL, to notebookURL: URL) {
        do {
            let new = try library.movePage(pageURL, to: notebookURL)
            if page == pageURL { page = new; notebook = notebookURL }
        } catch { present(error) }
    }

    func duplicate(_ url: URL) {
        do { page = try library.duplicatePage(url) } catch { present(error) }
    }

    func deletePage(_ url: URL) {
        do {
            try library.deletePage(url)
            if page == url { page = nil }
        } catch { present(error) }
    }

    func deleteNotebook(_ url: URL) {
        do {
            try library.deleteNotebook(url)
            if notebook == url { notebook = nil; page = nil }
        } catch { present(error) }
    }

    private func present(_ error: Error) {
        NSAlert(error: error).runModal()
    }
}

struct LibraryWindow: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var library = LibraryStore.shared
    @StateObject private var state = LibraryWindowState()
    @StateObject private var controller = EditorController()
    @SceneStorage("library.notebook") private var storedNotebook = ""
    @SceneStorage("library.page") private var storedPage = ""
    @SceneStorage("library.outline") private var showOutline = false
    @SceneStorage("library.sidebarHidden") private var storedSidebarHidden = false

    var body: some View {
        NavigationSplitView(columnVisibility: $state.columns) {
            LibrarySidebar(state: state)
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 380)
        } detail: {
            detail
        }
        .navigationTitle(state.model?.title ?? state.notebook?.lastPathComponent ?? "Type")
        .navigationSubtitle(state.model != nil ? (state.notebook?.lastPathComponent ?? "") : "")
        .focusedSceneObject(state)
        .focusedSceneObject(controller)
        .preferredColorScheme(settings.appearance.colorScheme)
        .onAppear(perform: restoreSelection)
        .onChange(of: state.columns) { _, columns in storedSidebarHidden = columns == .detailOnly }
        .onChange(of: state.notebook) { old, new in
            storedNotebook = new?.path ?? ""
            // Switching notebooks opens its most recent page.
            if let p = state.page, let new, p.deletingLastPathComponent().standardizedFileURL == new.standardizedFileURL { return }
            state.page = library.pages(in: new, sort: .modified).first?.url
        }
        .onChange(of: state.page) { old, new in
            if let old {
                library.page(for: old).saveNow()
                state.syncFileName(old)
            }
            storedPage = state.page?.path ?? ""
        }
        .onChange(of: state.focusEditorRequest) {
            DispatchQueue.main.async {
                if let tv = controller.textView { tv.window?.makeFirstResponder(tv) }
            }
        }
        .onChange(of: library.notebooks) { _, notebooks in
            if let nb = state.notebook, !notebooks.contains(where: { $0.url == nb }) { state.notebook = notebooks.first?.url }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in library.saveAll() }
    }

    @ViewBuilder
    private var detail: some View {
        if let model = state.model, !model.isDeleted, FileManager.default.fileExists(atPath: model.url.path) {
            LibraryPageEditor(page: model, controller: controller, showOutline: $showOutline)
        } else {
            ContentUnavailableView {
                Label(state.notebook == nil ? "No Notebook Selected" : "No Page Selected", systemImage: "doc.text")
            } description: {
                Text(state.notebook == nil ? "Choose or create a notebook to start writing." : "Choose a page, or create a new one.")
            } actions: {
                Button(state.notebook == nil ? "New Notebook" : "New Page") {
                    state.notebook == nil ? state.newNotebook() : state.newPage()
                }
                .buttonStyle(.glassProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(settings.theme.color.ignoresSafeArea())
        }
    }

    private func restoreSelection() {
        if storedSidebarHidden { state.columns = .detailOnly }
        if !storedNotebook.isEmpty, library.notebooks.contains(where: { $0.url.path == storedNotebook }) {
            state.notebook = URL(fileURLWithPath: storedNotebook, isDirectory: true).standardizedFileURL
        } else {
            state.notebook = library.notebooks.first?.url
        }
        if !storedPage.isEmpty, FileManager.default.fileExists(atPath: storedPage) {
            state.page = URL(fileURLWithPath: storedPage).standardizedFileURL
        }
    }
}

// MARK: - Editor for a library page

private struct LibraryPageEditor: View {
    @ObservedObject var page: PageModel
    @ObservedObject var controller: EditorController
    @Binding var showOutline: Bool

    var body: some View {
        EditorPane(text: $page.text, controller: controller, fileURL: page.url,
                   undoManager: page.undoManager, documentID: ObjectIdentifier(page),
                   inLibrary: true, showOutline: $showOutline)
            .onDisappear { page.saveNow() }
    }
}

// MARK: - Sidebar (notebooks, with their pages beneath)

private struct LibrarySidebar: View {
    @ObservedObject var state: LibraryWindowState
    @ObservedObject private var library = LibraryStore.shared
    @EnvironmentObject private var settings: AppSettings
    @State private var expanded: Set<URL> = []
    @State private var dropTarget: URL?

    private func isNotebook(_ url: URL) -> Bool { library.notebooks.contains { $0.url == url } }

    /// One selection for the whole list: a page row opens that page; a notebook
    /// row opens the notebook (and its most recent page).
    private var selection: Binding<URL?> {
        Binding {
            state.page ?? state.notebook
        } set: { url in
            guard let url else { return }
            if isNotebook(url) {
                expanded.insert(url)
                state.notebook = url
            } else {
                state.notebook = url.deletingLastPathComponent().standardizedFileURL
                state.page = url
            }
        }
    }

    private func isExpanded(_ url: URL) -> Binding<Bool> {
        Binding { expanded.contains(url) } set: { open in
            if open { expanded.insert(url) } else { expanded.remove(url) }
        }
    }

    var body: some View {
        List(selection: selection) {
            Section("Notebooks") {
                ForEach(library.notebooks) { notebook in
                    DisclosureGroup(isExpanded: isExpanded(notebook.url)) {
                        let pages = library.pages(in: notebook.url, sort: settings.pageSort)
                        ForEach(pages) { page in
                            PageRow(page: page, state: state, live: page.url == state.page ? state.model : nil)
                                .tag(page.url)
                                .draggable(page.url)
                        }
                        if pages.isEmpty {
                            Text("No pages").foregroundStyle(.tertiary).selectionDisabled()
                        }
                    } label: {
                        NotebookRow(notebook: notebook, state: state, isDropTarget: dropTarget == notebook.url)
                            .tag(notebook.url)
                            .dropDestination(for: URL.self) { urls, _ in
                                let pages = urls.filter { LibraryStore.pageExtensions.contains($0.pathExtension.lowercased()) }
                                for url in pages { state.move(url, to: notebook.url) }
                                return !pages.isEmpty
                            } isTargeted: { targeted in
                                dropTarget = targeted ? notebook.url : (dropTarget == notebook.url ? nil : dropTarget)
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: URL.self) { urls in
            if let url = urls.first {
                if isNotebook(url) {
                    Button("New Page") { state.notebook = url; state.newPage() }
                    Button("Rename") { state.renaming = url }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Divider()
                    Button("Move to Trash", role: .destructive) { state.deleteNotebook(url) }
                } else {
                    PageMenu(url: url, state: state)
                }
            }
        } primaryAction: { urls in
            if let url = urls.first { state.renaming = url }
        }
        .safeAreaInset(edge: .bottom) {
            Button { state.newNotebook() } label: {
                Label("New Notebook", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .padding(12)
            .help("New Notebook (⇧⌘N)")
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Sort Pages By", selection: $settings.pageSort) {
                        ForEach(PageSort.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort Pages", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort Pages")
            }
            ToolbarItem {
                Button { state.newPage() } label: { Label("New Page", systemImage: "square.and.pencil") }
                    .help("New Page (⌘N)")
                    .disabled(library.notebooks.isEmpty)
            }
        }
        .onAppear { if let nb = state.notebook { expanded.insert(nb) } }
        .onChange(of: state.notebook) { _, nb in if let nb { expanded.insert(nb) } }
    }
}

private struct NotebookRow: View {
    let notebook: Notebook
    @ObservedObject var state: LibraryWindowState
    var isDropTarget: Bool
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Label {
            if state.renaming == notebook.url {
                TextField("Notebook name", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onAppear { draft = notebook.name; focused = true }
                    .onSubmit { state.rename(notebook.url, to: draft, isNotebook: true) }
                    .onExitCommand { state.renaming = nil }
                    .onChange(of: focused) { _, f in if !f, state.renaming == notebook.url { state.rename(notebook.url, to: draft, isNotebook: true) } }
            } else {
                HStack {
                    Text(notebook.name).lineLimit(1)
                    Spacer()
                    Text("\(notebook.pageCount)").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
        } icon: {
            Image(systemName: isDropTarget ? "book.fill" : "book.closed")
                .foregroundStyle(isDropTarget ? Color.accentColor : .secondary)
        }
    }
}

private struct PageRow: View {
    let page: PageInfo
    @ObservedObject var state: LibraryWindowState
    /// The open page's model, so its name follows the heading as you type.
    var live: PageModel?
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if state.renaming == page.url {
                TextField("Page title", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onAppear { draft = page.title; focused = true }
                    .onSubmit { state.rename(page.url, to: draft, isNotebook: false) }
                    .onExitCommand { state.renaming = nil }
                    .onChange(of: focused) { _, f in if !f, state.renaming == page.url { state.rename(page.url, to: draft, isNotebook: false) } }
            } else if let live {
                LiveTitle(page: live)
            } else {
                Text(page.title).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(page.modified, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .lineLimit(1)
                .layoutPriority(1)
        }
        .padding(.vertical, 3)
    }
}

private struct PageMenu: View {
    let url: URL
    @ObservedObject var state: LibraryWindowState
    @ObservedObject private var library = LibraryStore.shared

    var body: some View {
        Button("Rename") { state.renaming = url }
        Menu("Move To") {
            ForEach(library.notebooks.filter { $0.url != url.deletingLastPathComponent().standardizedFileURL }) { nb in
                Button(nb.name) { state.move(url, to: nb.url) }
            }
        }
        Button("Duplicate") { state.duplicate(url) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Divider()
        Button("Move to Trash", role: .destructive) { state.deletePage(url) }
    }
}

/// The open page's name, updated live from its first heading.
private struct LiveTitle: View {
    @ObservedObject var page: PageModel
    var body: some View {
        Text(page.title).lineLimit(1)
    }
}
