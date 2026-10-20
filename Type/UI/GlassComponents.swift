import SwiftUI

// MARK: - Status pill (word count, goal)

struct StatusPill: View {
    @ObservedObject var controller: EditorController
    @Binding var goal: Int
    @EnvironmentObject private var settings: AppSettings
    @State private var showDetails = false

    private var stats: DocumentStats { controller.stats }
    private var progress: Double { goal > 0 ? min(1, Double(stats.words) / Double(goal)) : 0 }

    var body: some View {
        Button { showDetails.toggle() } label: {
            HStack(spacing: 10) {
                if goal > 0 {
                    ZStack {
                        Circle().stroke(.secondary.opacity(0.25), lineWidth: 2.5)
                        Circle().trim(from: 0, to: progress)
                            .stroke(progress >= 1 ? Color.green : Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.smooth, value: progress)
                    }
                    .frame(width: 14, height: 14)
                }
                Text(summary)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: stats.words)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .popover(isPresented: $showDetails, arrowEdge: .top) {
            StatsDetails(controller: controller, goal: $goal)
                .environmentObject(settings)
        }
        .help("Document statistics")
    }

    private var summary: String {
        var parts = ["\(stats.words.formatted()) \(stats.words == 1 ? "word" : "words")"]
        if goal > 0 { parts[0] = "\(stats.words.formatted()) / \(goal.formatted())" }
        if settings.showCharacters {
            let chars = settings.countSpaces ? stats.characters : stats.charactersNoSpaces
            parts.append("\(chars.formatted()) characters")
        }
        if settings.showReadingTime, stats.words > 0 {
            parts.append("\(stats.readingMinutes(wordsPerMinute: settings.wordsPerMinute)) min read")
        }
        return parts.joined(separator: "  ·  ")
    }
}

struct StatsDetails: View {
    @ObservedObject var controller: EditorController
    @Binding var goal: Int
    @EnvironmentObject private var settings: AppSettings
    @State private var goalText = ""

    var body: some View {
        let s = controller.stats
        VStack(alignment: .leading, spacing: 14) {
            Text("Statistics").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                row("Words", s.words)
                row("Characters", s.characters)
                row("Without spaces", s.charactersNoSpaces)
                row("Paragraphs", s.paragraphs)
                GridRow {
                    Text("Reading time").foregroundStyle(.secondary)
                    Text("\(s.readingMinutes(wordsPerMinute: settings.wordsPerMinute)) min").monospacedDigit()
                }
            }
            Divider()
            Text("Writing Goal").font(.headline)
            HStack {
                TextField("Words", text: $goalText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .onSubmit(applyGoal)
                Button("Set", action: applyGoal).buttonStyle(.glass)
                if goal > 0 {
                    Button("Clear") { goal = 0; goalText = "" }.buttonStyle(.glass)
                }
            }
            HStack(spacing: 6) {
                ForEach([250, 500, 1000, 2000], id: \.self) { preset in
                    Button(preset.formatted()) { goal = preset; goalText = "\(preset)" }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            }
            Divider()
            Toggle("Show characters", isOn: $settings.showCharacters)
            Toggle("Count spaces", isOn: $settings.countSpaces)
            Toggle("Show reading time", isOn: $settings.showReadingTime)
        }
        .padding(18)
        .frame(width: 280)
        .onAppear { goalText = goal > 0 ? "\(goal)" : "" }
    }

    private func row(_ label: String, _ value: Int) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value.formatted()).monospacedDigit()
        }
    }

    private func applyGoal() {
        goal = max(0, Int(goalText.filter(\.isNumber)) ?? 0)
    }
}

struct GoalToast: View {
    let goal: Int
    @State private var bounce = false

    var body: some View {
        Label("Goal reached — \(goal.formatted()) words", systemImage: "checkmark.seal.fill")
            .font(.callout.weight(.medium))
            .symbolEffect(.bounce, value: bounce)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular.tint(.green.opacity(0.35)), in: .capsule)
            .onAppear { bounce.toggle() }
    }
}

// MARK: - Slash menu

struct SlashMenu: View {
    @ObservedObject var controller: EditorController
    let state: SlashState

    var body: some View {
        let items = controller.filteredSlashCommands
        VStack(alignment: .leading, spacing: 2) {
            if items.isEmpty {
                Text("No matches").foregroundStyle(.secondary).padding(10)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            Button { controller.runSlash(item) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: item.symbol)
                                        .frame(width: 26, height: 26)
                                        .background(.quaternary, in: .rect(cornerRadius: 7))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.title).font(.callout.weight(.medium))
                                        Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background {
                                    if index == state.selection {
                                        RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.18))
                                    }
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .id(item.id)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: state.selection) { _, sel in
                    if sel < items.count { withAnimation { proxy.scrollTo(items[sel].id, anchor: .center) } }
                }
            }
        }
        .frame(width: 250, height: min(CGFloat(max(items.count, 1)) * 44 + 12, 320))
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
    }
}

// MARK: - Outline

struct OutlineSidebar: View {
    @ObservedObject var controller: EditorController

    var body: some View {
        Group {
            if controller.outline.isEmpty {
                ContentUnavailableView("No Headings", systemImage: "list.bullet.indent",
                                       description: Text("Start a line with # to add a heading."))
            } else {
                List(selection: Binding(
                    get: { controller.currentHeading },
                    set: { if let item = $0 { controller.reveal(item) } }
                )) {
                    ForEach(controller.outline) { item in
                        Text(item.title)
                            .font(item.level == 1 ? .body.weight(.semibold) : .body)
                            .foregroundStyle(item.level <= 2 ? .primary : .secondary)
                            .lineLimit(2)
                            .padding(.leading, CGFloat(item.level - 1) * 12)
                            .tag(item)
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }
}
