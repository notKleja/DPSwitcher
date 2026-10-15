import Carbon
import Foundation

final class GlobalHotKeyController {
    enum Error: LocalizedError {
        case installHandler(OSStatus)
        case registerShortcut(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case let .installHandler(status):
                return "Could not install the global shortcut handler (\(status))."
            case let .registerShortcut(name, status):
                return "Could not register the \(name) shortcut (\(status))."
            }
        }
    }

    private static let signature: OSType = 0x4D42484B // MBHK
    private var eventHandler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef?] = []
    private var configuration: ShortcutConfiguration
    private let onZero: () -> Void
    private let onFull: () -> Void

    init(
        configuration: ShortcutConfiguration,
        onZero: @escaping () -> Void,
        onFull: @escaping () -> Void
    ) throws {
        self.configuration = configuration
        self.onZero = onZero
        self.onFull = onFull

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let controller = Unmanaged<GlobalHotKeyController>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                let result = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard result == noErr else { return result }
                switch hotKeyID.id {
                case 1: controller.onZero()
                case 2: controller.onFull()
                default: return OSStatus(eventNotHandledErr)
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard status == noErr else { throw Error.installHandler(status) }

        try register(configuration.zeroPercent, id: 1, name: "0%")
        try register(configuration.fullPercent, id: 2, name: "100%")
    }

    deinit {
        unregisterAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    func suspend() {
        unregisterAll()
    }

    func resume() throws {
        try registerConfiguration(configuration)
    }

    func update(to newConfiguration: ShortcutConfiguration) throws {
        let previous = configuration
        unregisterAll()
        do {
            try registerConfiguration(newConfiguration)
            configuration = newConfiguration
        } catch {
            unregisterAll()
            try? registerConfiguration(previous)
            throw error
        }
    }

    private func registerConfiguration(_ configuration: ShortcutConfiguration) throws {
        try register(configuration.zeroPercent, id: 1, name: "0%")
        do {
            try register(configuration.fullPercent, id: 2, name: "100%")
        } catch {
            unregisterAll()
            throw error
        }
    }

    private func unregisterAll() {
        for hotKey in hotKeys.compactMap({ $0 }) {
            _ = UnregisterEventHotKey(hotKey)
        }
        hotKeys.removeAll()
    }

    private func register(_ shortcut: GlobalShortcut, id: UInt32, name: String) throws {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr else { throw Error.registerShortcut(name, status) }
        hotKeys.append(reference)
    }
}
