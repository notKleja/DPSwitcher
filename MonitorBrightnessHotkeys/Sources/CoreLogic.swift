import Carbon
import Foundation

enum DDCPacket {
    static let chipAddress: UInt8 = 0x37
    static let dataAddress: UInt8 = 0x51
    static let brightnessCommand: UInt8 = 0x10

    static func setVCP(command: UInt8, value: UInt16) -> [UInt8] {
        var packet: [UInt8] = [
            0x84,
            0x03,
            command,
            UInt8(value >> 8),
            UInt8(value & 0xFF),
            0,
        ]
        packet[packet.count - 1] = checksum(
            initial: (chipAddress << 1) ^ dataAddress,
            bytes: packet.dropLast()
        )
        return packet
    }

    static func checksum<S: Sequence>(initial: UInt8, bytes: S) -> UInt8 where S.Element == UInt8 {
        bytes.reduce(initial, ^)
    }
}

struct GlobalShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    var hasModifier: Bool {
        modifiers & UInt32(controlKey | optionKey | shiftKey | cmdKey) != 0
    }

    var glyph: String {
        var value = ""
        if modifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        value += Self.keyGlyphs[keyCode] ?? "Key \(keyCode)"
        return value
    }

    static let zeroPercent = GlobalShortcut(
        keyCode: UInt32(kVK_DownArrow),
        modifiers: UInt32(controlKey | optionKey | cmdKey)
    )

    static let fullPercent = GlobalShortcut(
        keyCode: UInt32(kVK_UpArrow),
        modifiers: UInt32(controlKey | optionKey | cmdKey)
    )

    private static let keyGlyphs: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
        UInt32(kVK_DownArrow): "↓", UInt32(kVK_UpArrow): "↑",
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩",
        UInt32(kVK_Tab): "⇥", UInt32(kVK_Delete): "⌫",
        UInt32(kVK_Home): "↖", UInt32(kVK_End): "↘",
        UInt32(kVK_PageUp): "⇞", UInt32(kVK_PageDown): "⇟",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
    ]
}

enum ShortcutAction {
    case zeroPercent
    case fullPercent
}

struct ShortcutConfiguration: Codable, Equatable {
    enum ValidationError: LocalizedError {
        case duplicateShortcut
        case modifierRequired

        var errorDescription: String? {
            switch self {
            case .duplicateShortcut:
                return "Choose two different shortcuts."
            case .modifierRequired:
                return "Include Command, Option, Control, or Shift."
            }
        }
    }

    var zeroPercent: GlobalShortcut
    var fullPercent: GlobalShortcut

    static let defaults = ShortcutConfiguration(
        zeroPercent: .zeroPercent,
        fullPercent: .fullPercent
    )

    func updating(_ action: ShortcutAction, to shortcut: GlobalShortcut) throws -> ShortcutConfiguration {
        guard shortcut.hasModifier else { throw ValidationError.modifierRequired }
        var updated = self
        switch action {
        case .zeroPercent: updated.zeroPercent = shortcut
        case .fullPercent: updated.fullPercent = shortcut
        }
        guard updated.zeroPercent != updated.fullPercent else { throw ValidationError.duplicateShortcut }
        return updated
    }
}

enum BrightnessTransition {
    enum Action: Equatable {
        case showPersistentBlack
        case removePersistentBlack
        case setHardware(UInt16)
    }

    static func actions(for percent: UInt16) -> [Action] {
        if percent == 0 {
            return [.showPersistentBlack, .setHardware(0)]
        }
        return [.removePersistentBlack, .setHardware(min(percent, 100))]
    }
}

enum LaunchMode: Equatable {
    case interactive
    case background

    init(arguments: [String]) {
        self = arguments.contains("--login") ? .background : .interactive
    }
}
