#if DEBUG
import SwiftUI

@MainActor
struct DiagnosticsView: View {
    @Environment(TravelCore.self) private var core

    private var diagnostics: DiagnosticsSnapshot { core.snapshot.diagnostics }

    var body: some View {
        List {
            Section("模块状态") {
                DiagnosticStateRow(title: "BLE 控制面", state: diagnostics.bleState, systemImage: "antenna.radiowaves.left.and.right")
                DiagnosticStateRow(title: "高速数据面", state: diagnostics.transportState, systemImage: "network")
                DiagnosticStateRow(title: "位置", state: diagnostics.locationState, systemImage: "location")
                DiagnosticStateRow(title: "UWB 测距", state: diagnostics.rangingState, systemImage: "dot.scope")
            }

            Section("复制与同步") {
                LabeledContent("已连接成员", value: "\(diagnostics.connectedPeerCount)")
                LabeledContent("事件总数", value: "\(diagnostics.eventCount)")
                LabeledContent("待复制事件", value: "\(diagnostics.pendingReplicationCount)")
                LabeledContent(
                    "最后同步",
                    value: diagnostics.lastSyncAt?.formatted(date: .abbreviated, time: .standard) ?? "尚无"
                )
            }

            Section("核心快照") {
                LabeledContent("Snapshot revision", value: "\(core.snapshot.revision)")
                LabeledContent("Protocol version", value: "\(core.snapshot.protocolVersion)")
                LabeledContent("Lifecycle phase", value: core.snapshot.lifecycle.phase)
                LabeledContent("前台", value: core.snapshot.lifecycle.isForeground ? "是" : "否")
            }

            Section("最近事件") {
                if diagnostics.recentEvents.isEmpty {
                    Text("暂无诊断事件")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(diagnostics.recentEvents.sorted { $0.timestamp > $1.timestamp }) { event in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(event.subsystem)
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text(event.timestamp.formatted(date: .omitted, time: .standard))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(event.message)
                                .font(.subheadline)
                                .textSelection(.enabled)
                            TCStatusPill(text: event.level.uppercased(), tone: tone(for: event.level))
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .navigationTitle("连接与同步诊断")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func tone(for level: String) -> TCStatusTone {
        switch level.lowercased() {
        case "error", "fault": .danger
        case "warning", "warn": .warning
        case "debug", "trace": .neutral
        default: .info
        }
    }
}

private struct DiagnosticStateRow: View {
    let title: String
    let state: String
    let systemImage: String

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(state)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
#endif

