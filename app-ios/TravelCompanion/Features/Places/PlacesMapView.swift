import MapKit
import SwiftUI

@MainActor
struct PlacesMapView: View {
    @Environment(TravelCore.self) private var core

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selection: String?

    private var items: [TravelMapItem] {
        let placeItems = core.snapshot.places.map { place in
            TravelMapItem(
                id: "place:\(place.id)",
                title: place.title,
                subtitle: place.note.isEmpty ? place.authorName : place.note,
                coordinate: CLLocationCoordinate2D(
                    latitude: place.latitude,
                    longitude: place.longitude
                ),
                kind: .place,
                isStale: false
            )
        }

        let peerItems = core.snapshot.peers.compactMap { peer -> TravelMapItem? in
            guard let location = peer.location else { return nil }
            return TravelMapItem(
                id: "peer:\(peer.id)",
                title: peer.displayName,
                subtitle: location.isStale
                    ? "位置已过期 · \(location.sampledAt.formattedRelative)"
                    : "\(location.source.uppercased()) · \(location.sampledAt.formattedRelative)",
                coordinate: CLLocationCoordinate2D(
                    latitude: location.latitude,
                    longitude: location.longitude
                ),
                kind: .peer,
                isStale: location.isStale
            )
        }

        return placeItems + peerItems
    }

    private var selectedItem: TravelMapItem? {
        guard let selection else { return nil }
        return items.first { $0.id == selection }
    }

    var body: some View {
        Group {
            if items.isEmpty {
                TCEmptyState(
                    title: "没有可显示的坐标",
                    message: "创建地点或收到成员位置后，可在这里获得 MapKit 增强视图。",
                    systemImage: "map"
                )
            } else {
                Map(position: $cameraPosition, selection: $selection) {
                    ForEach(items) { item in
                        Marker(item.title, systemImage: item.systemImage, coordinate: item.coordinate)
                            .tint(item.tint)
                            .tag(item.id)
                    }
                }
                .mapStyle(.standard)
                .mapControls {
                    MapCompass()
                    MapScaleView()
                }
                .safeAreaInset(edge: .top, spacing: 8) {
                    TCNotice(
                        title: "MapKit 可选增强",
                        message: "底图可能需要网络或系统缓存；离线列表、坐标、雷达和同步始终可用。",
                        systemImage: "map.fill",
                        tone: .info
                    )
                    .padding(.horizontal, TCDesign.pagePadding)
                }
                .safeAreaInset(edge: .bottom, spacing: 8) {
                    if let selectedItem {
                        MapSelectionCard(item: selectedItem) {
                            selection = nil
                        }
                        .padding(.horizontal, TCDesign.pagePadding)
                    }
                }
            }
        }
        .navigationTitle("地图增强")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("显示全部", systemImage: "viewfinder") {
                        withAnimation { cameraPosition = .automatic }
                    }
                }
            }
        }
    }
}

private struct TravelMapItem: Identifiable {
    enum Kind {
        case place
        case peer
    }

    let id: String
    let title: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D
    let kind: Kind
    let isStale: Bool

    var systemImage: String {
        switch kind {
        case .place: "mappin"
        case .peer: "person.fill"
        }
    }

    var tint: Color {
        switch kind {
        case .place: .red
        case .peer: isStale ? .orange : .blue
        }
    }

    var kindTitle: String {
        switch kind {
        case .place: "地点标注"
        case .peer: isStale ? "成员最后位置 · 已过期" : "成员最后位置"
        }
    }
}

private struct MapSelectionCard: View {
    let item: TravelMapItem
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.systemImage)
                .font(.title2)
                .foregroundStyle(item.tint)
                .frame(width: 34)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.headline)
                Text(item.kindTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(item.tint)
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(
                    "\(item.coordinate.latitude.formatted(.number.precision(.fractionLength(5)))), " +
                    "\(item.coordinate.longitude.formatted(.number.precision(.fractionLength(5))))"
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }

            Spacer(minLength: 4)

            Button("关闭", systemImage: "xmark.circle.fill", action: onClose)
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .accessibilityLabel("关闭坐标详情")
        }
        .tcCard(padding: 12)
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
    }
}

