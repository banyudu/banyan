import Foundation

/// Reorders session IDs within one sidebar group while preserving the order of
/// all sessions outside that group.
public enum SessionSidebarOrdering {
    public static func reorderedIDs(
        activeIDs: [String],
        groupIDs: [String],
        sourceOffsets: IndexSet,
        destinationOffset: Int
    ) -> [String]? {
        guard !sourceOffsets.isEmpty,
              !groupIDs.isEmpty,
              destinationOffset >= 0,
              destinationOffset <= groupIDs.count,
              sourceOffsets.allSatisfy({ $0 >= 0 && $0 < groupIDs.count })
        else {
            return nil
        }

        let sourceSet = Set(sourceOffsets)
        let movingIDs = sourceOffsets.sorted().map { groupIDs[$0] }
        var remainingIDs = groupIDs.enumerated().compactMap { index, id in
            sourceSet.contains(index) ? nil : id
        }
        let removedBeforeDestination = sourceOffsets.filter { $0 < destinationOffset }.count
        let insertionIndex = max(0, min(destinationOffset - removedBeforeDestination, remainingIDs.count))
        remainingIDs.insert(contentsOf: movingIDs, at: insertionIndex)

        let groupIDSet = Set(groupIDs)
        guard groupIDSet.count == groupIDs.count,
              groupIDSet.isSubset(of: Set(activeIDs)) else {
            return nil
        }

        var reorderedGroupIterator = remainingIDs.makeIterator()
        return activeIDs.map { id in
            if groupIDSet.contains(id) {
                return reorderedGroupIterator.next() ?? id
            }
            return id
        }
    }

    public static func reorderedIDs(
        activeIDs: [String],
        groupIDs: [String],
        sourceID: String,
        targetID: String
    ) -> [String]? {
        guard let sourceIndex = groupIDs.firstIndex(of: sourceID),
              let targetIndex = groupIDs.firstIndex(of: targetID),
              sourceIndex != targetIndex else {
            return nil
        }

        let destinationOffset = sourceIndex < targetIndex ? targetIndex + 1 : targetIndex
        return reorderedIDs(
            activeIDs: activeIDs,
            groupIDs: groupIDs,
            sourceOffsets: IndexSet(integer: sourceIndex),
            destinationOffset: destinationOffset
        )
    }
}
