import BanyanCore
import SwiftUI

struct CodexRetryBanner: View {
    @ObservedObject var session: BanyanSession

    var body: some View {
        if let status = session.codexRetryStatus {
            HStack(spacing: 12) {
                Image(systemName: "arrow.clockwise")
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        if status.isExhausted {
                            Text("Automatic retries stopped after four attempts")
                        } else if let date = status.retryAt {
                            Text("Retrying in")
                            Text(date, style: .relative).monospacedDigit()
                            Text("· \(status.attempt)/4")
                        } else {
                            Text("Retrying · \(status.attempt)/4")
                        }
                    }
                    Text(status.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button(status.isExhausted ? "Dismiss" : "Cancel Retry") { session.codexAutoRetry.cancel() }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
            .accessibilityIdentifier("banyan.codex.auto-retry")
        }
    }
}
