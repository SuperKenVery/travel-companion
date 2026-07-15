import SwiftUI

@MainActor
struct CapabilityStatusView: View {
    @Environment(TravelCore.self) private var core

    private var snapshot: AppSnapshot { core.snapshot }

    var body: some View {
        List {
            Section {
                CapabilityRow(
                    title: "蓝牙",
                    detail: "成员发现、控制提示和后台敲门",
                    systemImage: "antenna.radiowaves.left.and.right",
                    blocker: blocker(matching: ["bluetooth", "蓝牙"])
                )
                CapabilityRow(
                    title: "本地网络",
                    detail: "Bonjour/AWDL 内容同步和实时音频",
                    systemImage: "network",
                    blocker: blocker(matching: ["network", "transport", "本地网络"])
                )
                CapabilityRow(
                    title: "位置",
                    detail: "旅行期间的最后位置与后台更新",
                    systemImage: "location.fill",
                    blocker: blocker(matching: ["location", "位置"])
                )
                CapabilityRow(
                    title: "精确测距",
                    detail: "双方前台并确认后的 UWB 距离与方向",
                    systemImage: "dot.scope",
                    blocker: blocker(matching: ["ranging", "uwb", "nearby", "精确"])
                )
                CapabilityRow(
                    title: "本地通知",
                    detail: "后台位置请求、消息和来电提醒",
                    systemImage: "bell.badge.fill",
                    blocker: blocker(matching: ["notification", "通知"])
                )
            }

            if !snapshot.lifecycle.blockers.isEmpty {
                Section("如何恢复") {
                    ForEach(snapshot.lifecycle.blockers) { blocker in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(blocker.capability)
                                .font(.headline)
                            Text(blocker.reason)
                                .font(.subheadline)
                            if let suggestion = blocker.recoverySuggestion {
                                Text(suggestion)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            Section("系统边界") {
                Text("用户强制退出 App、撤回权限或系统不给予后台执行时间时，无法保证即时位置、消息提醒或来电；重新启动或重连后会继续补同步。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("系统能力")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func blocker(matching needles: [String]) -> CapabilityBlocker? {
        snapshot.lifecycle.blockers.first { blocker in
            let haystack = blocker.capability.lowercased()
            return needles.contains { haystack.contains($0.lowercased()) }
        }
    }
}

private struct CapabilityRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let blocker: CapabilityBlocker?

    private var isBlocked: Bool { blocker != nil }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(isBlocked ? .orange : .accentColor)
                .frame(width: 30)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(blocker?.reason ?? detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            TCStatusPill(
                text: isBlocked ? "受限" : "可用",
                tone: isBlocked ? .warning : .success,
                systemImage: isBlocked ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
            )
        }
        .accessibilityElement(children: .combine)
    }

}
