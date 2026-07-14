import SwiftUI
import WiFiAware

struct DiagnosticsRootView: View {
    let coordinator: ExperimentCoordinator

    var body: some View {
        TabView {
            NavigationStack { OverviewView(coordinator: coordinator) }
                .tabItem { Label("总览", systemImage: "checklist") }
            NavigationStack { TransportDiagnosticsView(coordinator: coordinator) }
                .tabItem { Label("连接", systemImage: "antenna.radiowaves.left.and.right") }
            NavigationStack { LocationDiagnosticsView(coordinator: coordinator) }
                .tabItem { Label("定位", systemImage: "location") }
            NavigationStack { NearbyDiagnosticsView(coordinator: coordinator) }
                .tabItem { Label("UWB", systemImage: "dot.radiowaves.left.and.right") }
            NavigationStack { CallDiagnosticsView(coordinator: coordinator) }
                .tabItem { Label("来电", systemImage: "phone") }
            NavigationStack { LogDiagnosticsView(coordinator: coordinator) }
                .tabItem { Label("日志", systemImage: "waveform.path.ecg") }
        }
    }
}

private struct OverviewView: View {
    let coordinator: ExperimentCoordinator

    var body: some View {
        List {
            Section("实验会话") {
                LabeledContent("状态", value: coordinator.isLabRunning ? "运行中" : "已停止")
                LabeledContent("设备", value: coordinator.displayName)
                LabeledContent("实验 ID", value: coordinator.deviceID.uuidString)
                    .font(.caption.monospaced())
                Button(coordinator.isLabRunning ? "结束全部验证" : "开始全部验证") {
                    coordinator.isLabRunning ? coordinator.stopLab() : coordinator.startLab()
                }
                .buttonStyle(.borderedProminent)
                .tint(coordinator.isLabRunning ? .red : .accentColor)
            }

            Section("硬件与权限") {
                ForEach(coordinator.capabilityMetadata().sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    LabeledContent(key, value: value)
                }
                Button("请求本地通知权限") {
                    Task { await coordinator.notifications.requestAuthorization() }
                }
            }

            Section("边界") {
                Label("只支持 iPhone 真机和 iOS 26+；能力不足时不会切换到 Multipeer Connectivity。", systemImage: "iphone")
                Label("系统终止通过恢复回调和启动原因记录；用户强制退出后系统不会保证 BLE、定位或来电唤醒。", systemImage: "exclamationmark.triangle")
                Label("精确能耗仍需 Instruments Energy Log；App 同时每分钟记录电量、充电和热状态。", systemImage: "battery.50percent")
            }
        }
        .navigationTitle("第 11 节真机验证")
    }
}

private struct TransportDiagnosticsView: View {
    let coordinator: ExperimentCoordinator

    var body: some View {
        List {
            Section("11.1 Wi‑Fi Aware") {
                LabeledContent("数据连接", value: String(coordinator.dataConnectionCount))
                LabeledContent("realtime 语音连接", value: String(coordinator.voiceConnectionCount))
                WiFiAwarePairingControls(
                    isLabRunning: coordinator.isLabRunning,
                    pairedDeviceNames: coordinator.wifiPairedDeviceNames,
                    dataPublisherState: coordinator.wifiDataPublisherState,
                    voicePublisherState: coordinator.wifiVoicePublisherState,
                    discoveryState: coordinator.wifiDiscoveryState,
                    connectionState: coordinator.wifiConnectionState,
                    onStartPublishing: coordinator.startWiFiPublishing,
                    onEndpointSelected: coordinator.connectPickedEndpoint
                )
                if let error = coordinator.wifiLastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button("测小消息 RTT") { coordinator.sendPing() }
                Button("发送文字 + BLE dataAvailable") { coordinator.sendTextAndHint() }
                Button("主动 anti-entropy 拉取") { coordinator.requestAntiEntropy() }
                Button("发送 5 MiB 分块文件") { coordinator.sendLargeFile() }
            }

            Section("11.2 BLE 控制面") {
                LabeledContent("Central", value: coordinator.bluetooth.centralState)
                LabeledContent("Peripheral", value: coordinator.bluetooth.peripheralState)
                LabeledContent("已连接 peer", value: String(coordinator.bluetooth.connectedPeerCount))
                LabeledContent("恢复回调", value: String(coordinator.bluetooth.restorationCount))
                LabeledContent("已发 / 已收", value: "\(coordinator.bluetooth.sentMessageCount) / \(coordinator.bluetooth.receivedMessageCount)")
                Button("发送位置请求") { coordinator.requestLocation() }
                Button("开始 30 分钟重复请求") {
                    coordinator.bluetooth.startRepeatedRequestBenchmark()
                }
                Button("停止重复请求", role: .destructive) {
                    coordinator.bluetooth.cancelBenchmark()
                }
            }
        }
        .navigationTitle("离线连接")
    }
}

