import Foundation

/// Prioritized new/restored media is never stranded behind a persisted cursor.
/// The caller caches this result across animation frames.
enum ReviewQueueOrdering {
    static func prepending(_ incoming: [String], to existing: [String]) -> [String] {
        var seen = Set<String>()
        return (incoming + existing).filter { seen.insert($0).inserted }
    }

    static func arrange<Element>(_ items: [Element], id: (Element) -> String,
                                 resumeID: String?, priorityIDs: [String]) -> [Element] {
        let lookup = Dictionary(uniqueKeysWithValues: items.map { (id($0), $0) })
        var seen = Set<String>()
        let priority = priorityIDs.compactMap { key -> Element? in
            guard seen.insert(key).inserted else { return nil }
            return lookup[key]
        }
        let remaining = items.filter { !seen.contains(id($0)) }
        guard let resumeID, let index = remaining.firstIndex(where: { id($0) == resumeID }), index > 0 else {
            return priority + remaining
        }
        return priority + Array(remaining[index...]) + Array(remaining[..<index])
    }
}
