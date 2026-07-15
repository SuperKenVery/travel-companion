import SwiftUI

struct TCPeerAvatar: View {
    let name: String
    var isConnected: Bool = false
    var size: CGFloat = 44

    private var initials: String {
        let words = name.split(whereSeparator: \.isWhitespace)
        let result = words.prefix(2).compactMap(\.first).map(String.init).joined()
        return result.isEmpty ? "?" : result.uppercased()
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(.tint.opacity(0.16))
                .frame(width: size, height: size)
                .overlay {
                    Text(initials)
                        .font(.system(size: size * 0.34, weight: .semibold, design: .rounded))
                        .foregroundStyle(.tint)
                }

            Circle()
                .fill(isConnected ? TCDesign.success : Color.secondary)
                .frame(width: size * 0.24, height: size * 0.24)
                .overlay {
                    Circle().stroke(TCDesign.cardBackground, lineWidth: 2)
                }
        }
        .accessibilityHidden(true)
    }
}

struct TCRadarMarker: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// Clockwise degrees from north.
    let bearing: Double
    /// Normalized distance from center, in the closed range 0...1.
    let normalizedDistance: Double
    var isPrecise: Bool = false
    var isStale: Bool = false
}

struct TCRadar: View {
    let markers: [TCRadarMarker]

    var body: some View {
        Canvas { context, size in
            let diameter = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = diameter / 2 - 20

            for fraction in [0.33, 0.66, 1.0] {
                let ringRadius = radius * fraction
                let rect = CGRect(
                    x: center.x - ringRadius,
                    y: center.y - ringRadius,
                    width: ringRadius * 2,
                    height: ringRadius * 2
                )
                context.stroke(
                    Path(ellipseIn: rect),
                    with: .color(.secondary.opacity(0.24)),
                    style: StrokeStyle(lineWidth: 1, dash: fraction == 1 ? [] : [4, 4])
                )
            }

            var crosshair = Path()
            crosshair.move(to: CGPoint(x: center.x, y: center.y - radius))
            crosshair.addLine(to: CGPoint(x: center.x, y: center.y + radius))
            crosshair.move(to: CGPoint(x: center.x - radius, y: center.y))
            crosshair.addLine(to: CGPoint(x: center.x + radius, y: center.y))
            context.stroke(crosshair, with: .color(.secondary.opacity(0.12)))

            for marker in markers {
                let angle = (marker.bearing - 90) * .pi / 180
                let distance = radius * min(max(marker.normalizedDistance, 0.1), 1)
                let point = CGPoint(
                    x: center.x + cos(angle) * distance,
                    y: center.y + sin(angle) * distance
                )
                let color: Color = marker.isStale ? .secondary : (marker.isPrecise ? .purple : .accentColor)
                let markerRect = CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)
                context.fill(Path(ellipseIn: markerRect), with: .color(color))
                context.draw(
                    Text(marker.name)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.primary),
                    at: CGPoint(x: point.x, y: point.y + 15),
                    anchor: .top
                )
            }

            context.fill(
                Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)),
                with: .color(.primary)
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("同行雷达")
        .accessibilityValue(markers.isEmpty ? "附近没有成员" : "显示 \(markers.count) 位成员")
    }
}