private struct LocationDiagnosticsView: View {
    @Bindable var coordinator: ExperimentCoordinator

    var body: some View {
        List {
            Section("11.3 策略") {
                Picker("实验策略", selection: $coordinator.selectedLocationStrategy) {
                    ForEach(LocationExperimentStrategy.allCases) { strategy in
                        Text(strategy.title).tag(strategy)
                    }
                }
                LabeledContent("运行状态", value: coordinator.location.isRunning ? "运行中" : "已停止")
                LabeledContent("权限", value: coordinator.location.authorizationDescription)
                LabeledContent("诊断", value: coordinator.location.diagnosticSummary)
                LabeledContent("样本数", value: String(coordinator.location.updateCount))
                Toggle("暂停位置共享", isOn: Bindable(coordinator.location).sharingPaused)
                HStack {
                    Button("开始") { coordinator.startLocationExperiment() }
                        .buttonStyle(.borderedProminent)
                    Button("停止", role: .destructive) { coordinator.stopLocationExperiment() }
                    Button("BLE 请求") { coordinator.requestLocation() }
                }
            }

            if let sample = coordinator.location.latestSample {
                Section("最后样本") {
                    LabeledContent("经纬度", value: String(format: "%.6f, %.6f", sample.latitude, sample.longitude))
                    LabeledContent("水平精度", value: String(format: "%.1f m", sample.horizontalAccuracy))
                    LabeledContent("样本年龄", value: String(format: "%.1f s", sample.age))
                    LabeledContent("速度", value: String(format: "%.2f m/s", sample.speed))
                    LabeledContent("静止", value: sample.stationary ? "是" : "否")
                }
            }

            Section("对比要求") {
                Text("三种策略必须在相同行走路线和请求序列下分别运行；导出结果包含响应率、样本年龄、水平精度、P50/P95 延迟、电量与后台诊断。")
            }
        }
        .navigationTitle("后台定位")
    }
}

private struct NearbyDiagnosticsView: View {
    let coordinator: ExperimentCoordinator

