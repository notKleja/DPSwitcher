import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let shortcutConfigurationKey = "shortcutConfiguration"
    private static let softwareBlackActiveKey = "softwareBlackActive"

    private let launchMode: LaunchMode
    private let ddc = MonitorControlDDC()
    private let blackShade = PersistentBlackShade()
    private var shortcutConfiguration: ShortcutConfiguration
    private var hotKeys: GlobalHotKeyController?
    private var window: NSWindow?
    private var statusLabel: NSTextField?
    private var screenObserver: NSObjectProtocol?

    init(launchMode: LaunchMode) {
        self.launchMode = launchMode
        self.shortcutConfiguration = Self.loadShortcutConfiguration()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard keepOnlyOneInstance() else { return }

        do {
            hotKeys = try GlobalHotKeyController(
                configuration: shortcutConfiguration,
                onZero: { [weak self] in self?.setBrightness(0) },
                onFull: { [weak self] in self?.setBrightness(100) }
            )
        } catch {
            presentError(error)
        }

        registerLoginItem()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.blackShade.refresh()
        }

        if UserDefaults.standard.bool(forKey: Self.softwareBlackActiveKey) {
            blackShade.show()
        }

        if launchMode == .interactive {
            showWindow()
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    private func keepOnlyOneInstance() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return true }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { $0.processIdentifier != currentPID }
        guard let other else { return true }

        if launchMode == .interactive {
            other.activate()
        }
        NSApp.terminate(nil)
        return false
    }

    private func registerLoginItem() {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.loginItem(identifier: "com.notkleja.MonitorBrightnessHotkeys.LoginItem")
        guard service.status != .enabled else { return }
        do {
            try service.register()
        } catch {
            NSLog("MonitorBrightnessHotkeys: login item registration failed: %@", error.localizedDescription)
        }
    }

    private func setBrightness(_ percent: UInt16) {
        statusLabel?.stringValue = "Setting brightness to \(percent)%…"
        for action in BrightnessTransition.actions(for: percent) {
            switch action {
            case .showPersistentBlack:
                UserDefaults.standard.set(true, forKey: Self.softwareBlackActiveKey)
                blackShade.show()
            case .removePersistentBlack:
                blackShade.hide()
                UserDefaults.standard.set(false, forKey: Self.softwareBlackActiveKey)
            case let .setHardware(value):
                ddc.setBrightness(value) { [weak self] result in
                    switch result {
                    case let .success(displayCount):
                        let suffix = value == 0 ? " · persistent blackout active" : ""
                        self?.statusLabel?.stringValue = "Brightness: \(value)% · \(displayCount) display(s)\(suffix)"
                    case let .failure(error):
                        self?.statusLabel?.stringValue = error.localizedDescription
                        NSSound.beep()
                    }
                }
            }
        }
    }

    private func showWindow() {
        if window == nil { window = makeWindow() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Monitor Brightness Hotkeys"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let title = NSTextField(labelWithString: "Monitor Brightness Hotkeys")
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        let detail = NSTextField(wrappingLabelWithString:
            "0% combines minimum hardware brightness with MonitorControl’s persistent shielding shade for true black. The shade stays until the 100% shortcut is pressed and is excluded from normal screen capture."
        )
        detail.textColor = .secondaryLabelColor

        let zeroRecorder = makeRecorder(action: .zeroPercent, shortcut: shortcutConfiguration.zeroPercent)
        let fullRecorder = makeRecorder(action: .fullPercent, shortcut: shortcutConfiguration.fullPercent)
        let zeroShortcut = shortcutRow(recorder: zeroRecorder, label: "True-black 0%")
        let fullShortcut = shortcutRow(recorder: fullRecorder, label: "Restore to 100%")

        let zeroButton = NSButton(title: "Set 0%", target: self, action: #selector(setZeroFromButton))
        let fullButton = NSButton(title: "Set 100%", target: self, action: #selector(setFullFromButton))
        let buttons = NSStackView(views: [zeroButton, fullButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let status = NSTextField(labelWithString: "Launch at Login: enabled · click a shortcut field to capture")
        status.textColor = .secondaryLabelColor
        statusLabel = status

        let stack = NSStackView(views: [title, detail, zeroShortcut, fullShortcut, buttons, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            detail.widthAnchor.constraint(equalToConstant: 470),
        ])
        window.contentView = content
        return window
    }

    private func shortcutRow(recorder: ShortcutCaptureField, label: String) -> NSView {
        let text = NSTextField(labelWithString: label)
        text.translatesAutoresizingMaskIntoConstraints = false
        text.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let row = NSStackView(views: [text, recorder])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    private func makeRecorder(action: ShortcutAction, shortcut: GlobalShortcut) -> ShortcutCaptureField {
        let recorder = ShortcutCaptureField(shortcut: shortcut)
        recorder.onRecordingStarted = { [weak self] in
            self?.hotKeys?.suspend()
            self?.statusLabel?.stringValue = "Press the new shortcut · Escape cancels"
        }
        recorder.onRecordingCancelled = { [weak self] in
            try? self?.hotKeys?.resume()
            self?.statusLabel?.stringValue = "Shortcut capture cancelled"
        }
        recorder.onShortcutCaptured = { [weak self] shortcut in
            guard let self else { return .success(()) }
            let candidate: ShortcutConfiguration
            do {
                candidate = try self.shortcutConfiguration.updating(action, to: shortcut)
            } catch {
                try? self.hotKeys?.resume()
                return .failure(error)
            }

            do {
                try self.hotKeys?.update(to: candidate)
                self.shortcutConfiguration = candidate
                Self.saveShortcutConfiguration(candidate)
                self.statusLabel?.stringValue = "Shortcut saved: \(shortcut.glyph)"
                return .success(())
            } catch {
                return .failure(GlobalHotKeyController.Error.registerShortcut("captured", OSStatus(eventHotKeyExistsErr)))
            }
        }
        recorder.onError = { [weak self] error in
            self?.statusLabel?.stringValue = "Shortcut not saved: \(error.localizedDescription)"
            NSSound.beep()
        }
        return recorder
    }

    private static func loadShortcutConfiguration() -> ShortcutConfiguration {
        guard
            let data = UserDefaults.standard.data(forKey: shortcutConfigurationKey),
            let decoded = try? JSONDecoder().decode(ShortcutConfiguration.self, from: data)
        else { return .defaults }
        return decoded
    }

    private static func saveShortcutConfiguration(_ configuration: ShortcutConfiguration) {
        if let data = try? JSONEncoder().encode(configuration) {
            UserDefaults.standard.set(data, forKey: shortcutConfigurationKey)
        }
    }

    private func presentError(_ error: Swift.Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    @objc private func setZeroFromButton() { setBrightness(0) }
    @objc private func setFullFromButton() { setBrightness(100) }
}
