import SwiftUI

@MainActor
struct TravelOverviewView: View {
    @Environment(TravelCore.self) private var core
    @Environment(AppRouter.self) private var router

    @State private var isChangingTravelState = false
    @State private var isLeavingGroup = false

    private var snapshot: AppSnapshot { core.snapshot }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                TravelSessionCard(
                    lifecycle: snapshot.lifecycle,
                    isBusy: isChangingTravelState,
                    onToggleSession: toggleTravelSession,
                    onSetSharing: setLocationSharing
                )

                if let error = snapshot.lifecycle.lastError {
                    TCNotice(
                        title: "操作未完成",
                        message: error,
                        systemImage: "exclamationmark.triangle.fill",
                        tone: .danger
                    )
                }

                ForEach(snapshot.lifecycle.blockers) { blocker in
                    TCNotice(
                        title: blocker.capability,
                        message: [blocker.reason, blocker.recoverySuggestion]
                            .compactMap { $0 }
                            .joined(separator: "\n"),
                        systemImage: "exclamationmark.shield.fill",
                        tone: .warning
                    )
                }

                if !snapshot.pendingPrecisionRequests.isEmpty {
                    PendingPrecisionSection(requests: snapshot.pendingPrecisionRequests)
                }

                if let group = snapshot.group {
                    GroupSummaryCard(group: group, isLeaving: isLeavingGroup) {
                        isLeavingGroup = true
                    }

                    RadarSection(peers: snapshot.peers)
                    PeerListSection(peers: snapshot.peers)
                } else {
                    TCEmptyState(
                        title: "尚未加入旅行群组",
                        message: "面对面创建群组或输入同行伙伴给你的 PIN。全程不需要互联网。",
                        systemImage: "person.3.sequence.fill",
                        actionTitle: "创建群组"
                    ) {
                        router.present(.createGroup)
                    }

                    Button("使用 PIN 加入群组") {
                        router.present(.joinGroup)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(TCDesign.pagePadding)
        }
        .tcPageBackground()
        .navigationTitle("同行")
        .toolbar {
            if snapshot.group == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("群组", systemImage: "person.3") {
                        Button("创建群组", systemImage: "plus") {
                            router.present(.createGroup)
                        }
                        Button("使用 PIN 加入", systemImage: "number") {
                            router.present(.joinGroup)
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "离开当前群组？",
            isPresented: $isLeavingGroup,
            titleVisibility: .visible
        ) {
            Button("离开群组", role: .destructive) {
                Task { await core.send(.leaveGroup) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("本机将停止接收这个群组的新消息、位置和行程更新。")
        }
    }

    private func toggleTravelSession() {
        guard !isChangingTravelState else { return }
        isChangingTravelState = true
        let command: CoreCommand = snapshot.lifecycle.isTraveling ? .endTravel : .startTravel
        Task {
            await core.send(command)
            isChangingTravelState = false
        }
    }

    private func setLocationSharing(_ enabled: Bool) {
        Task { await core.send(.setLocationSharing(enabled)) }
    }
}

private struct TravelSessionCard: View {
    let lifecycle: LifecycleSnapshot
    let isBusy: Bool
    let onToggleSession: () -> Void
    let onSetSharing: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Label(
                        lifecycle.isTraveling ? "旅行进行中" : "旅行尚未开始",
                        systemImage: lifecycle.isTraveling ? "figure.walk.motion" : "pause.circle"
                    )
                    .font(.title3.weight(.bold))

                    Text(sessionDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                TCStatusPill(
                    text: lifecycle.isTraveling ? "运行中" : "已停止",
                    tone: lifecycle.isTraveling ? .success : .neutral,
                    systemImage: lifecycle.isTraveling ? "dot.radiowaves.left.and.right" : nil
                )
            }

            Toggle(
                isOn: Binding(
                    get: { lifecycle.locationSharingEnabled },
                    set: { enabled in onSetSharing(enabled) }
                )
            ) {
                Label("共享我的位置", systemImage: "location.fill")
            }
            .disabled(!lifecycle.isTraveling)
            .accessibilityHint(lifecycle.isTraveling ? "与当前群组成员共享位置" : "请先开始旅行")

            Button(action: onToggleSession) {
                HStack {
                    if isBusy {
                        ProgressView()
                    }
                    Text(lifecycle.isTraveling ? "结束旅行" : "开始旅行")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(lifecycle.isTraveling ? .red : .accentColor)
            .disabled(isBusy)
        }
        .tcCard()
    }

    private var sessionDescription: String {
        if lifecycle.isTraveling {
            return lifecycle.locationSharingEnabled
                ? "正在离线发现同行伙伴并按系统允许更新位置。"
                : "连接仍保持，但你的新位置不会分享给其他成员。"
        }
        return "开始后才会启用蓝牙发现、本地网络和后台位置。"
    }
}

private struct GroupSummaryCard: View {
    let group: GroupSnapshot
    let isLeaving: Bool
    let onLeave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.name)
                        .font(.title2.bold())
                    Text("\(group.members.count) 位成员 · Epoch \(group.epoch)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "person.3.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }

            if let pin = group.invitePIN, !pin.isEmpty {
                HStack {
                    Label("入群 PIN", systemImage: "number")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(pin)
                        .font(.title3.monospaced().weight(.semibold))
                        .textSelection(.enabled)
                        .accessibilityLabel("入群 PIN \(pin)")
                }
            }

            Button("离开群组", role: .destructive, action: onLeave)
                .font(.subheadline)
                .disabled(isLeaving)
        }
        .tcCard()
    }
}

private struct RadarSection: View {
    let peers: [PeerSnapshot]

