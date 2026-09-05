import Foundation

enum PlaybackPolicy {
    static func eligibleTarget(currentID: SekaiID?, visibleIDs: [SekaiID],
                               foreground: Bool, displayed: Bool, settled: Bool) -> SekaiID? {
        guard foreground, displayed, settled, let currentID, visibleIDs.contains(currentID) else { return nil }
        return currentID
    }

    static func replacement(oldIDs: [SekaiID], newIDs: [SekaiID], currentID: SekaiID?) -> SekaiID? {
        guard let currentID, let oldIndex = oldIDs.firstIndex(of: currentID) else { return newIDs.first }
        let survivors = Set(newIDs)
        if survivors.contains(currentID) { return currentID }
        if let next = oldIDs.dropFirst(oldIndex + 1).first(where: survivors.contains) { return next }
        return oldIDs.prefix(oldIndex).reversed().first(where: survivors.contains) ?? newIDs.first
    }
}
