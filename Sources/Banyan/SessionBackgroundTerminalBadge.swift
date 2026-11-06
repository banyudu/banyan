import SwiftUI

struct SessionBackgroundTerminalBadge: View {
    let count: Int
    let label: String

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "terminal")
            Text("\(count)").monospacedDigit()
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .frame(height: 16)
        .background(.quaternary, in: Capsule())
        .help(label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}
