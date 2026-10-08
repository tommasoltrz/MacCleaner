/// Separates the welcome guide, limited access, and full access.
public enum LaunchAccess: Sendable, Equatable {
    case welcome
    case diskAccess
    case limited
    case ready

    public init(hasCompletedOnboarding: Bool, hasFullDiskAccess: Bool, forceWelcome: Bool = false) {
        if forceWelcome || !hasCompletedOnboarding {
            self = .welcome
        } else {
            self = hasFullDiskAccess ? .ready : .diskAccess
        }
    }

    public var requiresOnboarding: Bool { self == .welcome || self == .diskAccess }

    /// Allows the user to continue without Full Disk Access.
    public mutating func finishOnboarding(hasFullDiskAccess: Bool) {
        self = hasFullDiskAccess ? .ready : .limited
    }

    /// Limited access permits manual scans. Automatic scans require Full Disk Access.
    public mutating func authorizeScan(hasFullDiskAccess: Bool, automatic: Bool = false) -> Bool {
        guard !requiresOnboarding else { return false }
        if hasFullDiskAccess {
            self = .ready
            return true
        }
        if self == .limited { return !automatic }
        self = .diskAccess
        return false
    }
}