    var body: some View {
        List {
            Section("11.4 UWB") {
                LabeledContent("精确测距", value: coordinator.nearby.isSupported ? "支持" : "不支持")
                LabeledContent("方向", value: coordinator.nearby.supportsDirection ? "支持" : "不支持")
                LabeledContent("状态", value: coordinator.nearby.state)
                LabeledContent("并发 session", value: String(coordinator.nearby.activeSessionCount))
                if let limit = coordinator.nearby.observedResourceLimit {
                    LabeledContent("实测资源上限", value: String(limit))
                }
                if let distance = coordinator.nearby.latestDistance {
                    LabeledContent("距离", value: String(format: "%.3f m", distance))
                }
                if let direction = coordinator.nearby.latestDirection {
                    LabeledContent("方向向量", value: String(format: "%.3f, %.3f, %.3f", direction.x, direction.y, direction.z))
                }
                Button("经 BLE 请求精确位置") { coordinator.requestPrecisionLocation() }
                Button("结束全部 UWB session", role: .destructive) {
                    coordinator.nearby.stopAll(reason: "manual")
                }
            }

            Section("待确认请求") {
                if coordinator.pendingPrecisionRequests.isEmpty {
                    ContentUnavailableView("暂无请求", systemImage: "dot.radiowaves.left.and.right")
                }
                ForEach(coordinator.pendingPrecisionRequests) { request in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(request.senderID.uuidString).font(.caption.monospaced())
                        Text(request.isExpired ? "已过期" : "有效至 \(request.deadline.formatted(date: .omitted, time: .standard))")
                            .foregroundStyle(request.isExpired ? .red : .secondary)
                        HStack {
                            Button("提供精确位置") { coordinator.acceptPrecisionRequest(request) }
                                .buttonStyle(.borderedProminent)
                            Button("忽略") { coordinator.ignorePrecisionRequest(request) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
        .navigationTitle("前台精确定位")
    }
}

private struct CallDiagnosticsView: View {
    let coordinator: ExperimentCoordinator

    var body: some View {
        List {
            Section("11.5 离线来电") {
                LabeledContent("CallKit", value: coordinator.calls.callState)
                LabeledContent("语音数据连接", value: String(coordinator.voiceConnectionCount))
                if let callID = coordinator.calls.activeCallID {
                    LabeledContent("Call ID", value: callID.uuidString).font(.caption.monospaced())
                }
                if let boundary = coordinator.calls.lastBoundary {
                    Text(boundary).foregroundStyle(.red)
                }
                Button("向已连接成员发起离线来电") { coordinator.startOutgoingCall() }
                    .buttonStyle(.borderedProminent)
                Button("结束当前通话", role: .destructive) { coordinator.endCurrentCall() }
            }

            Section("验证说明") {
                Text("BLE 只承载 offer/answer/end。接听后录音数据通过 realtime Wi‑Fi Aware UDP 传输；CallKit 无法呈现时会记录错误边界，产品应降级为未接来电。")
            }
        }
        .navigationTitle("离线来电")
    }
}

private struct LogDiagnosticsView: View {
    let coordinator: ExperimentCoordinator

    var body: some View {
        List {
            Section {
                HStack {
                    Button("刷新") { Task { await coordinator.refreshDiagnostics() } }
                    Button("导出 JSON") { coordinator.exportDiagnostics() }
                    Button("清空", role: .destructive) { coordinator.clearDiagnostics() }
                }
                .buttonStyle(.borderless)
                if let url = coordinator.lastExportURL {
                    ShareLink(item: url) {
                        Label("分享 \(url.lastPathComponent)", systemImage: "square.and.arrow.up")
                    }
                }
            }

            Section("P50 / P95") {
                ForEach(coordinator.summaries) { summary in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(summary.kind.rawValue) · \(summary.name)").font(.headline)
                        Text("n=\(summary.count) · 成功率 \(summary.successRate, format: .percent.precision(.fractionLength(1))) · P50 \(format(summary.p50Milliseconds)) · P95 \(format(summary.p95Milliseconds))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("最近事件") {
                ForEach(coordinator.recentRecords) { record in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(record.name).font(.headline)
                            Spacer()
                            Text(record.outcome.rawValue)
                                .foregroundStyle(color(record.outcome))
                        }
                        Text("\(record.kind.rawValue) · \(record.phase) · \(record.timestamp.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let latency = record.latencyMilliseconds {
                            Text(String(format: "%.2f ms", latency)).font(.caption.monospacedDigit())
                        }
                    }
                }
            }
        }
        .navigationTitle("实验数据")
    }

    private func format(_ value: Double?) -> String {
        value.map { String(format: "%.1f ms", $0) } ?? "—"
    }

    private func color(_ outcome: ExperimentOutcome) -> Color {
        switch outcome {
        case .success: .green
        case .failure, .timeout: .red
        case .info, .skipped: .secondary
        }
    }
}
