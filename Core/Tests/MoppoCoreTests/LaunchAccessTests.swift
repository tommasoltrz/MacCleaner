import Testing
@testable import MoppoCore

@Suite("Launch permission flow")
struct LaunchAccessTests {
    @Test("A first launch waits for the welcome guide", arguments: [false, true])
    func firstLaunch(hasAccess: Bool) {
        var access = LaunchAccess(hasCompletedOnboarding: false, hasFullDiskAccess: hasAccess)

        #expect(access == .welcome)
        let canScan = access.authorizeScan(hasFullDiskAccess: hasAccess)
        #expect(!canScan)
        access.finishOnboarding(hasFullDiskAccess: hasAccess)
        #expect(!access.requiresOnboarding)
        let manualScan = access.authorizeScan(hasFullDiskAccess: hasAccess)
        #expect(manualScan)
        let automaticScan = access.authorizeScan(hasFullDiskAccess: hasAccess, automatic: true)
        #expect(automaticScan == hasAccess)
    }

    @Test("A returning user can continue without access")
    func completedGuideWithoutAccess() {
        var access = LaunchAccess(hasCompletedOnboarding: true, hasFullDiskAccess: false)

        #expect(access == .diskAccess)
        #expect(access.requiresOnboarding)
        let scanBeforeGuide = access.authorizeScan(hasFullDiskAccess: false)
        #expect(!scanBeforeGuide)
        access.finishOnboarding(hasFullDiskAccess: false)
        #expect(access == .limited)
        #expect(!access.requiresOnboarding)
        let manualScan = access.authorizeScan(hasFullDiskAccess: false)
        #expect(manualScan)
    }

    @Test("Limited access blocks repeated automatic scans without reopening the guide")
    func limitedAccessStaysOpen() {
        var access = LaunchAccess(hasCompletedOnboarding: true, hasFullDiskAccess: false)
        access.finishOnboarding(hasFullDiskAccess: false)

        for _ in 0..<3 {
            let automaticScan = access.authorizeScan(hasFullDiskAccess: false, automatic: true)
            #expect(!automaticScan)
            #expect(access == .limited)
            #expect(!access.requiresOnboarding)
        }

        let manualScan = access.authorizeScan(hasFullDiskAccess: false)
        #expect(manualScan)
        let automaticAfterManual = access.authorizeScan(hasFullDiskAccess: false, automatic: true)
        #expect(!automaticAfterManual)
        #expect(access == .limited)
    }

    @Test("Granting access still waits for the user to leave the guide")
    func grantDuringGuide() {
        var access = LaunchAccess(hasCompletedOnboarding: true, hasFullDiskAccess: false)

        let scanBeforeConfirmation = access.authorizeScan(hasFullDiskAccess: true)
        #expect(!scanBeforeConfirmation)
        #expect(access == .diskAccess)
        access.finishOnboarding(hasFullDiskAccess: true)
        #expect(!access.requiresOnboarding)
        let scanAfterConfirmation = access.authorizeScan(hasFullDiskAccess: true, automatic: true)
        #expect(scanAfterConfirmation)
    }

    @Test("Granting access during limited use enables automatic scans")
    func grantDuringLimitedAccess() {
        var access = LaunchAccess(hasCompletedOnboarding: true, hasFullDiskAccess: false)
        access.finishOnboarding(hasFullDiskAccess: false)

        let canScan = access.authorizeScan(hasFullDiskAccess: true, automatic: true)
        #expect(canScan)
        #expect(access == .ready)
        #expect(!access.requiresOnboarding)
    }

    @Test("Revoking access returns to the guide and permits limited access")
    func revokedAccess() {
        var access = LaunchAccess(hasCompletedOnboarding: true, hasFullDiskAccess: true)

        let scanBeforeRevocation = access.authorizeScan(hasFullDiskAccess: true)
        #expect(scanBeforeRevocation)
        let scanAfterRevocation = access.authorizeScan(hasFullDiskAccess: false)
        #expect(!scanAfterRevocation)
        #expect(access == .diskAccess)
        access.finishOnboarding(hasFullDiskAccess: false)
        #expect(access == .limited)
        let automaticScan = access.authorizeScan(hasFullDiskAccess: false, automatic: true)
        #expect(!automaticScan)
        #expect(!access.requiresOnboarding)
    }

    @Test("Access lost before the final button selects limited access")
    func revokedBeforeCompletion() {
        var access = LaunchAccess(hasCompletedOnboarding: false, hasFullDiskAccess: true)

        access.finishOnboarding(hasFullDiskAccess: false)
        #expect(access == .limited)
        #expect(!access.requiresOnboarding)
        let canScan = access.authorizeScan(hasFullDiskAccess: false, automatic: true)
        #expect(!canScan)
    }

    @Test("A new launch without access shows the access step again")
    func relaunchAfterLimitedAccess() {
        var firstSession = LaunchAccess(hasCompletedOnboarding: false, hasFullDiskAccess: false)
        firstSession.finishOnboarding(hasFullDiskAccess: false)
        #expect(firstSession == .limited)

        let nextSession = LaunchAccess(hasCompletedOnboarding: true, hasFullDiskAccess: false)
        #expect(nextSession == .diskAccess)
        #expect(nextSession.requiresOnboarding)
    }

    @Test("The onboarding scheme suspends scans for an existing installation")
    func forcedWelcome() {
        var access = LaunchAccess(
            hasCompletedOnboarding: true,
            hasFullDiskAccess: true,
            forceWelcome: true
        )

        #expect(access == .welcome)
        let scanBeforeGuide = access.authorizeScan(hasFullDiskAccess: true, automatic: true)
        #expect(!scanBeforeGuide)
        access.finishOnboarding(hasFullDiskAccess: true)
        #expect(access == .ready)
        let scanAfterGuide = access.authorizeScan(hasFullDiskAccess: true, automatic: true)
        #expect(scanAfterGuide)
    }
}
