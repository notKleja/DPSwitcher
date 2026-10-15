import Foundation

struct InputPollPolicy {
    private(set) var consecutiveUSBCReads = 0
    private(set) var failures = 0

    mutating func record(_ input: String?) -> (delay: TimeInterval, reveal: Bool) {
        guard let input = input, let value = Int(input), (2...255).contains(value) else {
            consecutiveUSBCReads = 0
            failures = min(failures + 1, 6)
            let delays: [TimeInterval] = [1, 2, 4, 8, 15, 30]
            return (delays[failures - 1], false)
        }
        failures = 0
        consecutiveUSBCReads = input == "26" ? consecutiveUSBCReads + 1 : 0
        return (input == "26" ? 0.25 : 2, consecutiveUSBCReads >= 2)
    }
}
