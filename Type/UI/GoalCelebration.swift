import Foundation

/// Decides when reaching a writing goal deserves the "Goal reached" toast: once
/// per crossing, never for a page that is already over its goal when shown.
struct GoalCelebration {
    private var celebrated = false

    /// Call when a page is shown or its goal changes, with that page's own word count.
    mutating func reset(goal: Int, words: Int) {
        celebrated = goal > 0 && words >= goal
    }

    /// Call when the word count changes; true when the toast should appear.
    mutating func update(goal: Int, words: Int) -> Bool {
        guard goal > 0 else { return false }
        if words >= goal, !celebrated {
            celebrated = true
            return true
        }
        if words < goal { celebrated = false }
        return false
    }
}
