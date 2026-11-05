import AppKit
import BanyanCore
import Combine
import SwiftUI
import UniformTypeIdentifiers


struct PendingHandoffJobsView: View {
    let jobs: [HandoffJob]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Handoff")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            ForEach(jobs) { job in
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                        .frame(width: 16, height: 16)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(job.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text("Dispatching")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityIdentifier(AccessibilityID.sidebarPendingHandoffJobs)
    }
}

struct RecoverySessionsView: View {
    let count: Int
    let onRecover: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.clockwise.circle")
                .foregroundStyle(.orange)
            Text(count == 1 ? "1 session needs recovery" : "\(count) sessions need recovery")
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Recover All", action: onRecover)
                .buttonStyle(.banyanBorderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityIdentifier("banyan.sidebar.recovery")
    }
}

/// Reports the last palette command the app ran.
///
/// This is the visible half of the fix for "the Review command did nothing":
/// background commands write their output to a log rather than a terminal, so
/// without this the only signal was a session appearing (or not) some seconds
/// later. Failures keep the command's own last line and the log location on
/// screen until dismissed.
struct PaletteCommandRunBanner: View {
    let run: PaletteCommandRun
    let onRevealLog: () -> Void
    let onDismiss: () -> Void

    @State private var isOutputExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statusIcon
                    .frame(width: 16, height: 16)

                Text(run.headline)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)

                Spacer(minLength: 4)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.banyanPlain)
                .accessibilityIdentifier(AccessibilityID.sidebarPaletteCommandRunDismiss)
                .help("Dismiss")
            }

            if !run.command.isEmpty {
                Text(run.command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            if let detail = run.failureDetail, !isOutputExpanded {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if isOutputExpanded {
                ScrollView {
                    Text(run.outputTail)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .padding(6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier(AccessibilityID.sidebarPaletteCommandRunOutput)
            }

            HStack(spacing: 6) {
                if run.hasOutput {
                    Button(isOutputExpanded ? "Hide Output" : "Show Output") {
                        isOutputExpanded.toggle()
                    }
                    .accessibilityIdentifier(AccessibilityID.sidebarPaletteCommandRunToggleOutput)
                }
                if run.logURL != nil {
                    Button("Reveal Log", action: onRevealLog)
                        .accessibilityIdentifier(AccessibilityID.sidebarPaletteCommandRunRevealLog)
                }
                if run.isOutputTruncated {
                    Text("earlier output trimmed")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(.banyanBordered)
            .controlSize(.small)
            .font(.system(size: 11))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(AccessibilityID.sidebarPaletteCommandRun)
        // The countdown lives here rather than in the store so it can see the
        // output panel: a success that the user has opened up to read is a
        // success they are still using, and it waits. Keying on the run and the
        // armed flag together restarts the countdown when a run settles, and
        // cancels it the moment the banner goes away.
        .task(id: AutoDismissKey(runID: run.id, isArmed: isAutoDismissArmed)) {
            guard isAutoDismissArmed else { return }
            try? await Task.sleep(nanoseconds: UInt64(PaletteCommandRun.autoDismissDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            onDismiss()
        }
    }

    /// A settled success clears itself, unless the user has expanded its output.
    private var isAutoDismissArmed: Bool {
        run.autoDismisses && !isOutputExpanded
    }

    /// Restarting the countdown needs both halves: the run it belongs to, and
    /// whether it is armed at all.
    private struct AutoDismissKey: Equatable {
        let runID: UUID
        let isArmed: Bool
    }

    @ViewBuilder
    private var statusIcon: some View {
        if run.isRunning {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.65)
        } else if run.isFailure {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }
}
