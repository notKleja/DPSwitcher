import Carbon
import Foundation

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    guard actual == expected else {
        throw TestFailure(description: "\(message): expected \(expected), got \(actual)")
    }
}

@main
struct LogicTests {
    static func main() {
        do {
            let zeroPacket = DDCPacket.setVCP(command: 0x10, value: 0)
            try expect(zeroPacket, [0x84, 0x03, 0x10, 0x00, 0x00, 0xA8], "0% brightness packet")

            let fullPacket = DDCPacket.setVCP(command: 0x10, value: 100)
            try expect(fullPacket, [0x84, 0x03, 0x10, 0x00, 0x64, 0xCC], "100% brightness packet")

            try expect(
                GlobalShortcut.zeroPercent,
                GlobalShortcut(keyCode: UInt32(kVK_DownArrow), modifiers: UInt32(controlKey | optionKey | cmdKey)),
                "0% shortcut"
            )
            try expect(
                GlobalShortcut.fullPercent,
                GlobalShortcut(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(controlKey | optionKey | cmdKey)),
                "100% shortcut"
            )

            let customZero = GlobalShortcut(
                keyCode: UInt32(kVK_ANSI_B),
                modifiers: UInt32(controlKey | optionKey)
            )
            let defaults = ShortcutConfiguration.defaults
            let customized = try defaults.updating(.zeroPercent, to: customZero)
            try expect(customized.zeroPercent, customZero, "custom 0% shortcut")
            try expect(customized.fullPercent, .fullPercent, "100% recovery shortcut remains registered")

            do {
                _ = try defaults.updating(.zeroPercent, to: .fullPercent)
                throw TestFailure(description: "duplicate shortcuts must be rejected")
            } catch ShortcutConfiguration.ValidationError.duplicateShortcut {
                // Expected.
            }

            do {
                _ = try defaults.updating(
                    .fullPercent,
                    to: GlobalShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: 0)
                )
                throw TestFailure(description: "unmodified global shortcuts must be rejected")
            } catch ShortcutConfiguration.ValidationError.modifierRequired {
                // Expected.
            }

            let encoded = try JSONEncoder().encode(customized)
            let decoded = try JSONDecoder().decode(ShortcutConfiguration.self, from: encoded)
            try expect(decoded, customized, "shortcut configuration persistence")

            try expect(GlobalShortcut.zeroPercent.glyph, "⌃⌥⌘↓", "0% shortcut glyph")
            try expect(GlobalShortcut.fullPercent.glyph, "⌃⌥⌘↑", "100% shortcut glyph")

            try expect(
                BrightnessTransition.actions(for: 0),
                [.showPersistentBlack, .setHardware(0)],
                "0% shows persistent black before lowering hardware brightness"
            )
            try expect(
                BrightnessTransition.actions(for: 100),
                [.removePersistentBlack, .setHardware(100)],
                "raising brightness is the only transition that removes black"
            )

            try expect(LaunchMode(arguments: ["App", "--login"]), .background, "login launch mode")
            try expect(LaunchMode(arguments: ["App"]), .interactive, "normal launch mode")

            print("LogicTests passed")
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
