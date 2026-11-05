import AppKit
import BanyanCore
import Combine
import SwiftUI
import UniformTypeIdentifiers

extension ContentView {
    var addSessionDraftBinding: Binding<AddSessionDraft?> {
        Binding {
            store.addSessionDraft
        } set: { draft in
            store.addSessionDraft = draft
        }
    }

    var closeConfirmationBinding: Binding<Bool> {
        Binding {
            store.pendingCloseSession != nil
        } set: { isPresented in
            if !isPresented {
                store.cancelPendingClose()
            }
        }
    }

    @ViewBuilder
    var closeConfirmationButtons: some View {
        let availability = closeConfirmationAvailability
        Button("Cancel", role: .cancel) {}
        if let session = store.pendingCloseSession, store.canHideAndKeepWorking(session) {
            Button("Keep Working in Background") { store.confirmPendingHideAndKeepWorking() }
                .modifier(DefaultActionModifier(enabled: availability.backgroundIsDefault))
        }
        if store.pendingCloseCanPause {
            Button("Pause and Close", role: .destructive) {
                store.confirmPendingPauseAndClose()
            }
            .disabled(availability.primaryCloseDisabled)
            .modifier(DefaultActionModifier(enabled: availability.primaryCloseIsDefault))
        }
        if store.pendingCloseNeedsForce {
            Button(closeConfirmationAction, role: .destructive) {
                store.confirmPendingForceClose()
            }
            .disabled(availability.forceCloseDisabled)
            .modifier(DefaultActionModifier(enabled: availability.forceCloseIsDefault))
        } else if !store.pendingCloseCanPause {
            Button(closeConfirmationAction, role: .destructive) {
                store.confirmPendingClose()
            }
            .disabled(availability.primaryCloseDisabled)
            .modifier(DefaultActionModifier(enabled: availability.primaryCloseIsDefault))
        }
    }

    var handoffNoticeBinding: Binding<Bool> {
        Binding(
            get: { store.handoffNotice != nil },
            set: { isPresented in
                if !isPresented {
                    store.handoffNotice = nil
                }
            }
        )
    }

    private var closeConfirmationAction: String {
        if store.pendingCloseNeedsForce, commandModifierHeld {
            return store.pendingCloseSession?.closeEndsAgentWork == false ? "Force Close" : "Force Close and Kill"
        }
        return store.pendingCloseSession?.closeEndsAgentWork == false ? "Close" : "Close and Kill"
    }

    private var closeConfirmationAvailability: CloseConfirmationActionAvailability {
        CloseConfirmationActionAvailability(
            isPausing: store.pendingCloseIsPausing,
            canPause: store.pendingCloseCanPause,
            needsForce: store.pendingCloseNeedsForce,
            commandHeld: commandModifierHeld
        )
    }

    var puckSessionErrorBinding: Binding<Bool> {
        Binding(
            get: { store.puckSessionError != nil },
            set: { isPresented in
                if !isPresented {
                    store.puckSessionError = nil
                }
            }
        )
    }

    var closeConfirmationTitle: String {
        if store.pendingCloseHasOngoingAgent {
            return "Close running agent?"
        }
        if store.pendingCloseHasActiveChildren {
            return "Close parent session?"
        }
        return "Close session?"
    }

