import SwiftUI

enum TCStatusTone: Sendable {
    case neutral
    case info
    case success
    case warning
    case danger

    var color: Color {
        switch self {
        case .neutral: .secondary
        case .info: .blue
        case .success: TCDesign.success
        case .warning: TCDesign.warning
        case .danger: TCDesign.danger
        }
    }
}

struct TCStatusPill: View {
    let text: String
    var tone: TCStatusTone = .neutral
    var systemImage: String?

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }
            Text(text)
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tone.color)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(tone.color.opacity(0.12), in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

struct TCNotice: View {
    let title: String
    let message: String
    var systemImage: String = "info.circle.fill"
    var tone: TCStatusTone = .info
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(.caption.weight(.semibold))
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)
        }
        .tcCard(padding: 12)
        .accessibilityElement(children: .combine)
    }
}

struct TCEmptyState: View {
    let title: String
    let message: String
    let systemImage: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct TCOperationOverlay: ViewModifier {
    let isPresented: Bool
    let title: String

    func body(content: Content) -> some View {
        content
            .disabled(isPresented)
            .overlay {
                if isPresented {
                    ProgressView(title)
                        .padding(18)
                        .background(.regularMaterial, in: .rect(cornerRadius: TCDesign.compactRadius))
                        .accessibilityAddTraits(.isModal)
                }
            }
    }
}

extension View {
    func tcOperationOverlay(isPresented: Bool, title: String) -> some View {
        modifier(TCOperationOverlay(isPresented: isPresented, title: title))
    }
}

