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
                .help("Fork selected directory")

                Button {
                    showingPreferences = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
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
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $store.selectedSessionID) {
                ForEach(store.visibleSessions) { session in
                    SessionRow(session: session)
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

            HStack {
                Button {
                    store.forkSelectedSession()
                } label: {
                    Image(systemName: "plus")
                }
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
                .help("Sidebar options")

                Spacer()

                if let selected = store.selectedSession {
                    Button {
                        editingSession = selected
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .help("Edit selected session")

                    Button {
                        try? store.close(id: selected.id)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .help("Close selected session")
                }
            }
            .buttonStyle(.borderless)
            .padding(12)
        }
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
        } else {
            ContentUnavailableView(
                "No Session Selected",
                systemImage: "terminal",
                description: Text("Spawn a session from the toolbar or with banyanctl.")
            )
        }
    }
}

private struct SessionRow: View {
    @ObservedObject var session: BanyanSession

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(nsColor: session.tone.nsColor))
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Image(systemName: session.status.systemImage)
                    Text(session.isRestored ? "Restorable" : session.status.label)
                    if let reportedTitle = session.reportedTitle, !reportedTitle.isEmpty {
                        Text("·")
                        Text(reportedTitle)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(session.tone.backgroundColor, in: RoundedRectangle(cornerRadius: 6))
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
                Text(session.title)
                    .font(.headline)
                Text(session.cwd)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(session.command.isEmpty ? "shell" : session.command)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if session.isRestored || !session.isProcessStarted {
                Button {
                    try? store.respawn(id: session.id)
                } label: {
                    Label("Attach", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
