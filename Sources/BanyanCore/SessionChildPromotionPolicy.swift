import Foundation

/// Rules for what happens to a closing session's direct children.
///
/// Children move up exactly one tree level — to the closing session's parent
/// level, never under one of the closing session's siblings — and take the
/// closing session's place in manual order. Closing `B` in `A, B(B1, B2), C`
/// therefore yields `A, B1, B2, C`: the subtree is promoted, not re-nested
/// under `A` and not left behind at the end of the list.
public enum SessionChildPromotionPolicy {
    /// Parent ID the direct children of a closing session move to: the
    /// closing session's own parent (nil for a top-level session).
    public static func promotedParentID(
        closingParentID: String?
    ) -> String? {
        SessionInputPolicy.normalizedOptionalText(closingParentID)
    }

    /// Reorders `orderedIDs` so `promotedChildIDs` (in their given relative
    /// order) end up where `closingID` was.
    ///
    /// - `removingParent`: true when the closing row leaves the array
    ///   (`remove`); the children are inserted at its index. False when the
    ///   closing row stays as a hidden closed row (`close`); the children are
    ///   inserted immediately after it. Either way the visible order keeps the
    ///   promoted children where their parent was instead of wherever they
    ///   happened to sit in the array (child sessions are appended at spawn
    ///   time, so without this they would jump to the end: `A, C, B1, B2`).
    ///
    /// Returns nil when there is nothing to do (no promoted children, unknown
    /// closing ID, or the order already matches).
    public static func reorderedIDs(
        orderedIDs: [String],
        closingID: String,
        promotedChildIDs: [String],
        removingParent: Bool
    ) -> [String]? {
        guard !promotedChildIDs.isEmpty,
              orderedIDs.contains(closingID),
              Set(promotedChildIDs).count == promotedChildIDs.count,
              !promotedChildIDs.contains(closingID)
        else {
            return nil
        }
        let promotedSet = Set(promotedChildIDs)
        guard promotedSet.isSubset(of: Set(orderedIDs)) else { return nil }

        if removingParent {
            let closingIndex = orderedIDs.firstIndex(of: closingID) ?? 0
            let promotedBeforeClosing = orderedIDs[..<closingIndex].filter {
                promotedSet.contains($0)
            }.count
            var remaining = orderedIDs.filter {
                $0 != closingID && !promotedSet.contains($0)
            }
            let insertionIndex = closingIndex - promotedBeforeClosing
            let clamped = max(0, min(insertionIndex, remaining.count))
            remaining.insert(contentsOf: promotedChildIDs, at: clamped)
            return remaining == orderedIDs ? nil : remaining
        }

        var remaining = orderedIDs.filter { !promotedSet.contains($0) }
        guard let closingIndex = remaining.firstIndex(of: closingID) else {
            return nil
        }
        let insertionIndex = closingIndex + 1
        remaining.insert(contentsOf: promotedChildIDs, at: insertionIndex)
        return remaining == orderedIDs ? nil : remaining
    }
}
