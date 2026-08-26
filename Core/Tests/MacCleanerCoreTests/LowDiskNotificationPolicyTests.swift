import Foundation
import Testing
@testable import MacCleanerCore

@Suite("Low-disk notification policy")
struct LowDiskNotificationPolicyTests {
    private let threshold = Int64(20) * ByteFormatting.bytesPerGB
    private let now = Date(timeIntervalSince1970: 1_756_000_000)

    @Test("the first observation below the threshold warns")
    func firstLowObservationWarns() {
        let decision = LowDiskNotificationPolicy.evaluate(
            freeBytes: threshold - 1,
            thresholdBytes: threshold,
            now: now,
            state: .init()
        )

        #expect(decision.shouldNotify)
        #expect(decision.state.wasBelowThreshold)
        #expect(decision.state.lastNotificationAt == now)
    }

    @Test("relaunching while still low does not warn again")
    func remainingLowIsQuiet() {
        let state = LowDiskNotificationPolicy.State(
            wasBelowThreshold: true,
            lastNotificationAt: now.addingTimeInterval(-90_000)
        )
        let decision = LowDiskNotificationPolicy.evaluate(
            freeBytes: threshold / 2,
            thresholdBytes: threshold,
            now: now,
            state: state
        )

        #expect(!decision.shouldNotify)
        #expect(decision.state == state)
    }

    @Test("exactly the threshold is recovered, not low")
    func thresholdIsNotBelow() {
        let decision = LowDiskNotificationPolicy.evaluate(
            freeBytes: threshold,
            thresholdBytes: threshold,
            now: now,
            state: .init(wasBelowThreshold: true, lastNotificationAt: now)
        )

        #expect(!decision.shouldNotify)
        #expect(!decision.state.wasBelowThreshold)
    }

    @Test("a fresh crossing after the cooldown warns again")
    func laterCrossingWarns() {
        let state = LowDiskNotificationPolicy.State(
            wasBelowThreshold: false,
            lastNotificationAt: now.addingTimeInterval(-LowDiskNotificationPolicy.cooldown)
        )
        let decision = LowDiskNotificationPolicy.evaluate(
            freeBytes: threshold - 1,
            thresholdBytes: threshold,
            now: now,
            state: state
        )

        #expect(decision.shouldNotify)
        #expect(decision.state.lastNotificationAt == now)
    }

    @Test("a repeated crossing inside the cooldown is quiet")
    func cooldownSuppressesCrossing() {
        let last = now.addingTimeInterval(-60 * 60)
        let decision = LowDiskNotificationPolicy.evaluate(
            freeBytes: threshold - 1,
            thresholdBytes: threshold,
            now: now,
            state: .init(wasBelowThreshold: false, lastNotificationAt: last)
        )

        #expect(!decision.shouldNotify)
        #expect(decision.state.wasBelowThreshold)
        #expect(decision.state.lastNotificationAt == last)
    }

    @Test("a backwards clock does not suppress the next real crossing indefinitely")
    func backwardsClockStillWarns() {
        let decision = LowDiskNotificationPolicy.evaluate(
            freeBytes: threshold - 1,
            thresholdBytes: threshold,
            now: now,
            state: .init(
                wasBelowThreshold: false,
                lastNotificationAt: now.addingTimeInterval(90_000)
            )
        )

        #expect(decision.shouldNotify)
        #expect(decision.state.lastNotificationAt == now)
    }
}
