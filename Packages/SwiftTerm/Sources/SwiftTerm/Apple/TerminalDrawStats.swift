//
//  TerminalDrawStats.swift
//
//  Per-draw attribution for the CoreText rendering path, so an embedder can
//  tell an expensive repaint (many rows rebuilt) from a cheap one (cache hits)
//  without attaching Instruments.
//

import Foundation

public struct TerminalDrawStats: Sendable {
    /// Rows the dirty rect mapped onto, before per-row skipping.
    public var rowsInRange = 0
    /// Rows whose attributed string was rebuilt, the dominant per-draw cost.
    public var rowsRebuilt = 0
    /// Rows served from `lineInfoCache`.
    public var rowsCached = 0
    /// Rows skipped entirely because they fell outside the dirty rect.
    public var rowsSkipped = 0
    /// Fraction of the view's height the dirty rect covered.
    public var dirtyHeightFraction = 0.0

    public init() {}
}
