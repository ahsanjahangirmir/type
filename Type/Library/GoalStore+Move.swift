import Foundation

extension GoalStore {
    /// Carries writing goals along when a page file or a whole notebook folder is
    /// renamed or moved (goals are keyed by path).
    static func moveGoals(from old: URL, to new: URL) {
        let oldPath = old.standardizedFileURL.path, newPath = new.standardizedFileURL.path
        guard oldPath != newPath, var all = defaults.dictionary(forKey: key) else { return }
        var changed = false
        for (path, goal) in all where path == oldPath || path.hasPrefix(oldPath + "/") {
            all[path] = nil
            all[newPath + path.dropFirst(oldPath.count)] = goal
            changed = true
        }
        if changed { defaults.set(all, forKey: key) }
    }
}
