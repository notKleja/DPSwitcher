import AppKit
import Carbon

final class ShortcutCaptureField: NSSearchField {
    private weak static var activeRecorder: ShortcutCaptureField?
    private var eventMonitor: Any?
    private var isRecording = false

    private(set) var shortcut: GlobalShortcut
    var onRecordingStarted: (() -> Void)?
    var onRecordingCancelled: (() -> Void)?
    var onShortcutCaptured: ((GlobalShortcut) -> Result<Void, Swift.Error>)?
    var onError: ((Swift.Error) -> Void)?

    init(shortcut: GlobalShortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        alignment = .center
        baseWritingDirection = .leftToRight
        placeholderString = "Capture Shortcut"
        (cell as? NSSearchFieldCell)?.searchButtonCell = nil
        (cell as? NSSearchFieldCell)?.cancelButtonCell = nil
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        stringValue = shortcut.glyph
        toolTip = "Click, then press the new shortcut. Escape cancels."
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        removeMonitor()
    }

    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { false }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Capture keyboard shortcut" }
    override func accessibilityValue() -> String? { shortcut.glyph }

    override func accessibilityPerformPress() -> Bool {
        startRecording()
        return true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        startRecording()
    }

    override func viewDidHide() {
        super.viewDidHide()
        cancelRecording()
    }

    func updateShortcut(_ shortcut: GlobalShortcut) {
        self.shortcut = shortcut
        stringValue = shortcut.glyph
    }

    private func startRecording() {
        guard !isRecording, let window else { return }
        Self.activeRecorder?.cancelRecording()
        Self.activeRecorder = self
        isRecording = true
        stringValue = ""
        placeholderString = "Press Shortcut"
        onRecordingStarted?()
        window.makeFirstResponder(self)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard isRecording, Self.activeRecorder === self else { return event }

        if event.type == .leftMouseDown {
            if event.window !== window || !bounds.contains(convert(event.locationInWindow, from: nil)) {
                cancelRecording()
            }
            return event
        }

        guard event.type == .keyDown else { return event }
        if event.keyCode == UInt16(kVK_Escape), event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            cancelRecording()
            return nil
        }

        let captured = GlobalShortcut(
            keyCode: UInt32(event.keyCode),
            modifiers: event.modifierFlags.carbonModifiers
        )
        guard captured.hasModifier || Self.functionKeyCodes.contains(captured.keyCode) else {
            NSSound.beep()
            return nil
        }

        switch onShortcutCaptured?(captured) ?? .success(()) {
        case .success:
            shortcut = captured
            finishRecording()
        case let .failure(error):
            onError?(error)
            finishRecording()
        }
        return nil
    }

    private func cancelRecording() {
        guard isRecording else { return }
        onRecordingCancelled?()
        finishRecording()
    }

    private func finishRecording() {
        removeMonitor()
        isRecording = false
        placeholderString = "Capture Shortcut"
        stringValue = shortcut.glyph
        if Self.activeRecorder === self { Self.activeRecorder = nil }
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }

    private func removeMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    private static let functionKeyCodes: Set<UInt32> = [
        UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4),
        UInt32(kVK_F5), UInt32(kVK_F6), UInt32(kVK_F7), UInt32(kVK_F8),
        UInt32(kVK_F9), UInt32(kVK_F10), UInt32(kVK_F11), UInt32(kVK_F12),
        UInt32(kVK_F13), UInt32(kVK_F14), UInt32(kVK_F15), UInt32(kVK_F16),
        UInt32(kVK_F17), UInt32(kVK_F18), UInt32(kVK_F19), UInt32(kVK_F20),
    ]
}

private extension NSEvent.ModifierFlags {
    var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        let flags = intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) { value |= UInt32(controlKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        return value
    }
}
