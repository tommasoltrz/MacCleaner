import Combine
import SwiftUI
import ScoloCore

/// Preferences → General: startup, scanning schedule, and the Full Disk Access status.
struct GeneralPane: View {

    @Bindable var settings: SettingsStore

    /// Probed rather than stored. TCC can be changed while the app is running — that
    /// is the whole point of the button in this pane — so the row re-reads it every
    /// time the app comes forward instead of trusting a value from launch.
    @State private var hasFullDiskAccess = FullDiskAccess.isGranted

    var body: some View {
        PrefPane {
            startup
            scanning
            iCloud
            permissions
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            hasFullDiskAccess = FullDiskAccess.isGranted
        }
    }

    // MARK: - Startup

    private var startup: some View {
        PrefSection("Startup") {
            PrefToggleRow(title: "Open at login", isOn: $settings.launchAtLogin)
            PrefDivider()
            PrefToggleRow(
                title: "Show in menu bar",
                description: "Live free-space readout and a one-click cache purge.",
                isOn: $settings.showInMenuBar
            )
        }
    }

    // MARK: - Scanning

    private var scanning: some View {
        PrefSection("Scanning") {
            PrefPickerRow(
                title: "Scan automatically",
                selection: $settings.scanSchedule,
                label: \.displayName
            )
            PrefDivider()
            PrefToggleRow(title: "Only when plugged in and idle", isOn: $settings.idleOnly)
            PrefDivider()
            PrefRow(
                title: "Warn me below",
                description: "Notify when free space drops under the threshold."
            ) {
                warnBelowControl
            }
        }
    }

    private var warnBelowControl: some View {
        HStack(spacing: 10) {
            Slider(
                value: warnBelowBinding,
                in: Double(SettingsStore.warnBelowRange.lowerBound)
                    ... Double(SettingsStore.warnBelowRange.upperBound),
                step: 5
            )
            .frame(width: 112)
            .accessibilityLabel("Warn me below")
            .accessibilityValue("\(settings.warnBelowGB) gigabytes")

            Text("\(settings.warnBelowGB) GB")
                .font(.mcControlLabel.monospacedDigit())
                .foregroundStyle(Token.Text.primary)
                // Fixed width so the slider does not shift sideways as the readout
                // crosses from one digit to two.
                .frame(width: 44, alignment: .trailing)
        }
    }

    /// `Slider` wants a `Double`; the setting is whole gigabytes.
    private var warnBelowBinding: Binding<Double> {
        Binding(
            get: { Double(settings.warnBelowGB) },
            set: { settings.warnBelowGB = Int($0.rounded()) }
        )
    }

    // MARK: - iCloud

    /// The plan size is the only figure on the Dashboard's iCloud card with no source
    /// at all — `brctl` reports free space but never the plan it is free within — so
    /// it is estimated, and this is where a wrong estimate gets corrected.
    private var iCloud: some View {
        PrefSection("iCloud") {
            PrefRow(
                title: "Storage plan",
                // One line: the row has a fixed height, and the longer version was
                // clipped at both ends.
                description: "macOS does not report your plan size, so it is estimated."
            ) {
                Picker("Storage plan", selection: $settings.iCloudPlan) {
                    ForEach(ICloudPlan.allCases) { plan in
                        Text(plan.displayName).tag(plan)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    // MARK: - Permissions

    /// A status row, not a setting: nothing here can be switched, because the grant
    /// belongs to System Settings. The row's job is to say which way it currently sits
    /// and open the right pane.
    private var permissions: some View {
        PrefSection("Permissions") {
            HStack(spacing: PrefMetrics.controlGap) {
                Circle()
                    .fill(Token.color(hasFullDiskAccess ? .green : .red))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)

                PrefLabel(
                    title: hasFullDiskAccess
                        ? "Full Disk Access granted"
                        : "Full Disk Access required",
                    description: "Required to measure other users’ caches and iOS backups."
                )

                Spacer(minLength: PrefMetrics.controlGap)

                Button("Open System Settings") {
                    FullDiskAccess.openSystemSettings()
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.horizontal, PrefMetrics.rowPaddingH)
            .padding(.vertical, PrefMetrics.rowPaddingV)
            .frame(maxWidth: .infinity, minHeight: PrefMetrics.rowHeight)
            .accessibilityElement(children: .contain)
        }
    }
}

// MARK: - Preview

#Preview("General") {
    GeneralPane(settings: .preview())
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
}
