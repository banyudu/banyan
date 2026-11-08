import AppKit
import SwiftUI

/// Keys the Puck composer handles before the text view does.
enum PuckComposerKey {
    case submit
    case escape
    case tab
    case upArrow
    case downArrow
}

/// The Puck message field. SwiftUI's `TextField` cannot take an image
/// paste or a file drop, and cannot insert a newline at the caret, so the
/// field is an `NSTextView`: Return sends, Shift/Option-Return inserts a
/// newline, and pasted or dropped images become attachments.
struct PuckComposerTextView: NSViewRepresentable {
    @Binding var text: String
    /// The current text as a plain value, so SwiftUI re-measures the field
    /// whenever it changes.
    var measuredText: String
    var placeholder: String
    var font: NSFont
    /// Changing this value moves keyboard focus into the field.
    var focusRequest: Int
    var maximumLines = 8
    var acceptsImages: Bool
    /// Returns true when the key was handled.
    var onKey: (PuckComposerKey) -> Bool
    var onImageData: (Data) -> Void
    var onImageFiles: ([URL]) -> Void
    var onFocusChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PuckComposerNSTextView()
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.font = font
        textView.string = text
        textView.placeholder = placeholder
        textView.setAccessibilityIdentifier(AccessibilityID.puckSessionMessageField)
        textView.setAccessibilityLabel("Message")

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.requestFocus(focusRequest)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        if textView.font != font { textView.font = font }
        textView.placeholder = placeholder
        textView.needsDisplay = true
        context.coordinator.requestFocus(focusRequest)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let textView = context.coordinator.textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return nil }
        let width = max(proposal.width ?? 320, 40)
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let lineHeight = layoutManager.defaultLineHeight(for: font)
        let used = layoutManager.usedRect(for: container).height
        let height = min(max(used, lineHeight), lineHeight * CGFloat(maximumLines))
        return CGSize(width: width, height: ceil(height))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PuckComposerTextView
        weak var textView: PuckComposerNSTextView?
        private var appliedFocusRequest: Int?
        private var pendingFocus = false

        init(_ parent: PuckComposerTextView) { self.parent = parent }

        func requestFocus(_ request: Int) {
            guard request != appliedFocusRequest else { return }
            appliedFocusRequest = request
            pendingFocus = true
            DispatchQueue.main.async { [weak self] in self?.applyPendingFocus() }
        }

        /// A new field is not in a window until SwiftUI installs it.
        func applyPendingFocus() {
            guard pendingFocus, let textView, let window = textView.window else { return }
            pendingFocus = false
            window.makeFirstResponder(textView)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            if parent.text != textView.string { parent.text = textView.string }
            textView.invalidateIntrinsicContentSize()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // An input method owns Return and the arrows while composing.
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                let flags = (textView as? PuckComposerNSTextView)?.keyModifiers ?? []
                if flags.contains(.shift) || flags.contains(.option) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                return parent.onKey(.submit)
            case #selector(NSResponder.insertLineBreak(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            case #selector(NSResponder.cancelOperation(_:)), #selector(NSTextView.complete(_:)):
                return parent.onKey(.escape)
            case #selector(NSResponder.insertTab(_:)):
                return parent.onKey(.tab)
            case #selector(NSResponder.moveUp(_:)):
                return parent.onKey(.upArrow)
            case #selector(NSResponder.moveDown(_:)):
                return parent.onKey(.downArrow)
            default:
                return false
            }
        }

        func focusChanged(_ focused: Bool) { parent.onFocusChange(focused) }

        /// Images become attachments; other files are inserted as paths, as
        /// a terminal would. Returns false to let plain text paste normally.
        func handle(_ pasteboard: NSPasteboard, in textView: NSTextView) -> Bool {
            let urls = (pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL]) ?? []
            if !urls.isEmpty {
                let images = parent.acceptsImages ? urls.filter(PuckDraftImage.isImageFile) : []
                let others = urls.filter { !images.contains($0) }
                if !images.isEmpty { parent.onImageFiles(images) }
                if !others.isEmpty {
                    textView.insertText(others.map { Self.shellQuoted($0.path) }.joined(separator: " "),
                                        replacementRange: textView.selectedRange())
                }
                return true
            }
            if pasteboard.string(forType: .string) != nil { return false }
            if let png = Self.pngData(from: pasteboard) {
                parent.onImageData(png)
                return true
            }
            return false
        }

        private static func pngData(from pasteboard: NSPasteboard) -> Data? {
            if let png = pasteboard.data(forType: .png) { return png }
            guard let data = pasteboard.data(forType: .tiff) ?? NSImage(pasteboard: pasteboard)?.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: data) else { return nil }
            return bitmap.representation(using: .png, properties: [:])
        }

        private static func shellQuoted(_ path: String) -> String {
            let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+@:,"))
            guard path.unicodeScalars.contains(where: { !safe.contains($0) }) else { return path }
            return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }
}

final class PuckComposerNSTextView: NSTextView {
    weak var coordinator: PuckComposerTextView.Coordinator?
    var placeholder = "" {
        didSet { if placeholder != oldValue { needsDisplay = true } }
    }

    /// Modifiers of the key being interpreted; the command selector for
    /// Return does not carry them.
    private(set) var keyModifiers: NSEvent.ModifierFlags = []

    override func keyDown(with event: NSEvent) {
        keyModifiers = event.modifierFlags
        defer { keyModifiers = [] }
        super.keyDown(with: event)
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.fileURL, .png, .tiff]
    }

    override func paste(_ sender: Any?) {
        if let coordinator, coordinator.handle(.general, in: self) { return }
        pasteAsPlainText(sender)
    }

    override func dragOperation(for dragInfo: NSDraggingInfo, type: NSPasteboard.PasteboardType) -> NSDragOperation {
        [.fileURL, .png, .tiff].contains(type) ? .copy : super.dragOperation(for: dragInfo, type: type)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let coordinator, coordinator.handle(sender.draggingPasteboard, in: self) { return true }
        return super.performDragOperation(sender)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        coordinator?.applyPendingFocus()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { coordinator?.focusChanged(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { coordinator?.focusChanged(false) }
        return resigned
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let origin = NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0),
                             y: textContainerOrigin.y)
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }
}
