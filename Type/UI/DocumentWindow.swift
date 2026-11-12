import SwiftUI

/// A standalone Markdown / text file opened from Finder (outside the library).
struct DocumentWindow: View {
    @Binding var document: TypeDocument
    let fileURL: URL?

    @EnvironmentObject private var settings: AppSettings
    @StateObject private var controller = EditorController()
    @SceneStorage("showOutline") private var showOutline = false

    var body: some View {
        EditorPane(text: $document.text, controller: controller, fileURL: fileURL, showOutline: $showOutline)
            .navigationTitle(controller.title)
            .navigationSubtitle(controller.currentHeading?.title ?? "")
            .focusedSceneObject(controller)
            .focusedSceneValue(\.showOutline, $showOutline)
            .preferredColorScheme(settings.appearance.colorScheme)
    }
}