    var selectedPullRequestHelp: String {
        guard let context = store.selectedContextInfo else {
            return "Preview GitHub pull request"
        }
        if let number = context.pullRequestNumber {
            return "Preview GitHub pull request #\(number)"
        }
        if let title = context.pullRequestTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return "Preview GitHub pull request: \(title)"
        }
        return "Preview GitHub pull request"
    }

    @ViewBuilder
    var detail: some View {
        switch store.sidebarMode {
        case .sessions, .work:
            sessionDetail
        case .linear:
            linearDetail
        }
    }

    @ViewBuilder
    private var sessionDetail: some View {
        HStack(spacing: 0) {
            ZStack {
                SelectionAwareTerminalSwitcher(
                    selection: selection,
                    sessions: store.visibleTerminalSessions,
                    theme: store.terminalTheme,
                    fontFamily: store.terminalFontFamily,
                    fontSize: store.terminalFontSize,
                    focusRequestID: store.terminalFocusRequestID,
                    switchRequestedAt: store.sessionSwitchRequestedAt,
                    onTerminalSlashCommand: { terminal, command in
                        _ = store.runTerminalSlashCommand(command, from: terminal)
                    }
                )
                .ignoresSafeArea(edges: .bottom)

                if let session = store.selectedSession {
                    SessionDetailOverlay(session: session)
                } else {
                    ContentUnavailableView(
                        "No Session Selected",
                        systemImage: "terminal",
                        description: Text("Spawn a session from the toolbar or with banyanctl.")
                    )
                    .accessibilityIdentifier(AccessibilityID.emptyDetail)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let session = store.selectedSession { AgentAdmissionBanner(session: session, store: store) }
            }
            // SwiftTerm owns a Metal-backed surface. During restoration SwiftUI
            // can briefly propose the panel's fixed width before it proposes the
            // remaining detail width; never collapse that surface to a sliver.
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)

            if let session = store.selectedSession {
                if store.isPullRequestPreviewPresented,
                   let context = store.selectedPullRequestPreviewContext,
                   session.status != .closed {
                    issuePreviewPanel {
                        PullRequestPreviewPanel(
                            context: context,
                            details: store.selectedPullRequestDetails,
                            loadState: store.selectedPullRequestLoadState,
                            onRefresh: {
                                store.refreshSelectedPullRequestPreview(force: true)
                            },
                            onOpen: store.openSelectedPullRequest,
                            onClose: store.closePullRequestPreview
                        )
                    }
                } else if let context = store.selectedContextInfo,
                          context.githubIssueURL?.isEmpty == false,
                          session.status != .closed {
                    issuePreviewPanel {
                        GitHubIssuePanel(
                            context: context,
                            issue: store.selectedGitHubIssueDetails,
                            loadState: store.selectedGitHubIssueLoadState,
                            onRefresh: { store.refreshSelectedGitHubIssue(force: true) },
                            onOpen: store.openSelectedGitHubIssue
                        )
                    }
                } else if let context = store.selectedContextInfo,
                          context.linearIssueID?.isEmpty == false,
                          session.status != .closed {
                    issuePreviewPanel {
                        LinearIssuePanel(
                            context: context,
                            issue: store.selectedLinearIssueDetails,
                            loadState: store.selectedLinearIssueLoadState,
                            onRefresh: {
                                store.refreshSelectedLinearIssue(force: true)
                            },
                            onOpen: store.openSelectedLinearIssue,
                            onChangeState: store.updateSelectedLinearIssueState,
                            onToggleTask: store.updateSelectedLinearIssueDescription,
                            onRetryDescription: store.retrySelectedLinearIssueDescription
                        )
                    }
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.detail)
    }

    @ViewBuilder
    private func issuePreviewPanel<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 0) {
            Divider()
            content()
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(
                    color: .black.opacity(0.14),
                    radius: 12,
                    x: -4,
                    y: 0
                )
                .padding(.vertical, 10)
                .padding(.leading, 10)
                .padding(.trailing, 10)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.background)
    }

    @ViewBuilder
    private var linearDetail: some View {
        Group {
            if let context = store.selectedLinearListIssueContext {
                LinearIssuePanel(
                    context: context,
                    issue: store.selectedLinearListIssueDetails,
                    loadState: store.selectedLinearListIssueLoadState,
                    onRefresh: {
                        store.refreshSelectedLinearListIssue(force: true)
                    },
                    onOpen: store.openSelectedLinearListIssue,
                    onChangeState: store.updateSelectedLinearListIssueState,
                    onToggleTask: store.updateSelectedLinearListIssueDescription,
                    onRetryDescription: store.retrySelectedLinearListIssueDescription,
                    onStart: store.startSelectedLinearListIssueSession,
                    isStarting: store.linearIssueListLoadState.isStarting,
                    presentation: .main
                )
            } else {
                ContentUnavailableView(
                    "No Linear Issue Selected",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Select an issue from the Linear sidebar.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            store.refreshLinearIssueListIfNeeded()
            store.refreshSelectedLinearListIssue(force: true)
        }
        .accessibilityIdentifier(AccessibilityID.detail)
    }
}
