import AppKit
import SwiftUI

struct OnboardingView: View {
    @Bindable var settings: SettingsStore
    let onFinish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasFullDiskAccess = FullDiskAccess.isGranted

    private var isWelcome: Bool { settings.onboardingStep == .welcome }

    var body: some View {
        VStack(spacing: 0) {
            WindowDragHandle()
                .frame(height: Token.Size.headerBand)

            ScrollView {
                VStack(spacing: 24) {
                    illustration
                    VStack(spacing: 10) {
                        Text(isWelcome ? "Welcome to Scolo" : "Choose your access")
                            .font(.mcSecondaryHero)
                            .foregroundStyle(Token.Text.primary)
                            .accessibilityAddTraits(.isHeader)
                        Text(isWelcome
                             ? "Find unused files, review your storage, and choose what to remove."
                             : "Full Disk Access lets Scolo scan more folders on your Mac.")
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
                .frame(maxWidth: 580)
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, minHeight: 470)
                .id(settings.onboardingStep)
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
        .task(id: settings.onboardingStep) {
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
                Image(systemName: hasFullDiskAccess ? "checkmark.shield" : "externaldrive.badge.checkmark")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(Token.textColor(hasFullDiskAccess ? .green : .accent))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Token.Fill.control, in: RoundedRectangle(cornerRadius: 20))
            }
        }
        .frame(width: 80, height: 80)
        .accessibilityHidden(true)
    }

    private var welcomeDetails: some View {
        VStack(spacing: 0) {
            feature("Review before removal", symbol: "checklist",
                    detail: "Scolo groups files by type and identifies items that need your review.")
            Divider().padding(.leading, 58)
            feature("Keep control", symbol: "hand.raised",
                    detail: "You choose what to remove. Scans do not delete files.")
            Divider().padding(.leading, 58)
            feature("Recover files from Trash", symbol: "trash",
                    detail: "Cleanup moves files to Trash so you can restore them.")
        }
        .background(Token.Fill.control, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Token.Fill.controlBorder, lineWidth: 1))
    }

    private func feature(_ title: String, symbol: String, detail: String) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(Token.textColor(.accent))
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Token.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
    }

    private var accessDetails: some View {
        VStack(spacing: 18) {
            PermissionRow(
                title: "Full Disk Access",
                detail: "Include protected folders in your scans",
                symbol: "externaldrive.badge.checkmark",
                status: hasFullDiskAccess ? "On" : "Enable",
                isEnabled: hasFullDiskAccess,
                settingsHint: "Open Full Disk Access in System Settings",
                action: FullDiskAccess.openSystemSettings
            )

            Text(hasFullDiskAccess
                 ? "Access is ready. You can change permissions later in System Settings."
                 : "You can continue with limited access. Some folders will be skipped.")
                .font(.system(size: 13))
                .foregroundStyle(Token.Text.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
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

    private func changeStep(to step: SettingsStore.OnboardingStep) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            settings.onboardingStep = step
        }
    }
}
