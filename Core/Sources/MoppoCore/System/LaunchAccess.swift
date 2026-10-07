/// Keeps disk scans behind the welcome guide and the current permission check.
public enum LaunchAccess: Sendable, Equatable {
    case welcome
    case diskAccess
    case ready

    public init(hasCompletedOnboarding: Bool, hasFullDiskAccess: Bool, forceWelcome: Bool = false) {
        if forceWelcome || !hasCompletedOnboarding {
            self = .welcome
        } else {
            self = hasFullDiskAccess ? .ready : .diskAccess
        }
    }

    public var requiresOnboarding: Bool { self != .ready }

    /// Rechecks access before the user leaves the welcome guide.
    @discardableResult
    public mutating func finishOnboarding(hasFullDiskAccess: Bool) -> Bool {
        self = hasFullDiskAccess ? .ready : .diskAccess
        return self == .ready
    }

    /// Stops new scans when access is missing or the guide is open.
    public mutating func authorizeScan(hasFullDiskAccess: Bool) -> Bool {
        guard self == .ready else { return false }
        guard hasFullDiskAccess else {
            self = .diskAccess
            return false
        }
        return true
    }
}
