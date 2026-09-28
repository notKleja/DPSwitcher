enum StatusItemMouseButton {
    case left
    case right
}

enum StatusItemClickAction: Equatable {
    case ignore
    case showMenu
    case switchToDisplayPort
}

enum StatusItemClickPolicy {
    static func action(for button: StatusItemMouseButton, clickCount: Int) -> StatusItemClickAction {
        switch button {
        case .right:
            return .showMenu
        case .left where clickCount == 2:
            return .switchToDisplayPort
        case .left:
            return .ignore
        }
    }
}