    private var markers: [TCRadarMarker] {
        let distances = peers.compactMap { effectiveDistance(for: $0) }
        let scale = max(distances.max() ?? 1, 1)

        return peers.compactMap { peer in
            guard let bearing = effectiveBearing(for: peer),
                  let distance = effectiveDistance(for: peer)
            else { return nil }
            return TCRadarMarker(
                id: peer.id,
                name: peer.displayName,
                bearing: bearing,
                normalizedDistance: min(distance / scale, 1),
                isPrecise: peer.ranging?.distanceMeters != nil,
                isStale: peer.ranging?.distanceMeters == nil && (peer.location?.isStale ?? true)
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TCSectionHeader(
                title: "离线雷达",
                subtitle: "方向朝上代表北方；紫色成员正在使用近距离精确测距。",
                systemImage: "scope"
            )

            if markers.isEmpty {
                TCNotice(
                    title: "等待位置",
                    message: "成员可达并分享首个位置后，会出现在这里。无地图底图也能使用。",
                    systemImage: "location.slash",
                    tone: .neutral
                )
            } else {
                TCRadar(markers: markers)
                    .frame(maxWidth: 360)
                    .frame(maxWidth: .infinity)
            }
        }
        .tcCard()
    }

    private func effectiveDistance(for peer: PeerSnapshot) -> Double? {
        peer.ranging?.distanceMeters ?? peer.location?.distanceMeters
    }

    private func effectiveBearing(for peer: PeerSnapshot) -> Double? {
        peer.ranging?.directionDegrees ?? peer.location?.bearingDegrees
    }
}

private struct PeerListSection: View {
    let peers: [PeerSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TCSectionHeader(
                title: "成员",
                subtitle: "位置时间和来源始终显示，过期数据不会伪装成实时位置。",
                systemImage: "person.2"
            )

            if peers.isEmpty {
                Text("附近还没有发现其他成员。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                ForEach(peers) { peer in
                    NavigationLink {
                        PeerDetailView(peerID: peer.id)
                    } label: {
                        PeerRow(peer: peer)
                    }
                    .buttonStyle(.plain)

                    if peer.id != peers.last?.id {
                        Divider()
                    }
                }
            }
        }
        .tcCard()
    }
}

private struct PeerRow: View {
    let peer: PeerSnapshot

    var body: some View {
        HStack(spacing: 12) {
            TCPeerAvatar(name: peer.displayName, isConnected: peer.isReachable)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(peer.displayName)
                        .font(.headline)
                    if peer.locationSharingPaused {
                        Image(systemName: "location.slash.fill")
                            .foregroundStyle(.orange)
                            .accessibilityLabel("已暂停位置共享")
                    }
                }

                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                if let distance = effectiveDistance {
                    Text(distance.formattedDistance)
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                }
                TCStatusPill(
                    text: peer.isReachable ? "可达" : "离线",
                    tone: peer.isReachable ? .success : .neutral
                )
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("查看成员位置和精确定位操作")
    }

    private var effectiveDistance: Double? {
        peer.ranging?.distanceMeters ?? peer.location?.distanceMeters
    }

    private var detail: String {
        if let ranging = peer.ranging, ranging.distanceSource == "uwb" {
            return "UWB · \(ranging.updatedAt.formattedRelative)"
        }
        guard let location = peer.location else {
            return peer.lastSeenAt.map { "最后出现 \($0.formattedRelative)" } ?? "尚无位置"
        }
        let freshness = location.isStale ? "已过期" : location.sampledAt.formattedRelative
        return "\(location.source.uppercased()) · \(freshness)"
    }
}

private struct PendingPrecisionSection: View {
    @Environment(TravelCore.self) private var core

    let requests: [PrecisionRequestSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TCSectionHeader(
                title: "精确位置请求",
                subtitle: "只有你明确同意且双方都在前台时才会启动 UWB。",
                systemImage: "location.magnifyingglass"
            )

            ForEach(requests) { request in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TCPeerAvatar(name: request.requesterName, isConnected: true, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(request.requesterName) 正在寻找你")
                                .font(.headline)
                            Text("\(request.expiresAt.formattedRelative)到期")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Button("忽略", role: .destructive) {
                            Task {
                                await core.send(.respondPrecision(requestID: request.id, accept: false))
                            }
                        }
                        .buttonStyle(.bordered)

                        Button("提供精确位置") {
                            Task {
                                await core.send(.respondPrecision(requestID: request.id, accept: true))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(12)
                .background(TCDesign.subtleBackground, in: .rect(cornerRadius: TCDesign.compactRadius))
            }
        }
        .tcCard()
    }
}

extension Double {
    var formattedDistance: String {
        Measurement(value: self, unit: UnitLength.meters)
            .formatted(
                .measurement(
                    width: .abbreviated,
                    usage: .road,
                    numberFormatStyle: .number.precision(.fractionLength(0...1))
                )
            )
    }
}

extension Date {
    var formattedRelative: String {
        formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}
