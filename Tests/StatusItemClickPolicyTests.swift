import Foundation

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    guard actual == expected else {
        throw TestFailure(description: "\(message): expected \(expected), got \(actual)")
    }
}

@main
struct StatusItemClickPolicyTests {
    static func main() {
        do {
            try expectEqual(
                StatusItemClickPolicy.action(for: .left, clickCount: 1),
                .ignore,
                "a single left-click must not switch inputs"
            )
            try expectEqual(
                StatusItemClickPolicy.action(for: .left, clickCount: 2),
                .switchToDisplayPort,
                "a double left-click must switch to DisplayPort"
            )
            try expectEqual(
                StatusItemClickPolicy.action(for: .right, clickCount: 1),
                .showMenu,
                "a right-click must keep opening the manual input menu"
            )
            print("StatusItemClickPolicyTests passed")
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
