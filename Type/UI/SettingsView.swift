import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Typography", systemImage: "textformat") { TypographySettings() }
            Tab("Writing", systemImage: "pencil.and.scribble") { WritingSettings() }
            Tab("Sound", systemImage: "speaker.wave.2") { SoundSettings() }
            Tab("Statistics", systemImage: "chart.bar") { StatisticsSettings() }
        }
        .frame(width: 520)
        .scenePadding()
        .preferredColorScheme(settings.appearance.colorScheme)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Picker("Appearance", selection: $settings.appearance) {
                ForEach(AppearanceChoice.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Background", selection: $settings.theme) {
                ForEach(PaperTheme.allCases) { theme in
                    Label {
                        Text(theme.label)
                    } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(theme.color)
                    }
                    .tag(theme)
                }
            }
            Toggle("Hide toolbar while typing", isOn: $settings.autoHideChrome)
            Text("The toolbar fades away as you type and returns when you move the mouse.")
                .font(.caption).foregroundStyle(.secondary)

            Section("Library") {
                LabeledContent("Location") {
                    HStack {
                        Text((settings.libraryPath as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseLibrary)
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: settings.libraryPath)])
                        } label: { Image(systemName: "folder") }
                        .help("Show in Finder")
                    }
                }
                Picker("Sort pages by", selection: $settings.pageSort) {
                    ForEach(PageSort.allCases) { Text($0.label).tag($0) }
                }
                Text("Notebooks are folders and pages are Markdown files, so you can sync the library with iCloud Drive or open it in other apps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

extension GeneralSettings {
    func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use as Library"
        panel.directoryURL = URL(fileURLWithPath: settings.libraryPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.libraryPath = url.path
        LibraryStore.shared.setRoot(url)
    }
}

private struct TypographySettings: View {
    @EnvironmentObject private var settings: AppSettings
    private let families = NSFontManager.shared.availableFontFamilies

    private var customSelection: Binding<Color> {
        Binding {
            Color(nsColor: NSColor(hex: settings.selectionCustomHex) ?? .selectedTextBackgroundColor)
        } set: { color in
            settings.selectionCustomHex = NSColor(color).hexString
        }
    }

    var body: some View {
        Form {
            Section("Font") {
                Picker("Typeface", selection: $settings.fontChoice) {
                    ForEach(FontChoice.allCases) { Text($0.label).tag($0) }
                }
                if settings.fontChoice == .custom {
                    Picker("Family", selection: $settings.customFontFamily) {
                        ForEach(families, id: \.self) { Text($0).tag($0) }
                    }
                }
                LabeledContent("Size") {
                    HStack {
                        Slider(value: $settings.fontSize, in: 12...32, step: 1)
                        Text("\(Int(settings.fontSize)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent("Line height") {
                    HStack {
                        Slider(value: $settings.lineHeight, in: 1.0...2.2, step: 0.05)
                        Text(settings.lineHeight, format: .number.precision(.fractionLength(2))).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Toggle("Space between paragraphs", isOn: $settings.paragraphSpacing)
            }
            Section("Layout") {
                Picker("Text width", selection: $settings.textWidth) {
                    ForEach(TextWidth.allCases) { Text($0.label).tag($0) }
                }
                Picker("Text direction", selection: $settings.direction) {
                    ForEach(WritingDirection.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("Comments") {
                Picker("Comment color", selection: $settings.commentTint) {
                    ForEach(CommentTint.allCases) { tint in
                        Label { Text(tint.label) } icon: { Image(systemName: "circle.fill").foregroundStyle(Color(nsColor: tint.nsColor)) }
                            .tag(tint)
                    }
                }
            }
            Section("Cursor") {
                Picker("Caret color", selection: $settings.caretColor) {
                    ForEach(CaretColor.allCases) { c in
                        Label { Text(c.label) } icon: { Image(systemName: "circle.fill").foregroundStyle(Color(nsColor: c.nsColor)) }
                            .tag(c)
                    }
                }
                Toggle("Hide caret", isOn: $settings.hideCaret)
                Toggle(isOn: $settings.smoothTyping) {
                    Text("Smooth typing")
                    Text("The caret glides as you type and letters fade in and out.")
                }
            }
            Section("Selection") {
                Picker("Selection color", selection: $settings.selectionColor) {
                    ForEach(SelectionColor.allCases.filter { $0 != .custom }) { c in
                        Label { Text(c.label) } icon: { Image(systemName: "circle.fill").foregroundStyle(Color(nsColor: c.swatch)) }
                            .tag(c)
                    }
                    Divider()
                    Text("Custom").tag(SelectionColor.custom)
                }
                if settings.selectionColor == .custom {
                    ColorPicker("Custom color", selection: customSelection, supportsOpacity: true)
                }
                SelectionPreview(color: settings.selectionColor.nsColor(custom: settings.selectionCustomHex))
            }
        }
        .formStyle(.grouped)
    }
}

private struct WritingSettings: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Focus") {
                Toggle("Focus mode", isOn: $settings.focusMode)
                LabeledContent("Dimmed text opacity") {
                    Slider(value: $settings.focusOpacity, in: 0.05...0.7)
                }
                .disabled(!settings.focusMode)
                Toggle("Typewriter scrolling", isOn: $settings.typewriterScrolling)
            }
            Section("Smart Typing") {
                Toggle("Smart quotes  “ ” ‘ ’", isOn: $settings.smartQuotes)
                Toggle("Smart dashes  -- → —", isOn: $settings.smartDashes)
                Toggle("Smart ellipses  ... → …", isOn: $settings.smartEllipses)
                Toggle("Smart arrows  -> → →", isOn: $settings.smartArrows)
                Toggle("Capitalize sentences automatically", isOn: $settings.autoCapitalize)
                Toggle("Continue lists on Return", isOn: $settings.continueLists)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SoundSettings: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Toggle("Typing sounds", isOn: $settings.typingSounds)
            Section("Sound") {
                ForEach(SoundProfile.allCases) { profile in
                    HStack {
                        Image(systemName: settings.soundProfile == profile ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(settings.soundProfile == profile ? Color.accentColor : .secondary)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(profile.label)
                            Text(profile.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            TypingSounds.shared.preview(profile)
                        } label: {
                            Label("Preview", systemImage: "play.fill").labelStyle(.iconOnly)
                        }
                        .buttonStyle(.glass)
                        .help("Preview \(profile.label)")
                    }
                    .contentShape(.rect)
                    .onTapGesture {
                        settings.soundProfile = profile
                        if !settings.typingSounds { settings.typingSounds = true }
                        TypingSounds.shared.preview(profile)
                    }
                }
            }
            .disabled(!settings.typingSounds)
            LabeledContent("Volume") {
                HStack {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: $settings.soundVolume, in: 0...1)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
            }
            .disabled(!settings.typingSounds)
        }
        .formStyle(.grouped)
    }
}

private struct StatisticsSettings: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Toggle("Show statistics", isOn: $settings.showStats)
            Toggle("Show character count", isOn: $settings.showCharacters)
            Toggle("Include spaces in character count", isOn: $settings.countSpaces)
            Toggle("Show reading time", isOn: $settings.showReadingTime)
            LabeledContent("Reading speed") {
                Stepper("\(Int(settings.wordsPerMinute)) words per minute", value: $settings.wordsPerMinute, in: 100...600, step: 10)
            }
        }
        .formStyle(.grouped)
    }
}

/// A line of sample text with a few words selected in the chosen color.
private struct SelectionPreview: View {
    let color: NSColor

    var body: some View {
        LabeledContent("Preview") {
            HStack(spacing: 0) {
                Text("Select ")
                Text("this text").background(Color(nsColor: color), in: .rect(cornerRadius: 2))
                Text(" to see it")
            }
            .font(.system(.body, design: .serif))
        }
    }
}
