import AppKit
import SwiftUI
import MoppoCore

struct OnboardingView: View {
    private enum Step { case welcome, access }
    @State private var step = Step.welcome

    init(startsAtAccess: Bool = false, onFinish: @escaping () -> Void) {
        _step = State(initialValue: startsAtAccess ? .access : .welcome)
        self.onFinish = onFinish
    }

    static var launchAccess: LaunchAccess {
        LaunchAccess(
            hasCompletedOnboarding: UserDefaults.standard.bool(forKey: "onboarding.completed"),
            hasFullDiskAccess: FullDiskAccess.isGranted,
            forceWelcome: isRequestedAtLaunch
        )
    }

    static var isRequestedAtLaunch: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--show-onboarding")
        #else
        false
        #endif
    }

    let onFinish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasFullDiskAccess = FullDiskAccess.isGranted

    private var isWelcome: Bool { step == .welcome }

    var body: some View {
        VStack(spacing: 0) {
            WindowDragHandle()
                .frame(height: Token.Size.headerBand)

            ScrollView {
                VStack(spacing: 24) {
                    illustration
                    VStack(spacing: 10) {
                        Text(isWelcome ? "Welcome to Moppo" : "Enable Full Disk Access")
                            .font(.mcSecondaryHero)
                            .foregroundStyle(Token.Text.primary)
                            .accessibilityAddTraits(.isHeader)
                        Text(isWelcome
                             ? "Find unused files, review your storage, and choose what to remove."
                             : "Enable access to scan protected folders, or continue with limited access.")
                            .font(.system(size: 15))
                            .foregroundStyle(Token.Text.secondary)
                            .multilineTextAlignment(.center)
                    }

                    if isWelcome {
                        welcomeDetails
                    } else {
                        accessDetails
                    }
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, minHeight: 470)
                .id(step)
                .transition(.opacity)
            }
            .defaultScrollAnchor(.center, for: .alignment)

            footer
        }
        .background(Token.chrome.ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowChrome(headerBand: Token.Size.headerBand))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasFullDiskAccess = FullDiskAccess.isGranted
        }
        .task(id: step) {
            guard !isWelcome else { return }
            while !Task.isCancelled {
                hasFullDiskAccess = FullDiskAccess.isGranted
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
            }
        }
    }

    private var illustration: some View {
        Group {
            if isWelcome {
                Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "externaldrive.badge.checkmark")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(Token.textColor(hasFullDiskAccess ? .green : .accent))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 80, height: 80)
        .accessibilityHidden(true)
    }

    private var welcomeDetails: some View {
        VStack(spacing: 0) {
            feature("Review before removal", symbol: "checklist",
                    detail: "Moppo groups files by type and identifies items that need your review.")
            Rectangle().fill(Token.Fill.boxBorder).frame(height: 1).padding(.leading, 48)
            feature("Keep control", symbol: "hand.raised",
                    detail: "You choose what to remove. Scans do not delete files.")
            Rectangle().fill(Token.Fill.boxBorder).frame(height: 1).padding(.leading, 48)
            feature("Recover files from Trash", symbol: "trash",
                    detail: "Cleanup moves files to Trash so you can restore them.")
        }
        .background(Token.Fill.well, in: RoundedRectangle(cornerRadius: Token.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Token.Radius.card).strokeBorder(Token.Fill.boxBorder, lineWidth: 1))
    }

    private func feature(_ title: String, symbol: String, detail: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(Token.textColor(.accent))
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Token.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var accessDetails: some View {
        PermissionRow(
            title: "Full Disk Access",
            detail: "Allow disk scans without separate requests for common folders",
            symbol: "externaldrive.badge.checkmark",
            status: hasFullDiskAccess ? "On" : "Enable",
            isEnabled: hasFullDiskAccess,
            settingsHint: "Open Full Disk Access in System Settings",
            action: FullDiskAccess.openSystemSettings
        )
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            ZStack {
                HStack(spacing: 16) {
                    stepIndicator(1, title: "Welcome", active: isWelcome)
                    Rectangle().fill(Token.separator).frame(width: 24, height: 1)
                    stepIndicator(2, title: "Access", active: !isWelcome)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(isWelcome ? "Step 1 of 2: Welcome" : "Step 2 of 2: Access")

                HStack {
                    if !isWelcome {
                        Button("Back") {
                            changeStep(to: .welcome)
                        }
                        .buttonStyle(PageActionButtonStyle())
                    }
                    Spacer()
                    Button(isWelcome ? "Continue" : (hasFullDiskAccess ? "Start Scan" : "Continue with Limited Access")) {
                        if isWelcome { changeStep(to: .access) }
                        else { onFinish() }
                    }
                    .buttonStyle(PageActionButtonStyle(tint: Token.color(.accent)))
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.vertical, 22)
        }
        .padding(.horizontal, 40)
    }

    private func stepIndicator(_ number: Int, title: String, active: Bool) -> some View {
        HStack(spacing: 9) {
            Text("\(number)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? Color.white : Token.Text.secondary)
                .frame(width: 28, height: 28)
                .background(active ? Token.color(.accent) : Token.Fill.control, in: Circle())
            Text(title)
                .font(.system(size: 13, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Token.Text.primary : Token.Text.secondary)
        }
    }

    private func changeStep(to step: Step) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            self.step = step
        }
    }
}
