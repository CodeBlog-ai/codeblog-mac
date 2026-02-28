//
//  ChatInputField.swift
//  CodeBlog
//
//  AppKit-backed multi-line composer using NSTextView.
//  - Enter       → send
//  - Shift+Enter → newline
//  - Cmd+Enter / Ctrl+Enter → send
//  - Height grows with content (min 50pt, max 160pt, then scrolls)
//

import SwiftUI
import AppKit

// MARK: - SwiftUI Wrapper

struct AppKitComposerTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let focusToken: Int
    let placeholder: String
    let onSubmit: () -> Void

    static let minHeight: CGFloat = 50
    static let maxHeight: CGFloat = 160

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> ComposerTextView {
        let tv = ComposerTextView()
        tv.delegate        = context.coordinator
        tv.isEditable      = true
        tv.isSelectable    = true
        tv.isRichText      = false
        tv.allowsUndo      = true
        tv.drawsBackground = false
        tv.focusRingType   = .none

        tv.textContainerInset  = NSSize(width: 14, height: 15)
        tv.textContainer?.widthTracksTextView  = true
        tv.textContainer?.containerSize        = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                        height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable   = true
        tv.isHorizontallyResizable = false

        let font = NSFont(name: "Nunito-Medium", size: 16)
                    ?? NSFont.systemFont(ofSize: 16, weight: .medium)
        tv.font      = font
        tv.textColor = NSColor(hex: "2F2A24") ?? .labelColor

        tv.placeholderText  = placeholder
        tv.placeholderColor = NSColor(hex: "9B948D") ?? .secondaryLabelColor
        tv.string           = text
        tv.onSubmit         = onSubmit

        // Wrap in a scroll view that NSTextView needs for scrolling
        // but we control the outer frame via sizeThatFits
        tv.enclosingScrollView?.hasVerticalScroller  = true
        tv.enclosingScrollView?.autohidesScrollers   = true
        tv.enclosingScrollView?.drawsBackground      = false

        context.coordinator.textView = tv
        return tv
    }

    func updateNSView(_ tv: ComposerTextView, context: Context) {
        context.coordinator.parent = self
        tv.onSubmit = onSubmit

        // Sync text only when changed externally (e.g. cleared after send)
        if tv.string != text {
            tv.string = text
            tv.refreshPlaceholder()
            tv.invalidateIntrinsicContentSize()
        }

        // Focus token
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
        if isFocused && tv.window?.firstResponder !== tv {
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
    }

    /// Let SwiftUI ask for the preferred size — this drives .frame height automatically.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: ComposerTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 300
        let h = tv.idealHeight(forWidth: width)
            .clamped(to: Self.minHeight...Self.maxHeight)
        return CGSize(width: width, height: h)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AppKitComposerTextField
        var lastFocusToken = -1
        weak var textView: ComposerTextView?

        init(parent: AppKitComposerTextField) { self.parent = parent }

        func textDidBeginEditing(_ n: Notification) { parent.isFocused = true  }
        func textDidEndEditing  (_ n: Notification) { parent.isFocused = false }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? ComposerTextView else { return }
            parent.text = tv.string
            tv.refreshPlaceholder()
            tv.invalidateIntrinsicContentSize()
        }

        func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            guard sel == #selector(NSResponder.insertNewline(_:)) else { return false }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) {
                // Shift+Enter → real newline
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            // Plain Enter → send (Cmd+Enter is caught in keyDown below)
            parent.onSubmit()
            return true
        }
    }
}

// MARK: - ComposerTextView

final class ComposerTextView: NSTextView {

    /// Called when Cmd+Enter / Ctrl+Enter is pressed
    var onSubmit: (() -> Void)?

    // MARK: Placeholder

    var placeholderText: String = "" { didSet { refreshPlaceholder() } }
    var placeholderColor: NSColor = .secondaryLabelColor { didSet { refreshPlaceholder() } }

    private lazy var placeholderLabel: NSTextField = {
        let f = NSTextField(labelWithString: "")
        f.isEditable    = false
        f.isSelectable  = false
        f.isBordered    = false
        f.drawsBackground = false
        f.lineBreakMode = .byTruncatingTail
        f.maximumNumberOfLines = 1
        addSubview(f)
        return f
    }()

    func refreshPlaceholder() {
        placeholderLabel.stringValue = placeholderText
        placeholderLabel.font        = font
        placeholderLabel.textColor   = placeholderColor
        placeholderLabel.isHidden    = !string.isEmpty
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Mirror NSTextView's text inset so placeholder aligns with real text
        let inset  = textContainerInset
        let pad    = textContainer?.lineFragmentPadding ?? 5
        let x      = inset.width + pad
        let fh     = (font?.ascender ?? 14) - (font?.descender ?? -4)
        // NSTextView is flipped; origin.y is from the top
        placeholderLabel.frame = NSRect(x: x, y: inset.height,
                                        width: max(0, bounds.width - x - inset.width),
                                        height: fh + 2)
    }

    // MARK: Intrinsic size (drives sizeThatFits)

    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let tc = textContainer else {
            return NSSize(width: NSView.noIntrinsicMetric, height: AppKitComposerTextField.minHeight)
        }
        lm.ensureLayout(for: tc)
        let used   = lm.usedRect(for: tc).height
        let insets = textContainerInset.height * 2
        let h = (used + insets)
            .clamped(to: AppKitComposerTextField.minHeight...AppKitComposerTextField.maxHeight)
        return NSSize(width: NSView.noIntrinsicMetric, height: h)
    }

    /// Height needed to display all text at a given width.
    func idealHeight(forWidth width: CGFloat) -> CGFloat {
        guard let lm = layoutManager, let tc = textContainer else {
            return AppKitComposerTextField.minHeight
        }
        let saved = tc.containerSize
        tc.containerSize = NSSize(width: width - textContainerInset.width * 2,
                                  height: CGFloat.greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let h = lm.usedRect(for: tc).height + textContainerInset.height * 2
        tc.containerSize = saved
        return h
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isEnter = event.keyCode == 36 || event.keyCode == 76 // Return / numpad Enter
        if isEnter && (flags == .command || flags == .control) {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    override var acceptsFirstResponder: Bool { true }
}

// MARK: - Helpers

private extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}
