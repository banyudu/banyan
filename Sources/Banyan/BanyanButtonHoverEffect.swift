import AppKit
import SwiftUI

enum BanyanButtonHoverStyle {
    case standard
    case labelOnly
}

struct BanyanDefaultButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DefaultButtonStyle()
            .makeBody(configuration: configuration)
            .banyanButtonHoverEffect()
    }
}

struct BanyanBorderlessButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BorderlessButtonStyle()
            .makeBody(configuration: configuration)
            .banyanButtonHoverEffect()
    }
}

struct BanyanBorderedButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BorderedButtonStyle()
            .makeBody(configuration: configuration)
            .banyanButtonHoverEffect()
    }
}

struct BanyanBorderedProminentButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BorderedProminentButtonStyle()
            .makeBody(configuration: configuration)
            .banyanButtonHoverEffect()
    }
}

struct BanyanPlainButtonStyle: PrimitiveButtonStyle {
    let hoverStyle: BanyanButtonHoverStyle

    func makeBody(configuration: Configuration) -> some View {
        PlainButtonStyle()
            .makeBody(configuration: configuration)
            .banyanButtonHoverEffect(hoverStyle)
    }
}

struct BanyanButtonHoverEffect: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    @State private var hasPushedCursor = false

    let style: BanyanButtonHoverStyle
    let onHoverChanged: ((Bool) -> Void)?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(hoverBackground)
            .scaleEffect(isActive ? 1.025 : 1)
            .animation(.easeOut(duration: 0.12), value: isActive)
            .onHover(perform: setHovered)
            .onChange(of: isEnabled) { _, enabled in
                if !enabled {
                    setHovered(false)
                }
            }
            .onDisappear(perform: resetHover)
    }

    @ViewBuilder
    private var hoverBackground: some View {
        if isActive, style == .standard {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .padding(-4)
        }
    }

    private var isActive: Bool {
        isEnabled && isHovered
    }

    private func setHovered(_ hovered: Bool) {
        let nextValue = hovered && isEnabled
        guard isHovered != nextValue else { return }

        isHovered = nextValue
        onHoverChanged?(nextValue)

        if nextValue, !hasPushedCursor {
            NSCursor.pointingHand.push()
            hasPushedCursor = true
        } else if !nextValue, hasPushedCursor {
            NSCursor.pop()
            hasPushedCursor = false
        }
    }

    private func resetHover() {
        guard isHovered || hasPushedCursor else { return }
        isHovered = false
        onHoverChanged?(false)
        if hasPushedCursor {
            NSCursor.pop()
            hasPushedCursor = false
        }
    }
}

extension View {
    func banyanButtonHoverEffect(
        _ style: BanyanButtonHoverStyle = .standard,
        onHoverChanged: ((Bool) -> Void)? = nil
    ) -> some View {
        modifier(BanyanButtonHoverEffect(style: style, onHoverChanged: onHoverChanged))
    }
}

extension PrimitiveButtonStyle where Self == BanyanDefaultButtonStyle {
    static var banyanDefault: Self {
        BanyanDefaultButtonStyle()
    }
}

extension PrimitiveButtonStyle where Self == BanyanBorderlessButtonStyle {
    static var banyanBorderless: Self {
        BanyanBorderlessButtonStyle()
    }
}

extension PrimitiveButtonStyle where Self == BanyanBorderedButtonStyle {
    static var banyanBordered: Self {
        BanyanBorderedButtonStyle()
    }
}

extension PrimitiveButtonStyle where Self == BanyanBorderedProminentButtonStyle {
    static var banyanBorderedProminent: Self {
        BanyanBorderedProminentButtonStyle()
    }
}

extension PrimitiveButtonStyle where Self == BanyanPlainButtonStyle {
    static var banyanPlain: Self {
        BanyanPlainButtonStyle(hoverStyle: .standard)
    }

    static var banyanPlainLabelOnly: Self {
        BanyanPlainButtonStyle(hoverStyle: .labelOnly)
    }
}
