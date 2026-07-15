import SwiftUI

enum TCDesign {
    static let pagePadding: CGFloat = 16
    static let cardPadding: CGFloat = 16
    static let cardRadius: CGFloat = 18
    static let compactRadius: CGFloat = 12

    static let pageBackground = Color(.systemGroupedBackground)
    static let cardBackground = Color(.secondarySystemGroupedBackground)
    static let subtleBackground = Color(.tertiarySystemGroupedBackground)
    static let accent = Color.accentColor
    static let success = Color.green
    static let warning = Color.orange
    static let danger = Color.red
}

extension View {
    func tcCard(padding: CGFloat = TCDesign.cardPadding) -> some View {
        self
            .padding(padding)
            .background(TCDesign.cardBackground, in: .rect(cornerRadius: TCDesign.cardRadius))
    }

    func tcPageBackground() -> some View {
        self.background(TCDesign.pageBackground)
    }
}

struct TCSectionHeader: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    var systemImage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.headline)
            }

            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct TCMetric: View {
    let title: LocalizedStringKey
    let value: String
    var systemImage: String? = nil
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

