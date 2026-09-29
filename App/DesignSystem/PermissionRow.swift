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
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(Token.textColor(.accent))
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Token.Text.primary)
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(Token.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(status)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isEnabled ? Token.Text.secondary : Token.textColor(.accent))
                    .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Token.Fill.well, in: RoundedRectangle(cornerRadius: Token.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Token.Radius.card)
                .strokeBorder(Token.Fill.boxBorder, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Token.Radius.card))
        }
        .buttonStyle(CardPressButtonStyle(cornerRadius: Token.Radius.card))
        .accessibilityLabel(title)
        .accessibilityValue(status)
        .accessibilityHint(settingsHint)
        .help(settingsHint)
    }
}
