import Foundation

/// User-controlled board-group expansion. The policy is intentionally not a
/// view: production SwiftUI and the macOS regression executable share it.
enum ForumDirectoryState {
    static let storageKey = "forum.directory.expanded.v1"

    /// No group opens until the user opens it. Builtin and live lists both put
    /// 原创BT电影 first, so "expand the first group" was that category on every
    /// appearance, refresh, and navigation return.
    static func initialExpandedIDs() -> Set<String> { [] }

    static func restoredExpandedIDs(stored: String?) -> Set<String> {
        guard let stored else { return initialExpandedIDs() }
        let ids = stored.split(separator: "\n").map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return Set(ids)
    }

    static func persistedValue(for ids: Set<String>) -> String {
        ids.sorted().joined(separator: "\n")
    }

    /// A category replacement must not invent expansion. Unknown ids stay
    /// collapsed; ids the user opened stay open across refresh and pop-back.
    static func reconciledExpandedIDs(_ stored: Set<String>, categories: [ForumCategory]) -> Set<String> {
        let valid = Set(categories.filter { $0.boards.contains { !$0.isAd } }.map(\.id))
        return stored.intersection(valid)
    }

    static func toggled(_ ids: Set<String>, categoryID: String) -> Set<String> {
        var next = ids
        if next.contains(categoryID) { next.remove(categoryID) } else { next.insert(categoryID) }
        return next
    }
}
