import SwiftUI

@MainActor
struct PlaceDetailView: View {
    @Environment(TravelCore.self) private var core
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    let placeID: String
    @State private var isConfirmingDeletion = false

    private var place: PlaceSnapshot? {
        core.snapshot.places.first { $0.id == placeID }
    }

    private var canManage: Bool {
        guard let place else { return false }
        let snapshot = core.snapshot
        return place.authorID == snapshot.identity.peerID || snapshot.group?.ownerID == snapshot.identity.peerID
    }

    var body: some View {
        Group {
            if let place {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(spacing: 12) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.system(size: 58))
                                .foregroundStyle(.red)
                                .accessibilityHidden(true)
                            Text(place.title)
                                .font(.title.bold())
                                .multilineTextAlignment(.center)
                            Text(place.formattedCoordinate)
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity)
                        .tcCard()

                        VStack(alignment: .leading, spacing: 12) {
                            TCSectionHeader(title: "备注", systemImage: "note.text")
                            Text(place.note.isEmpty ? "没有备注" : place.note)
                                .foregroundStyle(place.note.isEmpty ? .secondary : .primary)
                                .textSelection(.enabled)
                        }
                        .tcCard()

                        VStack(alignment: .leading, spacing: 10) {
                            TCSectionHeader(title: "同步信息", systemImage: "arrow.triangle.2.circlepath")
                            LabeledContent("创建者", value: place.authorName)
                            LabeledContent("创建时间", value: place.createdAt.formatted(date: .abbreviated, time: .shortened))
                            LabeledContent("最后更新", value: place.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                        .tcCard()

                        TCNotice(
                            title: "无底图模式",
                            message: "此标注的坐标和备注已保存在本地，即使地图瓦片不可用也能查看。",
                            systemImage: "map",
                            tone: .info
                        )
                    }
                    .padding(TCDesign.pagePadding)
                }
                .tcPageBackground()
                .navigationTitle("地点详情")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if canManage {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu("地点操作", systemImage: "ellipsis.circle") {
                                Button("编辑", systemImage: "pencil") {
                                    router.present(.editPlace(id: place.id))
                                }
                                Button("删除", systemImage: "trash", role: .destructive) {
                                    isConfirmingDeletion = true
                                }
                            }
                        }
                    }
                }
                .confirmationDialog(
                    "删除“\(place.title)”？",
                    isPresented: $isConfirmingDeletion,
                    titleVisibility: .visible
                ) {
                    Button("删除", role: .destructive) {
                        Task {
                            await core.send(.deletePlace(id: place.id))
                            dismiss()
                        }
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("删除会同步给群组成员。")
                }
            } else {
                TCEmptyState(
                    title: "地点已不存在",
                    message: "它可能已由作者或群主删除。",
                    systemImage: "mappin.slash"
                )
            }
        }
    }
}

