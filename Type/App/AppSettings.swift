import SwiftUI
import AppKit

// MARK: - Option enums

enum TextWidth: String, CaseIterable, Identifiable {
    case narrow, medium, wide, full
    var id: String { rawValue }
    var label: String {
        switch self {
        case .narrow: "Narrow"
        case .medium: "Medium"
        case .wide: "Wide"
        case .full: "Full Width"
        }
    }
    /// Maximum column width in points; nil means fill the window.
    var points: CGFloat? {
        switch self {
        case .narrow: 560
        case .medium: 700
        case .wide: 880
        case .full: nil
        }
    }
}

enum FontChoice: String, CaseIterable, Identifiable {
    case serif, sans, rounded, mono, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .serif: "New York (Serif)"
        case .sans: "SF Pro (Sans)"
        case .rounded: "SF Pro Rounded"
        case .mono: "SF Mono"
        case .custom: "Other Font…"
        }
    }
}

enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum PaperTheme: String, CaseIterable, Identifiable {
    case plain, paper, sepia, slate
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var nsColor: NSColor {
        func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
            NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
        }
        switch self {
        case .plain:
            return .textBackgroundColor
        case .paper:
            return dynamic(NSColor(srgbRed: 0.985, green: 0.978, blue: 0.962, alpha: 1),
                           NSColor(srgbRed: 0.105, green: 0.105, blue: 0.11, alpha: 1))
        case .sepia:
            return dynamic(NSColor(srgbRed: 0.968, green: 0.937, blue: 0.874, alpha: 1),
                           NSColor(srgbRed: 0.16, green: 0.135, blue: 0.11, alpha: 1))
        case .slate:
            return dynamic(NSColor(srgbRed: 0.93, green: 0.945, blue: 0.96, alpha: 1),
                           NSColor(srgbRed: 0.09, green: 0.11, blue: 0.14, alpha: 1))
        }
    }
    var color: Color { Color(nsColor: nsColor) }
}

enum CaretColor: String, CaseIterable, Identifiable {
    case accent, blue, purple, pink, orange, green, graphite
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var nsColor: NSColor {
        switch self {
        case .accent: .controlAccentColor
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        case .orange: .systemOrange
        case .green: .systemGreen
        case .graphite: .secondaryLabelColor
        }
    }
}

/// Background color of selected text.
enum SelectionColor: String, CaseIterable, Identifiable {
    case system, accent, blue, purple, pink, orange, yellow, green, graphite, custom
    var id: String { rawValue }
    var label: String { self == .system ? "System Highlight" : rawValue.capitalized }

    /// Swatch for pickers (the solid hue, before transparency).
    var swatch: NSColor {
        switch self {
        case .system: .selectedTextBackgroundColor
        case .accent: .controlAccentColor
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .graphite: .systemGray
        case .custom: .systemGray
        }
    }

    /// The selection background. Tints are translucent so the text stays readable;
    /// a custom color is used exactly as picked (including its opacity).
    func nsColor(custom hex: String) -> NSColor {
        switch self {
        case .system: .selectedTextBackgroundColor
        case .custom: NSColor(hex: hex) ?? .selectedTextBackgroundColor
        default: swatch.dynamicAlpha(0.32)
        }
    }
}

extension NSColor {
    /// Parses "#RRGGBB" or "#RRGGBBAA".
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let rgba = s.count == 6 ? (v << 8 | 0xFF) : v
        self.init(srgbRed: CGFloat(rgba >> 24 & 0xFF) / 255, green: CGFloat(rgba >> 16 & 0xFF) / 255,
                  blue: CGFloat(rgba >> 8 & 0xFF) / 255, alpha: CGFloat(rgba & 0xFF) / 255)
    }

    /// "#RRGGBBAA" in sRGB.
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        func byte(_ x: CGFloat) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent), byte(c.alphaComponent))
    }
}

enum CommentTint: String, CaseIterable, Identifiable {
    case green, yellow, blue, pink, purple
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var nsColor: NSColor {
        switch self {
        case .green: .systemGreen
        case .yellow: .systemYellow
        case .blue: .systemBlue
        case .pink: .systemPink
        case .purple: .systemPurple
        }
    }
}

enum WritingDirection: String, CaseIterable, Identifiable {
    case natural, leftToRight, rightToLeft
    var id: String { rawValue }
    var label: String {
        switch self {
        case .natural: "Automatic"
        case .leftToRight: "Left to Right"
        case .rightToLeft: "Right to Left"
        }
    }
    var nsDirection: NSWritingDirection {
        switch self {
        case .natural: .natural
        case .leftToRight: .leftToRight
        case .rightToLeft: .rightToLeft
        }
    }
}

enum PageSort: String, CaseIterable, Identifiable {
    case modified, name
    var id: String { rawValue }
    var label: String { self == .modified ? "Date Modified" : "Name" }
}

// MARK: - Editor configuration snapshot

