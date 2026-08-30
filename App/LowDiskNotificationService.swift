import Foundation
import UserNotifications
import ScoloCore

/// Bridges the pure threshold policy to Notification Center.
///
/// The service requests authorization only after a real low-space crossing. A user
/// with enough space does not receive an unnecessary prompt. The service also does
/// not ask again after a denial.
@MainActor
final class LowDiskNotificationService {
    nonisolated static let notificationIdentifier = "com.tommasolaterza.Scolo.low-disk"

    private let center: UNUserNotificationCenter
    private let defaults: UserDefaults

    private enum Key {
        static let policyState = "runtime.lowDiskNotification.policyState"
    }

    init(
        center: UNUserNotificationCenter = .current(),
        defaults: UserDefaults = .standard
    ) {
        self.center = center
        self.defaults = defaults
    }

    func observe(
        freeBytes: Int64,
        volumeName: String,
        thresholdGB: Int,
        now: Date = .now
    ) async {
        let thresholdBytes = Int64(thresholdGB) * ByteFormatting.bytesPerGB
        let decision = LowDiskNotificationPolicy.evaluate(
            freeBytes: freeBytes,
            thresholdBytes: thresholdBytes,
            now: now,
            state: loadState()
        )

        // Two facts, saved at two moments. The crossing is saved now, so a
        // relaunch during the permission prompt does not read as a fresh crossing.
        // The delivery timestamp is saved only after delivery: recording it here
        // meant a declined prompt, or a failed `add`, still started the 24-hour
        // cooldown for a warning nobody ever saw.
        let previous = loadState()
        var crossingOnly = decision.state
        crossingOnly.lastNotificationAt = previous.lastNotificationAt
        saveState(crossingOnly)
        guard decision.shouldNotify, await authorizationAllowsDelivery() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Storage is running low"
        content.body = "\(ByteFormatting.string(freeBytes)) remains on \(volumeName), "
            + "below your \(thresholdGB) GB warning threshold."
        content.sound = .default
        content.userInfo = ["destination": "dashboard"]

        let request = UNNotificationRequest(
            identifier: Self.notificationIdentifier,
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            // Both awaits above suspend the main actor, and another observation can
            // run in the gap — recording, say, that free space recovered. Saving the
            // decision captured *before* the prompt would put that older state back
            // and swallow the next real crossing. So: reload, keep whatever the
            // crossing flag says now, and stamp the moment delivery actually
            // happened rather than the moment the decision was made.
            var delivered = loadState()
            delivered.lastNotificationAt = Date()
            saveState(delivered)
        } catch {
            // Delivery failed: the cooldown has not started, and the next crossing
            // gets a real attempt.
        }
    }

    private func authorizationAllowsDelivery() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    private func loadState() -> LowDiskNotificationPolicy.State {
        guard let data = defaults.data(forKey: Key.policyState),
              let state = try? JSONDecoder().decode(
                LowDiskNotificationPolicy.State.self,
                from: data
              ) else { return .init() }
        return state
    }

    private func saveState(_ state: LowDiskNotificationPolicy.State) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Key.policyState)
    }
}
