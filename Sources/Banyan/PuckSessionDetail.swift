import BanyanCore
import SwiftUI

/// The detail pane of a `PuckSession`: the daemon's transcript, its pending
/// approval or question, and a message field. The session follows its event
/// stream only while this pane is on screen; a shared daemon watch keeps the
/// sidebar current and reports human activity.
struct PuckSessionDetail: View {
    @EnvironmentObject private var store: SessionStore
    @ObservedObject var session: PuckSession
    @State private var isFollowingLatest = true
    @State private var composerFocusRequest = 0

    private let transcriptEndID = "puck-transcript-end"

    private var transcriptTypography: PuckTranscriptTypography {
        PuckTranscriptTypography(
            fontFamily: store.terminalFontFamily,
            fontSize: store.terminalFontSize
        )
    }

    /// An ask takes the keyboard only when the composer is empty, so a key
    /// meant for a half-typed message cannot answer it.
    private var askTakesFocus: Bool {
        session.draft.isEmpty
    }

    var body: some View {
        let timeline = session.timeline
        VStack(alignment: .leading, spacing: 0) {
            if let notice = session.infoNotice {
                noticeBanner(notice)
                Divider()
            }
            transcript(timeline)
            if let pending = session.pendingApproval, !session.decisionInFlight {
                Divider()
                PuckApprovalPanel(
                    session: session,
                    pending: pending,
                    typography: transcriptTypography,
                    takesFocus: askTakesFocus
                )
                .id(pending.callID)
            }
            if let pending = session.pendingQuestion, !session.answerInFlight {
                Divider()
                PuckQuestionPanel(
                    session: session,
                    pending: pending,
                    plan: session.questionPlan,
                    typography: transcriptTypography,
                    takesFocus: askTakesFocus
                )
                .id(pending.callID)
            }
            Divider()
            PuckComposer(session: session, typography: transcriptTypography, focusRequest: composerFocusRequest)
            Divider()
            footer
        }
        .sessionLinks(context: session.linkContext)
        .onAppear {
            session.startFollowing()
            composerFocusRequest += 1
        }
        .onDisappear {
            session.stopFollowing()
        }
        // The shortcut that focuses a terminal pane focuses this pane's input.
        .onChange(of: store.terminalFocusRequestID) { _, _ in
            composerFocusRequest += 1
        }
        // Answering an ask hands the keyboard back to the composer.
        .onChange(of: session.pendingApproval == nil && session.pendingQuestion == nil) { _, settled in
            if settled { composerFocusRequest += 1 }
        }
        .accessibilityIdentifier(AccessibilityID.puckSessionDetail)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(runtimeSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            PuckTurnStatusBadge(phase: session.turnPhase)
            if session.turnPhase.isTurnActive {
                Button {
                    session.cancel()
                } label: {
                    Label(
                        session.cancelInFlight ? "Stopping…" : "Stop",
                        systemImage: session.cancelInFlight ? "hourglass" : "stop.circle"
                    )
                }
                .buttonStyle(.banyanBordered)
                .controlSize(.small)
                .disabled(!session.canCancelTurn)
                .help("Stop this turn without closing the session or its history")
                .accessibilityIdentifier(AccessibilityID.puckStopTurn)
            }
            switch session.followState {
            case .connecting:
                ProgressView()
                    .controlSize(.small)
                    .help("Attaching to puckd")
            case .lost:
                Button {
                    session.startFollowing()
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.banyanBorderedProminent)
                .controlSize(.small)
                .help("Attach to this session in puckd again")
            case .following, .stopped:
                EmptyView()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    /// Who runs the session, e.g. "Puck · codex · gpt-5.5 · default".
    private var runtimeSummary: String {
        let binding = session.binding
        return ["Puck", binding.provider, binding.model, binding.account]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func transcript(_ timeline: PuckTimeline) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if session.nextHistoryCursor != nil {
                        HStack {
                            Spacer()
                            Button {
                                isFollowingLatest = false
                                session.loadOlderHistory()
                            } label: {
                                if session.historyLoading {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Label("Load earlier messages", systemImage: "clock.arrow.circlepath")
                                }
                            }
                            .buttonStyle(.banyanBorderless)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .disabled(session.historyLoading)
                            .accessibilityIdentifier(AccessibilityID.puckLoadOlderMessages)
                            Spacer()
                        }
                    }
                    PuckTimelineRows(items: timeline.items, typography: transcriptTypography)
                    if !timeline.notices.isEmpty {
                        PuckTimelineNotices(
                            notices: timeline.notices,
                            typography: transcriptTypography
                        )
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(transcriptEndID)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    PuckTranscriptScrollObserver { following in
                        isFollowingLatest = following
                    }
                }
            }
            .scrollIndicators(.hidden)
            .hidesVerticalScroller()
            .accessibilityIdentifier(AccessibilityID.puckTimeline)
            .overlay {
                if timeline.items.isEmpty && timeline.notices.isEmpty {
                    emptyTranscript
                }
            }
            .overlay(alignment: .bottom) {
                if !isFollowingLatest && !timeline.items.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) {
                            isFollowingLatest = true
                            proxy.scrollTo(transcriptEndID, anchor: .bottom)
                        }
                        if !session.historyItems.isEmpty {
                            session.loadLatestHistory()
                        }
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down")
                    }
                    .buttonStyle(.banyanBordered)
                    .controlSize(.small)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityIdentifier(AccessibilityID.puckLatestMessages)
                }
            }
            .onAppear {
                isFollowingLatest = true
            }
            .task(id: timeline) {
                guard isFollowingLatest, !timeline.items.isEmpty || !timeline.notices.isEmpty else { return }
                // Streaming can change the timeline several times in one frame.
                // Let layout settle, cancelling obsolete requests instead of
                // queuing onChange animations that reenter scroll layout.
                await Task.yield()
                guard !Task.isCancelled, isFollowingLatest else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(transcriptEndID, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func noticeBanner(_ notice: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label {
                Text(notice)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            Spacer(minLength: 8)
            Button {
                session.infoNotice = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.banyanBorderless)
            .help("Dismiss")
            .accessibilityLabel("Dismiss notice")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .accessibilityIdentifier(AccessibilityID.puckCancellationNotice)
    }

    @ViewBuilder
    private var emptyTranscript: some View {
        switch session.followState {
        case .connecting:
            ProgressView("Attaching…")
        case .lost:
            ContentUnavailableView(
                "Disconnected from puckd",
                systemImage: "bolt.horizontal.circle",
                description: Text("The session is still in puckd. Reconnect to follow it again.")
            )
        case .following, .stopped:
            ContentUnavailableView(
                "No Messages Yet",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Send a message to start the first turn.")
            )
        }
    }
}
