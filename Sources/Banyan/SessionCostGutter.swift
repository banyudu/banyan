import AppKit
import BanyanCore
import Combine
import SwiftUI
import UniformTypeIdentifiers


// MARK: - Jump overlay badge

/// Visual-only cost readout for `SessionRow`'s trailing gutter. The row owns
/// hover tracking so this view never intercepts a title or trailing control.
struct SessionCostGutter: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let visibleDuration: Duration = .milliseconds(500)

    let session: BanyanSession
    let isHovered: Bool
    let source: () -> SessionCostTranscriptSource?
    let estimate: (SessionCostTranscriptSource) async -> SessionCostEstimate?
    let onEstimate: (SessionCostEstimate?) -> Void

    @State private var visibleEstimate: SessionCostEstimate?

    private var amountText: String? {
        guard case let .complete(amount, _) = visibleEstimate else { return nil }
        return SessionCostDisplay(amount: amount).text
    }

    private var tint: Color {
        guard case let .complete(_, tint) = visibleEstimate else { return .secondary }
        switch tint {
        case .claude: return .orange
        case .codex: return .cyan
        case .deepSeek: return Color.linearHex("4d6bfe")
        case .mixed: return .purple
        }
    }

    var body: some View {
        Text(amountText ?? "")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(tint)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                    }
            }
            .opacity(amountText == nil ? 0 : 1)
            .offset(x: amountText == nil && !reduceMotion ? 5 : 0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: amountText)
            // Keep the amount clear of the handoff button. The cost is an
            // overlay, so reserving that control slot does not reflow the row.
            .padding(.trailing, 38)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .allowsHitTesting(false)
            .accessibilityHidden(amountText == nil)
            .accessibilityLabel(amountText.map { "Estimated API cost: \($0)" } ?? "")
            .accessibilityIdentifier(AccessibilityID.sessionRowCost(session.id))
            .task(id: isHovered) {
                guard isHovered, let source = source() else {
                    visibleEstimate = nil
                    return
                }
                visibleEstimate = nil
                let result = await estimate(source)
                guard !Task.isCancelled, isHovered else { return }
                onEstimate(result)
                guard case .complete = result else { return }
                visibleEstimate = result
                try? await Task.sleep(for: Self.visibleDuration)
                guard !Task.isCancelled, isHovered else { return }
                visibleEstimate = nil
            }
    }
}

struct JumpKeyBadge: View {
    let label: String
    let provider: CodingAgentProvider?
    let costTier: SessionCostTier

    private var tint: Color {
        provider?.brandTint ?? .secondary
    }

    private var badgeTint: Color {
        switch costTier {
        case .standard: return tint
        case .expensive: return Color.linearHex("C99A3B")
        case .critical: return .red
        }
    }

    private var isWarning: Bool {
        costTier != .standard
    }

    private var warningHelp: String {
        switch costTier {
        case .standard: return ""
        case .expensive: return "High estimated API cost — hover for the amount"
        case .critical: return "Very high estimated API cost — hover for the amount"
        }
    }

    private var accessibilityDescription: String {
        switch costTier {
        case .standard: return "Session shortcut \(label)"
        case .expensive: return "High estimated API cost. Session shortcut \(label)"
        case .critical: return "Very high estimated API cost. Session shortcut \(label)"
        }
    }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(isWarning ? Color.primary : tint)
            .frame(width: Self.badgeWidth(for: label), height: 16)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(badgeTint.opacity(isWarning ? 0.18 : 0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(
                                badgeTint.opacity(isWarning ? 0.55 : 0.32),
                                lineWidth: 0.5
                            )
                    )
            )
            .opacity(label.isEmpty ? 0 : 1)
            .help(warningHelp)
            .accessibilityHidden(label.isEmpty)
            .accessibilityLabel(accessibilityDescription)
    }

    private static func badgeWidth(for label: String) -> CGFloat {
        CGFloat(12 + 6 * max(label.count, 1))
    }
}
