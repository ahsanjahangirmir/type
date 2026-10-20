import SwiftUI

struct TypeCommands: Commands {
    @ObservedObject var settings: AppSettings
    @FocusedObject private var editor: EditorController?
    @FocusedObject private var library: LibraryWindowState?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Page") {
                if let library { library.newPage() } else { showLibrary() }
            }
            .keyboardShortcut("n")
            Button("New Notebook") {
                if let library { library.newNotebook() } else { showLibrary() }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Window") { openWindow(id: "library") }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("New Standalone Document") { NSDocumentController.shared.newDocument(nil) }
                .keyboardShortcut("n", modifiers: [.command, .control])
            Divider()
            Button("Show Library") { showLibrary() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }

        CommandGroup(after: .saveItem) {
            Menu("Export") {
                ForEach(ExportFormat.allCases) { format in
                    Button(format.label) {
                        editor?.export(format, fontChoice: settings.fontChoice, customFamily: settings.customFontFamily)
                    }
                }
            }
            .disabled(editor == nil)
        }

        CommandGroup(replacing: .printItem) {
            Button("Print…") {
                editor?.printDocument(fontChoice: settings.fontChoice, customFamily: settings.customFontFamily)
            }
            .keyboardShortcut("p")
            .disabled(editor == nil)
        }

        CommandGroup(after: .textEditing) {
            Section {
                Button("Find…") { editor?.showFind() }.keyboardShortcut("f")
                Button("Find and Replace…") { editor?.showFind(replace: true) }.keyboardShortcut("f", modifiers: [.command, .option])
            }
            .disabled(editor == nil)
        }

        CommandMenu("Format") {
            Group {
            Group {
                Button("Bold") { editor?.bold() }.keyboardShortcut("b")
                Button("Italic") { editor?.italic() }.keyboardShortcut("i")
                Button("Strikethrough") { editor?.strikethrough() }.keyboardShortcut("x", modifiers: [.command, .shift])
                Button("Highlight") { editor?.highlight() }.keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Inline Code") { editor?.inlineCode() }.keyboardShortcut("e")
                Button("Link") { editor?.link() }.keyboardShortcut("k")
            }
            Divider()
            Group {
                Button("Heading 1") { editor?.heading(1) }.keyboardShortcut("1")
                Button("Heading 2") { editor?.heading(2) }.keyboardShortcut("2")
                Button("Heading 3") { editor?.heading(3) }.keyboardShortcut("3")
                Button("Body Text") { editor?.heading(0) }.keyboardShortcut("0", modifiers: [.command, .option])
            }
            Divider()
            Group {
                Button("Bulleted List") { editor?.bulletList() }.keyboardShortcut("8", modifiers: [.command, .shift])
                Button("Numbered List") { editor?.numberedList() }.keyboardShortcut("7", modifiers: [.command, .shift])
                Button("Checklist") { editor?.taskList() }.keyboardShortcut("9", modifiers: [.command, .shift])
                Button("Quote") { editor?.quote() }.keyboardShortcut("'", modifiers: [.command, .shift])
            }
            Divider()
            Group {
                Button("Insert Image…") { editor?.insertImage() }.keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Insert Table") { editor?.table() }
                Button("Insert Code Block") { editor?.codeBlock() }.keyboardShortcut("c", modifiers: [.command, .option])
                Button("Insert Comment") { editor?.comment() }.keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Insert Divider") { editor?.divider() }
            }
            }
            .disabled(editor == nil)
        }

        CommandGroup(before: .toolbar) {
            Toggle("Focus Mode", isOn: $settings.focusMode).keyboardShortcut("f", modifiers: [.command, .shift])
            Toggle("Typewriter Scrolling", isOn: $settings.typewriterScrolling).keyboardShortcut("t", modifiers: [.command, .option])
            Toggle("Typing Sounds", isOn: $settings.typingSounds).keyboardShortcut("s", modifiers: [.command, .option])
            Picker("Typing Sound", selection: $settings.soundProfile) {
                ForEach(SoundProfile.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Hide Markdown Syntax", isOn: $settings.hideSyntax).keyboardShortcut("h", modifiers: [.command, .control])
            Toggle("Show Statistics", isOn: $settings.showStats).keyboardShortcut("w", modifiers: [.command, .option])
            Toggle("Hide Toolbar While Typing", isOn: $settings.autoHideChrome)
            Divider()
            Button("Zoom In") { settings.zoomIn() }.keyboardShortcut("=")
            Button("Zoom Out") { settings.zoomOut() }.keyboardShortcut("-")
            Button("Actual Size") { settings.resetZoom() }.keyboardShortcut("0")
            Divider()
            Picker("Text Width", selection: $settings.textWidth) {
                ForEach(TextWidth.allCases) { Text($0.label).tag($0) }
            }
            Picker("Appearance", selection: $settings.appearance) {
                ForEach(AppearanceChoice.allCases) { Text($0.label).tag($0) }
            }
            Picker("Theme", selection: $settings.theme) {
                ForEach(PaperTheme.allCases) { Text($0.label).tag($0) }
            }
            Divider()
        }
    }

    private func showLibrary() {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("library") == true && $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "library")
        }
    }
}
