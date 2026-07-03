import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var showingAddSession = false
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
                Picker("Theme", selection: $store.terminalTheme) {
                    ForEach(TerminalTheme.allCases) { theme in
                        Text(theme.label).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 190)

                Picker("Sort", selection: $store.sortMode) {
                    ForEach(SortMode.allCases) { sortMode in
                        Text(sortMode.label).tag(sortMode)
                    }
                }
                .frame(width: 130)

                Button {
                    showingAddSession = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Spawn session")
            }
        }
        .sheet(isPresented: $showingAddSession) {
            AddSessionSheet()
                .environmentObject(store)
        }
        .sheet(item: $editingSession) { session in
            EditSessionSheet(session: session)
        }
        .onAppear {
            store.startControlServer()
            if store.sessions.isEmpty {
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
                            ForEach(SessionStatus.allCases.filter { $0 != .closed }) { status in
                                Button(status.label) {
                                    session.mark(status: status)
                                }
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
                    showingAddSession = true
                } label: {
                    Label("Add", systemImage: "plus")
                }

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
                TerminalHostView(session: session, theme: store.terminalTheme)
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
                    Text(session.status.label)
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
