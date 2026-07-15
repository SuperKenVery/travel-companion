import SwiftUI

@MainActor
struct PlaceListView: View {
    @Environment(TravelCore.self) private var core
    @Environment(AppRouter.self) private var router

    @State private var placePendingDeletion: PlaceSnapshot?

    private var snapshot: AppSnapshot { core.snapshot }
    private var places: [PlaceSnapshot] {
        snapshot.places.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        Group {
            if snapshot.group == nil {
                TCEmptyState(
                    title: "加入群组后添加地点",
                    message: "地点标注会作为不可变事件在附近成员之间离线同步。",
                    systemImage: "mappin.slash"
                )
            } else if places.isEmpty {
                TCEmptyState(
                    title: "还没有地点",
                    message: "即使地图底图不可用，也可以按坐标创建和查看离线标注。",
                    systemImage: "mappin.and.ellipse",
                    actionTitle: "添加坐标标注"
                ) {
                    router.present(.createPlace)
                }
            } else {
                List {
                    Section {
                        TCNotice(
                            title: "离线列表始终可用",
                            message: "Apple 地图底图不是正确运行所必需；坐标、备注和同步不依赖互联网。",
                            systemImage: "network.slash",
                            tone: .info
                        )
                        .listRowInsets(.init(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                    }

                    Section("群组地点") {
                        ForEach(places) { place in
                            NavigationLink {
                                PlaceDetailView(placeID: place.id)
                            } label: {
                                PlaceRow(place: place)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if canManage(place) {
                                    Button("删除", systemImage: "trash", role: .destructive) {
                                        placePendingDeletion = place
                                    }
                                    Button("编辑", systemImage: "pencil") {
                                        router.present(.editPlace(id: place.id))
                                    }
                                    .tint(.accentColor)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("地点")
        .toolbar {
            if snapshot.group != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        PlacesMapView()
                    } label: {
                        Label("地图增强", systemImage: "map")
                    }
                    .accessibilityHint("查看成员最后坐标和地点标注；底图不是离线功能的必需条件")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("添加地点", systemImage: "plus") {
                        router.present(.createPlace)
                    }
                }
            }
        }
        .alert(
            "删除“\(placePendingDeletion?.title ?? "这个地点")”？",
            isPresented: Binding(
                get: { placePendingDeletion != nil },
                set: { if !$0 { placePendingDeletion = nil } }
            ),
            presenting: placePendingDeletion
        ) { place in
            Button("删除", role: .destructive) {
                Task { await core.send(.deletePlace(id: place.id)) }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("删除事件会同步给群组成员，此操作不能在当前版本中撤销。")
        }
    }

    private func canManage(_ place: PlaceSnapshot) -> Bool {
        place.authorID == snapshot.identity.peerID || snapshot.group?.ownerID == snapshot.identity.peerID
    }
}

private struct PlaceRow: View {
    let place: PlaceSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .font(.title2)
                .foregroundStyle(.red)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(place.title)
                    .font(.headline)
                if !place.note.isEmpty {
                    Text(place.note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(place.formattedCoordinate)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            Text(place.authorName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

extension PlaceSnapshot {
    var formattedCoordinate: String {
        "\(latitude.formatted(.number.precision(.fractionLength(5)))), \(longitude.formatted(.number.precision(.fractionLength(5))))"
    }
}
