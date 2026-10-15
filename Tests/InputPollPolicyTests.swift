import Foundation

@main
struct InputPollPolicyTests {
    static func main() {
        var policy = InputPollPolicy()
        func check(_ condition: Bool, _ message: String) {
            guard condition else {
                FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
                exit(1)
            }
        }
        check(policy.record("15").delay == 2, "normal waits must not poll continuously")
        for delay in [1.0, 2, 4, 8, 15, 30, 30] {
            check(policy.record(nil).delay == delay, "unavailable display retries must back off to 30 seconds")
        }
        let first = policy.record("26")
        check(!first.reveal && first.delay == 0.25, "first USB-C read needs prompt confirmation")
        check(policy.failures == 0, "valid input must clear failure backoff")
        check(policy.record("26").reveal, "two USB-C reads must reveal")
        _ = policy.record("15")
        check(!policy.record("26").reveal, "another input must reset USB-C confirmation")
        _ = policy.record(nil)
        check(!policy.record("26").reveal, "failed reads must reset USB-C confirmation")
        check(policy.record("").delay == 1, "empty responses must count as unavailable")
        check(policy.record("Could not find a suitable external display.").delay == 2,
              "error text must count as unavailable")
        check(policy.record("0").delay == 4, "zero is a failed DDC read")
        check(policy.record("1").delay == 8, "known noisy DDC response must back off")
        print("InputPollPolicyTests passed")
    }
}
