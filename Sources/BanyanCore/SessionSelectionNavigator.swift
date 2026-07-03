public enum SessionSelectionDirection {
    case next
    case previous
}

public enum SessionSelectionNavigator {
    public static func adjacentID(
        in orderedIDs: [String],
        selectedID: String?,
        direction: SessionSelectionDirection
    ) -> String? {
        guard !orderedIDs.isEmpty else { return nil }
        guard let selectedID, let selectedIndex = orderedIDs.firstIndex(of: selectedID) else {
            return direction == .next ? orderedIDs.first : orderedIDs.last
        }

        switch direction {
        case .next:
            return orderedIDs[(selectedIndex + 1) % orderedIDs.count]
        case .previous:
            return orderedIDs[(selectedIndex - 1 + orderedIDs.count) % orderedIDs.count]
        }
    }

    public static func directID(in orderedIDs: [String], oneBasedIndex: Int) -> String? {
        guard oneBasedIndex > 0, oneBasedIndex <= orderedIDs.count else {
            return nil
        }
        return orderedIDs[oneBasedIndex - 1]
    }
}
