import Foundation

/// Decides whether an automatic scan should start.
///
/// A pure function over values, in Core rather than in the app, for the same reason
/// the grouping rules are: the decision has four inputs that are miserable to
/// arrange for real — the clock, the power source, how long the user has been away
/// from the keyboard, and when the last scan finished — and a scheduler that can
/// only be observed by waiting for it is a scheduler nobody checks.
public enum AutomaticScanPolicy {

    /// How often the user asked for a scan. `never` is the default and means the
    /// scheduler does nothing at all.
    public enum Cadence: String, Sendable, Equatable, CaseIterable {
        case never, daily, weekly

        /// How long must pass after a scan finishes before another is due.
        public var interval: TimeInterval? {
            switch self {
            case .never:  nil
            case .daily:  24 * 60 * 60
            case .weekly: 7 * 24 * 60 * 60
            }
        }
    }

    /// Everything the decision depends on, all supplied by the caller so a test can
    /// state them outright.
    public struct Conditions: Sendable, Equatable {
        public var now: Date
        /// When the last scan finished, or nil if none ever has.
        public var lastFinished: Date?
        public var cadence: Cadence
        /// Preferences › General › "Only when plugged in and idle".
        public var requiresIdleAndPower: Bool
        public var isOnACPower: Bool
        public var secondsSinceUserInput: TimeInterval
        /// A scan already running is never joined by a second one.
        public var isScanning: Bool

        public init(
            now: Date = Date(),
            lastFinished: Date? = nil,
            cadence: Cadence = .never,
            requiresIdleAndPower: Bool = false,
            isOnACPower: Bool = true,
            secondsSinceUserInput: TimeInterval = 0,
            isScanning: Bool = false
        ) {
            self.now = now
            self.lastFinished = lastFinished
            self.cadence = cadence
            self.requiresIdleAndPower = requiresIdleAndPower
            self.isOnACPower = isOnACPower
            self.secondsSinceUserInput = secondsSinceUserInput
            self.isScanning = isScanning
        }
    }

    /// How long the keyboard and mouse must be quiet before an idle-only scan runs.
    /// Five minutes: long enough that the machine is genuinely unattended, short
    /// enough that a lunch break is an opportunity.
    public static let idleThreshold: TimeInterval = 5 * 60

    public static func isDue(_ conditions: Conditions) -> Bool {
        guard !conditions.isScanning else { return false }
        guard let interval = conditions.cadence.interval else { return false }

        // Never scanned: due immediately. Otherwise due once the interval has
        // passed since the last one *finished* — a scan that takes an hour does not
        // shorten the wait for the next.
        if let last = conditions.lastFinished {
            // A clock that has gone backwards (a timezone fix, a manual change)
            // would otherwise park the next scan until the future catches up.
            let elapsed = conditions.now.timeIntervalSince(last)
            if elapsed >= 0 && elapsed < interval { return false }
        }

        if conditions.requiresIdleAndPower {
            guard conditions.isOnACPower,
                  conditions.secondsSinceUserInput >= idleThreshold
            else { return false }
        }
        return true
    }
}
