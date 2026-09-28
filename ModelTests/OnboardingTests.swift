import Foundation
import Testing

@Suite("Onboarding")
@MainActor
struct OnboardingTests {
    @Test("Test launches always show Welcome and preserve normal setup progress", arguments: [
        SettingsStore.OnboardingStep.access, .complete
    ])
    func forcedOnboarding(savedStep: SettingsStore.OnboardingStep) throws {
        let storage = try ModelTestStorage()
        let normal = SettingsStore(defaults: storage.defaults, managesLoginItem: false)
        normal.onboardingStep = savedStep
        let forced = SettingsStore(defaults: storage.defaults, managesLoginItem: false, forceOnboarding: true)
        #expect(forced.onboardingStep == .welcome)
        forced.onboardingStep = .access
        let app = AppModel(settings: forced, startsScheduler: false)
        app.completeOnboarding()
        #expect(!app.needsOnboarding)

        let nextTestLaunch = SettingsStore(defaults: storage.defaults, managesLoginItem: false, forceOnboarding: true)
        #expect(nextTestLaunch.onboardingStep == .welcome)
        let nextNormalLaunch = SettingsStore(defaults: storage.defaults, managesLoginItem: false)
        #expect(nextNormalLaunch.onboardingStep == savedStep)
    }

    @Test("Setup resumes after a restart and stays complete after a settings reset")
    func persistsProgress() throws {
        let storage = try ModelTestStorage()
        let settings = SettingsStore(defaults: storage.defaults, managesLoginItem: false)
        #expect(settings.onboardingStep == .welcome)
        settings.onboardingStep = .access
        let restored = SettingsStore(defaults: storage.defaults, managesLoginItem: false)
        #expect(restored.onboardingStep == .access)
        restored.onboardingStep = .complete
        restored.resetToDefaults()
        let completed = SettingsStore(defaults: storage.defaults, managesLoginItem: false)
        #expect(completed.onboardingStep == .complete)
    }

    @Test("Setup blocks scans until the user continues, with no permission requirement")
    func gatesScanning() async throws {
        let storage = try ModelTestStorage()
        let settings = SettingsStore(defaults: storage.defaults, managesLoginItem: false)
        settings.scanSchedule = .daily
        settings.idleOnly = false
        let scanner = ControlledCleanupScanner()
        let cleanup = CleanupModel(scanner: scanner, defaults: storage.defaults)
        let app = AppModel(settings: settings, cleanup: cleanup, startsScheduler: false)
        app.startInitialCleanupScan()
        app.startScan(refreshOverview: false)
        app.startPhotoSweep()
        app.startFileDuplicateScan(roots: [storage.url])
        #expect(app.needsOnboarding)
        #expect(!app.scheduledScanIsDue())
        #expect(!app.isBusyWithDisk)
        #expect(scanner.progress.isEmpty)

        settings.onboardingStep = .access
        app.completeOnboarding()
        #expect(!app.needsOnboarding)
        app.startInitialCleanupScan()
        try await waitForModel { scanner.progress.count == 1 }
        scanner.finish(scanResults([]))
        try await waitForModel { !app.isBusyWithDisk }
        #expect(cleanup.scanResults != nil)
    }
}
