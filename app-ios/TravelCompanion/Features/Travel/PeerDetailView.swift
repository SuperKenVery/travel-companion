import SwiftUI

@MainActor
struct PeerDetailView: View {
    @Environment(TravelCore.self) private var core

    let peerID: String
    @State private var isRequestingPrecision = false
    @State private var isStartingCall = false

    private var peer: PeerSnapshot? {
        core.snapshot.peers.first { $0.id == peerID }
    }

    var body: some View {
        Group {
            if let peer {
                ScrollView {
                    VStack(spacing: 16) {
                        identityHeader(peer)
                        actionCard(peer)
                        locationCard(peer)
                        rangingCard(peer)
                    }
                    .padding(TCDesign.pagePadding)
                }
                .tcPageBackground()
                .navigationTitle(peer.displayName)
                .navigationBarTitleDisplayMode(.inline)
            } else {
                TCEmptyState(
                    title: "成员已不在群组中",
                    message: "成员资料可能在同步后发生了变化。",
                    systemImage: "person.crop.circle.badge.questionmark"
                )
            }
        }
    }

    private func identityHeader(_ peer: PeerSnapshot) -> some View {
        VStack(spacing: 10) {
            TCPeerAvatar(name: peer.displayName, isConnected: peer.isReachable, size: 76)
            Text(peer.displayName)
                .font(.title2.bold())
            HStack(spacing: 8) {
                TCStatusPill(
                    text: peer.isReachable ? "当前可达" : "暂时离线",
                    tone: peer.isReachable ? .success : .neutral
                )
                if peer.locationSharingPaused {
                    TCStatusPill(text: "位置已暂停", tone: .warning, systemImage: "location.slash")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .tcCard()
    }

    private func actionCard(_ peer: PeerSnapshot) -> some View {
        VStack(spacing: 10) {
            Button {
                isRequestingPrecision = true
                Task {
                    await core.send(.requestPrecision(peerID: peer.id))
                    isRequestingPrecision = false
                }
            } label: {
                Label(
                    isRequestingPrecision ? "正在发送请求…" : "请求精确位置",
                    systemImage: "location.magnifyingglass"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!peer.isReachable || peer.locationSharingPaused || isRequestingPrecision)
            .accessibilityHint("对方确认后，双方在前台时启动近距离精确测距")

            Button {
                isStartingCall = true
                Task {
                    await core.send(.startCall(peerID: peer.id))
                    isStartingCall = false
                }
            } label: {
                Label(isStartingCall ? "正在呼叫…" : "离线语音通话", systemImage: "phone")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!peer.isReachable || core.snapshot.activeCall != nil || isStartingCall)
        }
        .tcCard()
    }

    private func locationCard(_ peer: PeerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            TCSectionHeader(title: "最后位置", systemImage: "location")

            if let location = peer.location {
                HStack(spacing: 8) {
                    TCStatusPill(
                        text: location.source.uppercased(),
                        tone: .info,
                        systemImage: "antenna.radiowaves.left.and.right"
                    )
                    TCStatusPill(
                        text: location.isStale ? "数据已过期" : "位置较新",
                        tone: location.isStale ? .warning : .success
                    )
                }

                HStack(spacing: 10) {
                    TCMetric(
                        title: "距离",
                        value: location.distanceMeters?.formattedDistance ?? "—",
                        systemImage: "ruler"
                    )
                    TCMetric(
                        title: "方位",
                        value: location.bearingDegrees.map { "\(Int($0.rounded()))°" } ?? "—",
                        systemImage: "safari"
                    )
                    TCMetric(
                        title: "精度",
                        value: location.horizontalAccuracyMeters.formattedDistance,
                        systemImage: "scope"
                    )
                }

                Divider()

                LabeledContent("纬度", value: location.latitude.formatted(.number.precision(.fractionLength(6))))
                LabeledContent("经度", value: location.longitude.formatted(.number.precision(.fractionLength(6))))
                LabeledContent("采样时间", value: location.sampledAt.formatted(date: .abbreviated, time: .standard))
                LabeledContent("本机收到", value: location.receivedAt.formatted(date: .omitted, time: .standard))
            } else {
                Text("尚未收到该成员的位置。仍可在成员重新连接后自动同步。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .tcCard()
    }

    private func rangingCard(_ peer: PeerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TCSectionHeader(
                title: "近距离精确测距",
                subtitle: "距离和方向是两个独立能力；方向不可用时立即回退到 GPS。",
                systemImage: "dot.scope"
            )

            if let ranging = peer.ranging {
                HStack(spacing: 10) {
                    TCMetric(
                        title: LocalizedStringKey("精确距离 · \(ranging.distanceSource)"),
                        value: ranging.distanceMeters?.formattedDistance ?? "不可用",
                        systemImage: "arrow.left.and.right",
                        tint: .purple
                    )
                    TCMetric(
                        title: LocalizedStringKey("方向 · \(ranging.directionSource)"),
                        value: ranging.directionDegrees.map { "\(Int($0.rounded()))°" }
                            ?? peer.location?.bearingDegrees.map { "\(Int($0.rounded()))° GPS" }
                            ?? "不可用",
                        systemImage: "location.north",
                        tint: .purple
                    )
                }
                Text("更新于 \(ranging.updatedAt.formattedRelative)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("当前未建立 UWB 会话。对方接受精确位置请求后会在这里显示结果。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .tcCard()
    }
}
