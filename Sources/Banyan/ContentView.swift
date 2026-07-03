import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var showingAddSession = false
    @State private var showingPreferences = false
    @State private var editingSession: BanyanSession?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.forkSelectedSession()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier(AccessibilityID.toolbarAddSession)
                .help("Fork selected directory")

                Button {
                    showingPreferences = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityIdentifier(AccessibilityID.toolbarPreferences)
                .help("Preferences")
            }
        }
        .sheet(isPresented: $showingAddSession) {
            AddSessionSheet()
                .environmentObject(store)
        }
        .sheet(isPresented: $showingPreferences) {
            PreferencesSheet()
                .environmentObject(store)
        }
        .sheet(item: $editingSession) { session in
            EditSessionSheet(session: session)
        }
        .onAppear {
            store.loadPersistedSessionsIfNeeded()
            store.startControlServer()
            if store.visibleSessions.isEmpty {
                store.spawn(title: "Shell", cwd: NSHomeDirectory())
            }
        }
        .accessibilityIdentifier(AccessibilityID.root)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $store.selectedSessionID) {
                ForEach(store.visibleSessions) { session in
                    SessionRow(session: session, isSelected: store.selectedSessionID == session.id)
                        .tag(session.id)
                        .contextMenu {
                            Button("Edit") {
                                editingSession = session
                            }
                            Divider()
                            Button("Close") {
                                try? store.close(id: session.id)
                            }
                            Button("Remove") {
                                try? store.remove(id: session.id)
                            }
                        }
                }
            }
            .listStyle(.sidebar)
            .accessibilityIdentifier(AccessibilityID.sidebarList)

            HStack {
                Button {
                    store.forkSelectedSession()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier(AccessibilityID.sidebarAddSession)
                .help("Fork selected directory")

                Menu {
                    Button("Custom Session...") {
                        showingAddSession = true
                    }
                    Divider()
                    Picker("Sort", selection: $store.sortMode) {
                        ForEach(SortMode.allCases) { sortMode in
                            Text(sortMode.label).tag(sortMode)
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton)
                .accessibilityIdentifier(AccessibilityID.sidebarOptions)
                .help("Sidebar options")

                Spacer()

                if let selected = store.selectedSession {
                    Button {
                        editingSession = selected
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier(AccessibilityID.sidebarEditSelected)
                    .help("Edit selected session")

                    Button {
                        try? store.close(id: selected.id)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityIdentifier(AccessibilityID.sidebarCloseSelected)
                    .help("Close selected session")
                }
            }
            .buttonStyle(.borderless)
            .padding(12)
            .accessibilityIdentifier(AccessibilityID.sidebarFooter)
        }
        .accessibilityIdentifier(AccessibilityID.sidebar)
    }

    @ViewBuilder
    private var detail: some View {
        if let session = store.selectedSession {
            VStack(spacing: 0) {
                TerminalHeader(session: session)
                Divider()
                TerminalHostView(
                    session: session,
                    theme: store.terminalTheme,
                    fontFamily: store.terminalFontFamily,
                    fontSize: store.terminalFontSize
                )
                    .id(session.id)
                    .ignoresSafeArea(edges: .bottom)
            }
            .accessibilityIdentifier(AccessibilityID.detail)
        } else {
            ContentUnavailableView(
                "No Session Selected",
                systemImage: "terminal",
                description: Text("Spawn a session from the toolbar or with banyanctl.")
            )
            .accessibilityIdentifier(AccessibilityID.emptyDetail)
        }
    }
}

private struct SessionRow: View {
    @ObservedObject var session: BanyanSession
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(nsColor: session.tone.nsColor))
                .frame(width: isSelected ? 9 : 7, height: isSelected ? 9 : 7)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayTitle)
                    .font(.system(size: isSelected ? 13 : 12.5, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .accessibilityIdentifier(AccessibilityID.sessionRowTitle(session.id))

                HStack(spacing: 6) {
                    Image(systemName: session.status.systemImage)
                    Text(session.isRestored ? "Restorable" : session.status.label)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityIdentifier(AccessibilityID.sessionRowStatus(session.id))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, isSelected ? 5 : 3)
        .padding(.horizontal, 8)
        .background(rowBackground)
        .accessibilityIdentifier(AccessibilityID.sessionRow(session.id))
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 6)
                .fill(session.tone.backgroundColor)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: session.tone.nsColor).opacity(0.18), lineWidth: 1)
                }
        } else {
            Color.clear
        }
    }
}

private struct TerminalHeader: View {
    @EnvironmentObject private var store: SessionStore
    @ObservedObject var session: BanyanSession

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.status.systemImage)
                .foregroundStyle(Color(nsColor: session.tone.nsColor))
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle)
                    .font(.headline)
                    .accessibilityIdentifier(AccessibilityID.terminalHeaderTitle)
                Text(session.cwd)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier(AccessibilityID.terminalHeaderDirectory)
            }
            Spacer()
            Text(session.command.isEmpty ? "shell" : session.command)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityIdentifier(AccessibilityID.terminalHeaderCommand)
            if session.isRestored || !session.isProcessStarted {
                Button {
                    try? store.respawn(id: session.id)
                } label: {
                    Label("Attach", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier(AccessibilityID.terminalAttachButton)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .accessibilityIdentifier(AccessibilityID.terminalHeader)
    }
}
