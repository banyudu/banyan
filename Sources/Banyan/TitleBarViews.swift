import AppKit
import BanyanCore
import Combine
import SwiftUI
import UniformTypeIdentifiers


extension SessionContextInfo {
    var hasTitlebarContent: Bool {
        let hasLinearTitle = linearIssueID?.isEmpty == false
            && linearIssueTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return hasLinearTitle
    }
}

struct TitleBarContextView: View {
    let context: SessionContextInfo
    let onOpenLinear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let issueID = context.linearIssueID,
               let linearIssueTitle = sanitizedLinearIssueTitle {
                TitleBarContextButton(
                    accessibilityIdentifier: AccessibilityID.toolbarLinearLink,
                    systemImage: "list.bullet.rectangle",
                    primary: issueID,
                    secondary: linearIssueTitle,
                    help: "Open Linear issue (Cmd-L)",
                    isEnabled: true,
                    action: onOpenLinear
                )
            }
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 10)
        .lineLimit(1)
        .accessibilityIdentifier(AccessibilityID.toolbarContext)
    }

    private var sanitizedLinearIssueTitle: String? {
        let trimmed = context.linearIssueTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

/// Toolbar fallback for sessions with no bound Linear issue: show the session's
/// display title (first prompt for agent sessions) instead of leaving the
/// titlebar empty. Plain shells stay empty — only agent sessions get a label.
struct TitleBarSessionFallbackView: View {
    @ObservedObject var session: BanyanSession

    var body: some View {
        if session.agentProvider != nil, let title = fallbackTitle {
            HStack(spacing: 6) {
                if let provider = session.displayAgentProvider {
                    AgentProviderIcon(provider: provider, size: 14, showsPeakBadge: false)
                }
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // The toolbar pins flexible principal items at ~370px regardless of
            // maxWidth or ideal size, but honors an explicit width — so measure
            // the text (same 12pt system font) and demand exactly that.
            .frame(width: fittedWidth(for: title))
            .padding(.horizontal, 10)
            .lineLimit(1)
            .accessibilityIdentifier(AccessibilityID.toolbarSessionTitle)
        }
    }

    private func fittedWidth(for title: String) -> CGFloat {
        let textWidth = (title as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 12)]
        ).width
        let chrome: CGFloat = (session.displayAgentProvider != nil ? 14 + 6 : 0) + 20 + 8
        return min(max(textWidth + chrome, 140), 1100)
    }

    private var fallbackTitle: String? {
        let trimmed = session.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct TitleBarContextButton: View {
    let accessibilityIdentifier: String
    let systemImage: String
    let primary: String
    let secondary: String?
    let help: String
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(primary)
                    .font(.system(size: 12, weight: .semibold))
                    .underline(isEnabled && isHovered)
                if let secondary = sanitizedSecondary {
                    Text(secondary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.banyanPlainLabelOnly)
        .onHover { isHovered = isEnabled && $0 }
        .onDisappear { isHovered = false }
        .disabled(!isEnabled)
        .help(help)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var sanitizedSecondary: String? {
        let trimmed = secondary?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

}

struct TitleBarLogo: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 86, height: 28))
        container.identifier = NSUserInterfaceItemIdentifier(AccessibilityID.toolbarLogo)
        container.setAccessibilityElement(true)
        container.setAccessibilityLabel("Banyan")
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor

        let iconView = NSImageView(image: Self.logoImage)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(iconView)

        let label = NSTextField(labelWithString: "Banyan")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        container.addSubview(label)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 86),
            container.heightAnchor.constraint(equalToConstant: 28),
            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 7),
            iconView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8)
        ])

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let iconView = nsView.subviews.first as? NSImageView {
            iconView.image = Self.logoImage
        }
    }

    private static var logoImage: NSImage {
        if let url = Bundle.main.url(forResource: "Banyan", withExtension: "icns"),
           let bundled = NSImage(contentsOf: url) {
            return bundled
        }
        if let bundled = NSImage(named: "Banyan") {
            return bundled
        }
        return NSApp.applicationIconImage
    }
}

/// Moves the close alert's default action between buttons without changing
/// either button's action or enabled state.
struct DefaultActionModifier: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.keyboardShortcut(.defaultAction)
        } else {
            content
        }
    }
}

/// Applies the window restoration policy once the content is in a window.
struct WindowRestorationConfigurator: NSViewRepresentable {
    let shortcuts: SessionJumpShortcuts

    func makeNSView(context: Context) -> NSView {
        let view = WindowRestorationConfigurationView(frame: .zero)
        view.shortcuts = shortcuts
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window { shortcuts.register(window: window) }
    }
}

private final class WindowRestorationConfigurationView: NSView {
    weak var shortcuts: SessionJumpShortcuts?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        WindowRestorationPolicy.configure(window)
        shortcuts?.register(window: window)
    }
}