/// Immutable snapshot of everything the text view needs. Comparing snapshots
/// lets the editor restyle only when something visible actually changed.
struct EditorConfig: Equatable {
    var fontChoice: FontChoice
    var customFontFamily: String
    var fontSize: CGFloat
    var lineHeight: CGFloat
    var paragraphSpacing: Bool
    var textWidth: TextWidth
    var direction: WritingDirection
    var caretColor: CaretColor
    var hideCaret: Bool
    var selectionColor: SelectionColor
    var selectionCustomHex: String
    var focusMode: Bool
    var focusOpacity: CGFloat
    var typewriterScrolling: Bool
    var smartQuotes: Bool
    var smartDashes: Bool
    var smartEllipses: Bool
    var smartArrows: Bool
    var autoCapitalize: Bool
    var continueLists: Bool
    var typingSounds: Bool
    var commentTint: CommentTint
    var dimSyntax: Bool
    var hideSyntax: Bool
    var smoothTyping: Bool
}

// MARK: - Settings store

/// App-wide preferences, persisted to UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let store = UserDefaults.standard

    // Appearance
    @Published var appearance: AppearanceChoice = .system { didSet { save(appearance.rawValue, "appearance") } }
    @Published var theme: PaperTheme = .paper { didSet { save(theme.rawValue, "theme") } }
    @Published var autoHideChrome = true { didSet { save(autoHideChrome, "autoHideChrome") } }

    // Typography
    @Published var fontChoice: FontChoice = .serif { didSet { save(fontChoice.rawValue, "fontChoice") } }
    @Published var customFontFamily = "Charter" { didSet { save(customFontFamily, "customFontFamily") } }
    @Published var fontSize: Double = 18 { didSet { save(fontSize, "fontSize") } }
    @Published var zoom: Double = 1.0 { didSet { save(zoom, "zoom") } }
    @Published var lineHeight: Double = 1.5 { didSet { save(lineHeight, "lineHeight") } }
    @Published var paragraphSpacing = true { didSet { save(paragraphSpacing, "paragraphSpacing") } }
    @Published var textWidth: TextWidth = .medium { didSet { save(textWidth.rawValue, "textWidth") } }
    @Published var direction: WritingDirection = .natural { didSet { save(direction.rawValue, "direction") } }
    @Published var caretColor: CaretColor = .accent { didSet { save(caretColor.rawValue, "caretColor") } }
    @Published var hideCaret = false { didSet { save(hideCaret, "hideCaret") } }
    @Published var selectionColor: SelectionColor = .system { didSet { save(selectionColor.rawValue, "selectionColor") } }
    @Published var selectionCustomHex = "#FF9F0A59" { didSet { save(selectionCustomHex, "selectionCustomHex") } }
    @Published var dimSyntax = true { didSet { save(dimSyntax, "dimSyntax") } }
    @Published var hideSyntax = false { didSet { save(hideSyntax, "hideSyntax") } }
    @Published var smoothTyping = true { didSet { save(smoothTyping, "smoothTyping") } }
    @Published var commentTint: CommentTint = .green { didSet { save(commentTint.rawValue, "commentTint") } }

    // Writing
    @Published var focusMode = false { didSet { save(focusMode, "focusMode") } }
    @Published var focusOpacity: Double = 0.25 { didSet { save(focusOpacity, "focusOpacity") } }
    @Published var typewriterScrolling = false { didSet { save(typewriterScrolling, "typewriterScrolling") } }
    @Published var smartQuotes = true { didSet { save(smartQuotes, "smartQuotes") } }
    @Published var smartDashes = true { didSet { save(smartDashes, "smartDashes") } }
    @Published var smartEllipses = true { didSet { save(smartEllipses, "smartEllipses") } }
    @Published var smartArrows = true { didSet { save(smartArrows, "smartArrows") } }
    @Published var autoCapitalize = false { didSet { save(autoCapitalize, "autoCapitalize") } }
    @Published var continueLists = true { didSet { save(continueLists, "continueLists") } }

    // Sound
    @Published var typingSounds = false { didSet { save(typingSounds, "typingSounds") } }
    @Published var soundVolume: Double = 0.6 { didSet { save(soundVolume, "soundVolume"); TypingSounds.shared.volume = Float(soundVolume) } }
    @Published var soundProfile: SoundProfile = .mechanical { didSet { save(soundProfile.rawValue, "soundProfile"); TypingSounds.shared.profile = soundProfile } }

    // Library
    @Published var libraryPath: String = AppSettings.defaultLibraryPath { didSet { save(libraryPath, "libraryPath") } }
    @Published var pageSort: PageSort = .modified { didSet { save(pageSort.rawValue, "pageSort") } }

    static var defaultLibraryPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Type").path
    }

    // Statistics
    @Published var showStats = true { didSet { save(showStats, "showStats") } }
    @Published var showCharacters = true { didSet { save(showCharacters, "showCharacters") } }
    @Published var countSpaces = false { didSet { save(countSpaces, "countSpaces") } }
    @Published var showReadingTime = true { didSet { save(showReadingTime, "showReadingTime") } }
    @Published var wordsPerMinute: Double = 270 { didSet { save(wordsPerMinute, "wordsPerMinute") } }

    private init() {
        func load<E: RawRepresentable>(_ key: String, _ value: inout E) where E.RawValue == String {
            if let raw = store.string(forKey: key), let v = E(rawValue: raw) { value = v }
        }
        func load(_ key: String, _ value: inout Bool) {
            if store.object(forKey: key) != nil { value = store.bool(forKey: key) }
        }
        func load(_ key: String, _ value: inout Double) {
            if store.object(forKey: key) != nil { value = store.double(forKey: key) }
        }
        load("appearance", &appearance)
        load("theme", &theme)
        load("autoHideChrome", &autoHideChrome)
        load("fontChoice", &fontChoice)
        if let fam = store.string(forKey: "customFontFamily") { customFontFamily = fam }
        load("fontSize", &fontSize)
        load("zoom", &zoom)
        load("lineHeight", &lineHeight)
        load("paragraphSpacing", &paragraphSpacing)
        load("textWidth", &textWidth)
        load("direction", &direction)
        load("caretColor", &caretColor)
        load("hideCaret", &hideCaret)
        load("selectionColor", &selectionColor)
        if let hex = store.string(forKey: "selectionCustomHex"), NSColor(hex: hex) != nil { selectionCustomHex = hex }
        load("dimSyntax", &dimSyntax)
        load("hideSyntax", &hideSyntax)
        load("smoothTyping", &smoothTyping)
        load("soundProfile", &soundProfile)
        if let path = store.string(forKey: "libraryPath"), !path.isEmpty { libraryPath = (path as NSString).expandingTildeInPath }
        if Self.isTestHost {
            // Unit tests run inside the app: never open (or rename files in) the real library.
            libraryPath = FileManager.default.temporaryDirectory.appendingPathComponent("TypeTestHostLibrary").path
        }
        load("pageSort", &pageSort)
        load("commentTint", &commentTint)
        load("focusMode", &focusMode)
        load("focusOpacity", &focusOpacity)
        load("typewriterScrolling", &typewriterScrolling)
        load("smartQuotes", &smartQuotes)
        load("smartDashes", &smartDashes)
        load("smartEllipses", &smartEllipses)
        load("smartArrows", &smartArrows)
        load("autoCapitalize", &autoCapitalize)
        load("continueLists", &continueLists)
        load("typingSounds", &typingSounds)
        load("soundVolume", &soundVolume)
        load("showStats", &showStats)
        load("showCharacters", &showCharacters)
        load("countSpaces", &countSpaces)
        load("showReadingTime", &showReadingTime)
        load("wordsPerMinute", &wordsPerMinute)
        TypingSounds.shared.volume = Float(soundVolume)
        TypingSounds.shared.profile = soundProfile
    }

    /// Settings given as launch arguments (`-libraryPath /tmp/x`) apply to that
    /// run only; they must never overwrite the user's saved preferences.
    private static let launchOverrides = Set(UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain).keys)

    /// True when the app is hosting the unit tests.
    static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil

    private func save(_ value: Any, _ key: String) {
        guard !Self.launchOverrides.contains(key), !Self.isTestHost else { return }
        store.set(value, forKey: key)
    }

    var editorConfig: EditorConfig {
        EditorConfig(
            fontChoice: fontChoice,
            customFontFamily: customFontFamily,
            fontSize: CGFloat(fontSize * zoom),
            lineHeight: CGFloat(lineHeight),
            paragraphSpacing: paragraphSpacing,
            textWidth: textWidth,
            direction: direction,
            caretColor: caretColor,
            hideCaret: hideCaret,
            selectionColor: selectionColor,
            selectionCustomHex: selectionCustomHex,
            focusMode: focusMode,
            focusOpacity: CGFloat(focusOpacity),
            typewriterScrolling: typewriterScrolling,
            smartQuotes: smartQuotes,
            smartDashes: smartDashes,
            smartEllipses: smartEllipses,
            smartArrows: smartArrows,
            autoCapitalize: autoCapitalize,
            continueLists: continueLists,
            typingSounds: typingSounds,
            commentTint: commentTint,
            dimSyntax: dimSyntax,
            hideSyntax: hideSyntax,
            smoothTyping: smoothTyping
        )
    }

    // Zoom (⌘+ / ⌘- / ⌘0)
    func zoomIn() { zoom = min(3.0, (zoom + 0.1).rounded(toPlaces: 2)) }
    func zoomOut() { zoom = max(0.5, (zoom - 0.1).rounded(toPlaces: 2)) }
    func resetZoom() { zoom = 1.0 }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let m = pow(10, Double(places))
        return (self * m).rounded() / m
    }
}
