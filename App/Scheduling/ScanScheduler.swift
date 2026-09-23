import Foundation
import CoreGraphics
import IOKit.ps

/// Runs periodic volume and scan schedule checks.
@MainActor
final class ScanScheduler {
    var onTick: (() async -> Void)?

    deinit { schedulerTask?.cancel() }

    private static let schedulerTick: Duration = .seconds(300)

    private var schedulerTask: Task<Void, Never>?

    func start() {
        guard schedulerTask == nil else { return }
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.schedulerTick)
                guard let self, !Task.isCancelled else { return }
                await self.onTick?()
            }
        }
    }

    static var isOnACPower: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue()
        else { return true }
        // `kIOPSACPowerValue`, spelled out: the constant is not bridged into Swift.
        return (source as String) == "AC Power"
    }

    static var secondsSinceUserInput: TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
    }
}
