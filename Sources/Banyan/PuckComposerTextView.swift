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
/// newline, and a pasted or dropped image becomes an attachment named by an
/// `[Image #N]` placeholder at the caret. A placeholder edits as one unit:
/// the caret steps over it and a deletion that touches it removes all of it.
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
    /// Attachments in the draft; placeholders up to this number are live.
    var imageCount: Int
    /// Returns true when the key was handled.
    var onKey: (PuckComposerKey) -> Bool
    /// Attach an image; returns the placeholder to insert, or nil.
    var onImageData: (Data) -> String?
    var onImageFiles: ([URL]) -> [String]
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
            // Undo steps recorded against the old text no longer apply.
            context.coordinator.undo.removeAllActions()
        }
        context.coordinator.highlightPlaceholders()
        if textView.font != font { textView.font = font }
        textView.placeholder = placeholder
        textView.needsDisplay = true
        context.coordinator.requestFocus(focusRequest)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let textView = context.coordinator.textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return nil }
        let widths = Self.widths(proposed: proposal.width ?? 0, actual: nsView.frame.width)
        if container.containerSize.width != widths.measure {
            container.containerSize = NSSize(width: widths.measure, height: .greatestFiniteMagnitude)
        }
        layoutManager.ensureLayout(for: container)
        let lineHeight = layoutManager.defaultLineHeight(for: font)
        let used = layoutManager.usedRect(for: container).height
        let height = min(max(used, lineHeight), lineHeight * CGFloat(maximumLines))
        return CGSize(width: widths.report, height: ceil(height))
    }

    /// Widths to measure the field at and to report back to SwiftUI.
    ///
    /// SwiftUI probes the field with an infinite or zero width, meaning
    /// "whatever fits", and with small widths while it looks for an ideal
    /// size. Measuring at a probe width rewraps the live text and resizes the
    /// text view, so the next pass measures a different height and rewraps
    /// again. The layout never settles and AppKit aborts the window once it
    /// has run more constraint passes than it has views. Measure at the width
    /// the field actually has, and let the next pass correct the height after
    /// SwiftUI lays the field out at its real width.
    ///
    /// Because the reported width is a concrete number for every probe, SwiftUI
    /// treats the field as fixed-width: the host must stretch it with
    /// `.frame(maxWidth: .infinity)`, or it never grows past its current frame
    /// and the composer only fills part of the pane.
    static func widths(proposed: CGFloat, actual: CGFloat) -> (measure: CGFloat, report: CGFloat) {
        let measure = actual >= 40 ? actual : (proposed.isFinite && proposed >= 40 ? proposed : 320)
        let report = proposed.isFinite && proposed >= 40 ? proposed : measure
        return (measure: measure, report: report)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PuckComposerTextView
        weak var textView: PuckComposerNSTextView?
        /// The field's own undo stack, so replacing the draft from outside
        /// (a send, a restored message) can clear it.
        let undo = UndoManager()
        /// What the highlight was last drawn for; SwiftUI updates the field on
        /// every published session change, streaming included.
        private var highlighted: (text: String, imageCount: Int)?
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
            highlightPlaceholders()
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange,
                      replacementString: String?) -> Bool {
            guard let replacement = replacementString, !textView.hasMarkedText() else { return true }
            let atomic = PuckImagePlaceholders.atomicRange(for: range, in: textView.string)
            guard atomic != range else { return true }
            // Re-enters this method with the widened range, which passes.
            if textView.shouldChangeText(in: atomic, replacementString: replacement) {
                textView.textStorage?.replaceCharacters(in: atomic, with: replacement)
                textView.didChangeText()
                textView.setSelectedRange(NSRange(location: atomic.location + (replacement as NSString).length,
                                                  length: 0))
            }
            return false
        }

        func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange,
                      toCharacterRange new: NSRange) -> NSRange {
            guard !textView.hasMarkedText() else { return new }
            return PuckImagePlaceholders.snappedSelection(new, from: old, in: textView.string)
        }

        /// Placeholders that name an attachment read as chips. Temporary
        /// attributes leave the plain-text storage and typing style alone.
        func highlightPlaceholders() {
            guard let textView, let layoutManager = textView.layoutManager else { return }
            if let highlighted, highlighted.text == textView.string, highlighted.imageCount == parent.imageCount {
                return
            }
            highlighted = (textView.string, parent.imageCount)
            let all = NSRange(location: 0, length: (textView.string as NSString).length)
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
            for token in PuckImagePlaceholders.references(in: textView.string, imageCount: parent.imageCount) {
                layoutManager.addTemporaryAttributes([
                    .foregroundColor: NSColor.controlAccentColor,
                    .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.14),
                ], forCharacterRange: token.range)
            }
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

        /// Images become attachments named at the caret; other files are
        /// inserted as paths, as a terminal would. Returns false to let plain
        /// text paste normally.
        func handle(_ pasteboard: NSPasteboard, in textView: NSTextView) -> Bool {
            let urls = (pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL]) ?? []
            if !urls.isEmpty {
                let images = parent.acceptsImages ? urls.filter(PuckDraftImage.isImageFile) : []
                let others = urls.filter { !images.contains($0) }
                if !images.isEmpty { insertPlaceholders(parent.onImageFiles(images), in: textView) }
                if !others.isEmpty {
                    textView.insertText(others.map { Self.shellQuoted($0.path) }.joined(separator: " "),
                                        replacementRange: textView.selectedRange())
                }
                return true
            }
            if pasteboard.string(forType: .string) != nil { return false }
            if let png = Self.pngData(from: pasteboard) {
                insertPlaceholders(parent.onImageData(png).map { [$0] } ?? [], in: textView)
                return true
            }
            return false
        }

        private func insertPlaceholders(_ labels: [String], in textView: NSTextView) {
            guard !labels.isEmpty else { return }
            let range = textView.selectedRange()
            textView.insertText(PuckImagePlaceholders.insertion(of: labels, at: range, in: textView.string),
                                replacementRange: range)
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
