import AppKit
import BanyanCore
import Combine
import SwiftUI
import UniformTypeIdentifiers


struct SidebarDragSortModifier: ViewModifier {
    let sessionID: String
    let isEnabled: Bool
    @Binding var draggingSessionID: String?
    let canMove: (String, String, SidebarSessionDropZone) -> Bool
    let onMove: (String, String, SidebarSessionDropZone) -> Void
    @State private var rowHeight: CGFloat = 26
    @State private var dropZone: SidebarSessionDropZone?

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: SidebarRowHeightPreferenceKey.self,
                            value: proxy.size.height
                        )
                    }
                }
                .onPreferenceChange(SidebarRowHeightPreferenceKey.self) { height in
                    guard height > 0, abs(height - rowHeight) > 0.5 else { return }
                    rowHeight = height
                }
                .opacity(draggingSessionID == sessionID ? 0.55 : 1)
                .onDrag {
                    draggingSessionID = sessionID
                    let provider = NSItemProvider()
                    provider.registerDataRepresentation(
                        forTypeIdentifier: SidebarSessionDrag.type.identifier,
                        visibility: .ownProcess
                    ) { completion in
                        completion(Data(sessionID.utf8), nil)
                        return nil
                    }
                    return provider
                }
                .onDrop(
                    of: [SidebarSessionDrag.type],
                    delegate: SidebarSessionDropDelegate(
                        targetSessionID: sessionID,
                        rowHeight: rowHeight,
                        draggingSessionID: $draggingSessionID,
                        dropZone: $dropZone,
                        canMove: canMove,
                        onMove: onMove
                    )
                )
                .overlay(alignment: .top) {
                    if dropZone == .before {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(height: 2)
                            .offset(y: -1)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottom) {
                    if dropZone == .after {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(height: 2)
                            .offset(y: 1)
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    if dropZone == .child {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 1.5)
                            .padding(.horizontal, 1)
                            .allowsHitTesting(false)
                    }
                }
                .animation(.easeOut(duration: 0.08), value: dropZone)
        } else {
            content
        }
    }
}

enum SidebarSessionDropZone: Equatable {
    case before
    case child
    case after

    func command(targetID: String) -> SessionSidebarMoveCommand {
        switch self {
        case .before: return .before(targetID)
        case .child: return .child(targetID)
        case .after: return .after(targetID)
        }
    }
}

private struct SidebarSessionDropDelegate: DropDelegate {
    let targetSessionID: String
    let rowHeight: CGFloat
    @Binding var draggingSessionID: String?
    @Binding var dropZone: SidebarSessionDropZone?
    let canMove: (String, String, SidebarSessionDropZone) -> Bool
    let onMove: (String, String, SidebarSessionDropZone) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        draggingSessionID != nil && info.hasItemsConforming(to: [SidebarSessionDrag.type])
    }

    func dropEntered(info: DropInfo) {
        guard let zone = resolvedZone(for: info) else {
            dropZone = nil
            return
        }
        dropZone = zone
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let zone = resolvedZone(for: info) else {
            dropZone = nil
            return DropProposal(operation: .forbidden)
        }
        dropZone = zone
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        dropZone = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggingSessionID else { return false }
        defer {
            self.draggingSessionID = nil
            dropZone = nil
        }
        guard let zone = resolvedZone(for: info) else { return false }
        onMove(draggingSessionID, targetSessionID, zone)
        return true
    }

    private func resolvedZone(for info: DropInfo) -> SidebarSessionDropZone? {
        guard let draggingSessionID, draggingSessionID != targetSessionID else { return nil }
        let zone = dropZone(at: info.location.y)
        guard canMove(draggingSessionID, targetSessionID, zone) else { return nil }
        return zone
    }

    private func dropZone(at y: CGFloat) -> SidebarSessionDropZone {
        let edge = max(6, rowHeight * 0.28)
        if y < edge { return .before }
        if y > rowHeight - edge { return .after }
        return .child
    }
}

private enum SidebarSessionDrag {
    static let type = UTType(exportedAs: "dev.banyudu.banyan.sidebar-session")
}

private struct SidebarRowHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
