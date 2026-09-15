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

    public static func nextMatchingID(
        in orderedIDs: [String],
        selectedID: String?,
        isMatch: (String) -> Bool
    ) -> String? {
        matchingID(in: orderedIDs, selectedID: selectedID, direction: .next, isMatch: isMatch)
    }

    /// Cycles to the nearest match in `direction`, wrapping around the list.
    ///
    /// The selection itself sits at the end of the search window, so it is only
    /// returned when nothing else matches. Pass `includingSelection: false` to
    /// drop it entirely and make "nothing else matches" a visible no-op rather
    /// than a silent reselection of the session the user is already on.
    public static func matchingID(
        in orderedIDs: [String],
        selectedID: String?,
        direction: SessionSelectionDirection,
        includingSelection: Bool = true,
        isMatch: (String) -> Bool
    ) -> String? {
        guard let selectedID,
              let selectedIndex = orderedIDs.firstIndex(of: selectedID) else {
            let matchingIDs = orderedIDs.filter(isMatch)
            return direction == .next ? matchingIDs.first : matchingIDs.last
        }

        let searchOrder: [String]
        switch direction {
        case .next:
            searchOrder = Array(orderedIDs[(selectedIndex + 1)...]) + Array(orderedIDs[...selectedIndex])
        case .previous:
            searchOrder = Array(orderedIDs[..<selectedIndex].reversed())
                + Array(orderedIDs[selectedIndex...].reversed())
        }

        return searchOrder.first { candidate in
            guard includingSelection || candidate != selectedID else { return false }
            return isMatch(candidate)
        }
    }
}
