import SwiftUI

/// Opens permission settings from a shared status row.
struct PermissionRow: View {
    let title: String
    let detail: String
    let symbol: String
    let status: String
    let isEnabled: Bool
    let settingsHint: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(Token.textColor(.accent))
                    .frame(width: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Token.Text.primary)
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(Token.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(status)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isEnabled ? Token.Text.secondary : Token.textColor(.accent))
                    .fixedSize()
            }
            .padding(20)
            .background(Token.Fill.control, in: RoundedRectangle(cornerRadius: Token.Size.panelRadius))
            .overlay(RoundedRectangle(cornerRadius: Token.Size.panelRadius)
                .strokeBorder(Token.Fill.controlBorder, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Token.Size.panelRadius))
        }
        .buttonStyle(CardPressButtonStyle(cornerRadius: Token.Size.panelRadius))
        .accessibilityLabel(title)
        .accessibilityValue(status)
        .accessibilityHint(settingsHint)
        .help(settingsHint)
    }
}
