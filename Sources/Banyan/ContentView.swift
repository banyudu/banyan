import AppKit
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
            ToolbarItem(placement: .navigation) {
                TitleBarLogo()
            }
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
        .background(WindowTitleConfigurator())
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

private struct TitleBarLogo: NSViewRepresentable {
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

private struct WindowTitleConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        TitlebarConfigurationView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            Self.configure(window: nsView.window)
        }
    }

    fileprivate static func configure(window: NSWindow?) {
        guard let window else { return }
        window.title = ""
    }
}

private final class TitlebarConfigurationView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            WindowTitleConfigurator.configure(window: self?.window)
        }
    }
}

private struct SessionRow: View {
    @ObservedObject var session: BanyanSession
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(nsColor: session.tone.nsColor))
                .frame(width: isSelected ? 9 : 7, height: isSelected ? 9 : 7)

            Text(session.displayTitle)
                .font(.system(size: isSelected ? 13 : 12.5, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier(AccessibilityID.sessionRowTitle(session.id))

            Spacer(minLength: 0)

            Image(systemName: sessionStatusIcon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 14, height: 14)
                .accessibilityLabel(session.isRestored ? "Restorable" : session.status.label)
                .accessibilityIdentifier(AccessibilityID.sessionRowStatus(session.id))
        }
        .padding(.vertical, isSelected ? 5 : 4)
        .padding(.horizontal, 8)
        .background(rowBackground)
        .accessibilityIdentifier(AccessibilityID.sessionRow(session.id))
    }

    private var sessionStatusIcon: String {
        session.isRestored ? "arrow.clockwise.circle.fill" : session.status.systemImage
    }

    private var statusColor: Color {
        switch session.status {
        case .failed:
            return .red
        case .needInput:
            return .yellow
        case .review:
            return .purple
        case .completed:
            return .green
        case .running, .closed:
            return .secondary
        }
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
