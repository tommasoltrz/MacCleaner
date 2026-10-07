import Testing
@testable import MoppoCore

@Suite("Launch permission flow")
struct LaunchAccessTests {
    @Test("A first launch waits for the welcome guide even when access already exists")
    func firstLaunch() {
        var access = LaunchAccess(hasCompletedOnboarding: false, hasFullDiskAccess: true)

        #expect(access == .welcome)
        let scanBeforeGuide = access.authorizeScan(hasFullDiskAccess: true)
        #expect(!scanBeforeGuide)
        let completed = access.finishOnboarding(hasFullDiskAccess: true)
        #expect(completed)
        let scanAfterGuide = access.authorizeScan(hasFullDiskAccess: true)
        #expect(scanAfterGuide)
    }

    @Test("An imported completion flag cannot skip missing permissions")
    func completedGuideWithoutAccess() {
        var access = LaunchAccess(hasCompletedOnboarding: true, hasFullDiskAccess: false)

        #expect(access == .diskAccess)
        #expect(access.requiresOnboarding)
        let canScan = access.authorizeScan(hasFullDiskAccess: false)
        #expect(!canScan)
        let completed = access.finishOnboarding(hasFullDiskAccess: false)
        #expect(!completed)
        #expect(access == .diskAccess)
    }

    @Test("Granting access still waits for the user to start the scan")
    func grantDuringGuide() {
        var access = LaunchAccess(hasCompletedOnboarding: true, hasFullDiskAccess: false)

        let scanBeforeConfirmation = access.authorizeScan(hasFullDiskAccess: true)
        #expect(!scanBeforeConfirmation)
        #expect(access == .diskAccess)
        let completed = access.finishOnboarding(hasFullDiskAccess: true)
        #expect(completed)
        #expect(!access.requiresOnboarding)
        let scanAfterConfirmation = access.authorizeScan(hasFullDiskAccess: true)
        #expect(scanAfterConfirmation)
    }

    @Test("Revoking access stops the next scan and returns to the access guide")
    func revokedAccess() {
        var access = LaunchAccess(hasCompletedOnboarding: true, hasFullDiskAccess: true)

        let scanBeforeRevocation = access.authorizeScan(hasFullDiskAccess: true)
        #expect(scanBeforeRevocation)
        let scanAfterRevocation = access.authorizeScan(hasFullDiskAccess: false)
        #expect(!scanAfterRevocation)
        #expect(access == .diskAccess)
        let scanBeforeConfirmation = access.authorizeScan(hasFullDiskAccess: true)
        #expect(!scanBeforeConfirmation)
        let completed = access.finishOnboarding(hasFullDiskAccess: true)
        #expect(completed)
        let scanAfterConfirmation = access.authorizeScan(hasFullDiskAccess: true)
        #expect(scanAfterConfirmation)
    }

    @Test("Access lost before the final button cannot complete the guide")
    func revokedBeforeCompletion() {
        var access = LaunchAccess(hasCompletedOnboarding: false, hasFullDiskAccess: true)

        let completed = access.finishOnboarding(hasFullDiskAccess: false)
        #expect(!completed)
        #expect(access == .diskAccess)
        let canScan = access.authorizeScan(hasFullDiskAccess: false)
        #expect(!canScan)
    }

    @Test("The onboarding scheme suspends scans for an existing installation")
    func forcedWelcome() {
        var access = LaunchAccess(
            hasCompletedOnboarding: true,
            hasFullDiskAccess: true,
            forceWelcome: true
        )

        #expect(access == .welcome)
        let scanBeforeGuide = access.authorizeScan(hasFullDiskAccess: true)
        #expect(!scanBeforeGuide)
        let completed = access.finishOnboarding(hasFullDiskAccess: true)
        #expect(completed)
        let scanAfterGuide = access.authorizeScan(hasFullDiskAccess: true)
        #expect(scanAfterGuide)
    }
}
