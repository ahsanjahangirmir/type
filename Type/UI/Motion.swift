import SwiftUI

/// Respects System Settings ▸ Accessibility ▸ Display ▸ Reduce Motion.
enum Motion {
    /// Overridden in tests; nil follows the system setting.
    nonisolated(unsafe) static var overrideReduced: Bool?

    static var reduced: Bool {
        overrideReduced ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// `animation`, or a brief cross-fade when motion is reduced.
    static func animation(_ animation: Animation) -> Animation {
        reduced ? .easeInOut(duration: 0.12) : animation
    }

    /// `transition`, or a plain fade when motion is reduced.
    static func transition(_ transition: AnyTransition) -> AnyTransition {
        reduced ? .opacity : transition
    }
}

/// Shadows SwiftUI's `withAnimation` for the whole app, so every state change
/// animated this way honors Reduce Motion (as a quick fade rather than movement).
func withAnimation<Result>(_ animation: Animation? = .default, _ body: () throws -> Result) rethrows -> Result {
    try SwiftUI.withAnimation(animation.map(Motion.animation), body)
}
