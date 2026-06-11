import Foundation

/// Exponential backoff: 1, 2, 4, 8, 16, 30, 30, ... seconds.
public struct Backoff {
    private var attempt = 0

    public init() {}

    public mutating func nextDelay() -> TimeInterval {
        let delay = min(30.0, pow(2.0, Double(attempt)))
        attempt += 1
        return delay
    }

    public mutating func reset() { attempt = 0 }
}
