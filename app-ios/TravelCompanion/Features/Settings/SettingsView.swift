import SwiftUI

@MainActor
struct SettingsView: View {
    @Environment(TravelCore.self) private var core

    @State private var isConfirmingClearData = false
    @State private var isConfirmingEndTravel = false
    @State private var isClearingData = false

    private var snapshot: AppSnapshot { core.snapshot }

    var body: some View {
        Form {
            Section {
                LabeledContent("名称", value: snapshot.identity.displayName)
                LabeledContent("Peer ID") {
                    Text(snapshot.identity.peerID.isEmpty ? "尚未生成" : snapshot.identity.peerID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("本机身份")
            } footer: {
                Text("身份密钥保存在本机安全存储中，不需要云账户。")
            }

            Section {
                HStack {
                    Label("运行状态", systemImage: "figure.walk.motion")
                    Spacer()
                    TCStatusPill(
                        text: snapshot.lifecycle.isTraveling ? "旅行中" : "已停止",
                        tone: snapshot.lifecycle.isTraveling ? .success : .neutral
                    )
                }

                Toggle(
                    isOn: Binding(
                        get: { snapshot.lifecycle.locationSharingEnabled },
                        set: { enabled in
                            Task { await core.send(.setLocationSharing(enabled)) }
                        }
                    )
                ) {
                    Label("共享我的位置", systemImage: "location.fill")
                }
                .disabled(!snapshot.lifecycle.isTraveling)

                if snapshot.lifecycle.isTraveling {
                    Button("结束旅行", role: .destructive) {
                        isConfirmingEndTravel = true
                    }
                } else {
                    Button("开始旅行", systemImage: "play.fill") {
                        Task { await core.send(.startTravel) }
                    }
                    .disabled(snapshot.group == nil)
                }
            } header: {
                Text("旅行会话")
            } footer: {
                Text("只有你明确开始旅行后，App 才会启用附近发现和按系统允许的后台位置更新。")
            }

            Section("群组") {
                if let group = snapshot.group {
                    LabeledContent("名称", value: group.name)
                    LabeledContent("成员", value: "\(group.members.count)")
                    if let pin = group.invitePIN {
                        LabeledContent("入群 PIN") {
                            Text(pin)
                                .font(.body.monospaced().weight(.semibold))
                                .textSelection(.enabled)
                        }
                    }
                } else {
                    Text("尚未加入群组")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                NavigationLink {
                    CapabilityStatusView()
                } label: {
                    HStack {
                        Label("系统能力", systemImage: "checklist")
                        Spacer()
                        if !snapshot.lifecycle.blockers.isEmpty {
                            TCStatusPill(text: "\(snapshot.lifecycle.blockers.count) 项受限", tone: .warning)
                        }
                    }
                }

                if let error = snapshot.lifecycle.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.subheadline)
                }
            } header: {
                Text("权限与可用性")
            } footer: {
                Text("权限被拒绝、蓝牙或 Wi‑Fi 关闭时，页面会准确说明受影响的功能，不会尝试绕过系统限制。")
            }

            Section("隐私说明") {
                PrivacyPurposeRow(
                    systemImage: "location.fill",
                    title: "位置",
                    detail: "在旅行期间向群组成员提供最后位置、距离和方向；暂停共享后不再发送新位置。"
                )
                PrivacyPurposeRow(
                    systemImage: "antenna.radiowaves.left.and.right",
                    title: "蓝牙",
                    detail: "发现附近群组成员，并传递入群、位置请求、新内容和来电等小型控制提示。"
                )
                PrivacyPurposeRow(
                    systemImage: "network",
                    title: "本地网络",
                    detail: "在附近设备间直接同步消息、图片、语音、地点和 Trip.md，不访问公网服务。"
                )
                PrivacyPurposeRow(
                    systemImage: "dot.scope",
                    title: "精确测距",
                    detail: "仅在双方前台且对方明确同意精确位置请求时使用 UWB。"
                )
            }

            #if DEBUG
            Section {
                NavigationLink {
                    DiagnosticsView()
                } label: {
                    Label("连接与同步诊断", systemImage: "stethoscope")
                }
            } header: {
                Text("开发")
            } footer: {
                Text("此页面仅在 Debug 构建中可见。")
            }
            #endif

            Section {
                Button("清除旅行数据", systemImage: "trash", role: .destructive) {
                    isConfirmingClearData = true
                }
                .disabled(isClearingData)
            } header: {
                Text("本机数据")
            } footer: {
                Text("清除本机当前旅行的消息、资源、位置历史和文档副本。身份密钥是否保留由核心的数据策略决定。")
            }

            Section("关于") {
                LabeledContent("协议版本", value: "\(snapshot.protocolVersion)")
                LabeledContent("快照版本", value: "\(snapshot.revision)")
            }
        }
        .navigationTitle("设置")
        .confirmationDialog(
            "结束当前旅行？",
            isPresented: $isConfirmingEndTravel,
            titleVisibility: .visible
        ) {
            Button("结束旅行", role: .destructive) {
                Task { await core.send(.endTravel) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将停止新的位置采集、附近广播、扫描和精确测距，并释放短期租约。")
        }
        .confirmationDialog(
            "清除本机旅行数据？",
            isPresented: $isConfirmingClearData,
            titleVisibility: .visible
        ) {
            Button("清除数据", role: .destructive) {
                isClearingData = true
                Task {
                    await core.send(.clearTripData)
                    isClearingData = false
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作不可撤销；其他成员设备上的数据不会因此自动删除。")
        }
    }
}

private struct PrivacyPurposeRow: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 24)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
