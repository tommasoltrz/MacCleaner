import Foundation

/// Decides when a free-space observation deserves a warning.
///
/// Kept in Core because notification delivery is platform UI, but the part most
/// likely to annoy someone is pure state-transition logic. The tests cover whether
/// a relaunch or a changing value produces another alert.
public enum LowDiskNotificationPolicy {

    /// One warning per day even if free space repeatedly crosses the threshold.
    public static let cooldown: TimeInterval = 24 * 60 * 60

    /// Persisted across launches. `wasBelowThreshold` prevents every startup from
    /// looking like a fresh crossing; the date also limits genuine repeated
    /// crossings when an install and cleanup make the figure bounce.
    public struct State: Codable, Equatable, Sendable {
        public var wasBelowThreshold: Bool
        public var lastNotificationAt: Date?

        public init(
            wasBelowThreshold: Bool = false,
            lastNotificationAt: Date? = nil
        ) {
            self.wasBelowThreshold = wasBelowThreshold
            self.lastNotificationAt = lastNotificationAt
        }
    }

    public struct Decision: Equatable, Sendable {
        public let shouldNotify: Bool
        public let state: State

        public init(shouldNotify: Bool, state: State) {
            self.shouldNotify = shouldNotify
            self.state = state
        }
    }

    /// Evaluates one live disk reading and returns state for the caller to save.
    /// Exactly the threshold is not "below" it. A clock corrected backwards is
    /// treated as elapsed rather than letting a future timestamp suppress warnings
    /// until wall time catches up.
    public static func evaluate(
        freeBytes: Int64,
        thresholdBytes: Int64,
        now: Date = .now,
        state: State,
        cooldown: TimeInterval = Self.cooldown
    ) -> Decision {
        guard thresholdBytes > 0 else {
            var reset = state
            reset.wasBelowThreshold = false
            return Decision(shouldNotify: false, state: reset)
        }

        let isBelow = freeBytes < thresholdBytes
        guard isBelow else {
            var recovered = state
            recovered.wasBelowThreshold = false
            return Decision(shouldNotify: false, state: recovered)
        }

        var below = state
        let crossedThreshold = !state.wasBelowThreshold
        below.wasBelowThreshold = true

        guard crossedThreshold, cooldownHasElapsed(since: state.lastNotificationAt, now: now,
                                                    cooldown: cooldown) else {
            return Decision(shouldNotify: false, state: below)
        }

        below.lastNotificationAt = now
        return Decision(shouldNotify: true, state: below)
    }

    private static func cooldownHasElapsed(
        since lastNotificationAt: Date?,
        now: Date,
        cooldown: TimeInterval
    ) -> Bool {
        guard let lastNotificationAt else { return true }
        let elapsed = now.timeIntervalSince(lastNotificationAt)
        return elapsed < 0 || elapsed >= max(0, cooldown)
    }
}
