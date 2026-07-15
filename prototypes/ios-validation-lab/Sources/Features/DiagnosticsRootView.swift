import SwiftUI

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
            Section("11.1 BLE 入群 + Bonjour P2P") {
                LabeledContent("数据连接", value: String(coordinator.dataConnectionCount))
                LabeledContent("realtime 语音连接", value: String(coordinator.voiceConnectionCount))
                GroupPairingControls(
                    isLabRunning: coordinator.isLabRunning,
                    groupID: coordinator.groupID,
                    createdGroupPIN: coordinator.createdGroupPIN,
                    bleMemberNames: coordinator.bluetooth.pairedMemberNames,
                    bonjourMemberNames: coordinator.bonjourDiscoveredMemberNames,
                    dataPublisherState: coordinator.dataPublisherState,
                    voicePublisherState: coordinator.voicePublisherState,
                    discoveryState: coordinator.discoveryState,
                    connectionState: coordinator.connectionState,
                    pairingError: coordinator.groupPairingError,
                    onCreateGroup: coordinator.createGroup,
                    onJoinGroup: coordinator.joinGroup,
                    onLeaveGroup: coordinator.leaveGroup
                )
                if let error = coordinator.transportLastError {
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

            Section("独立测试") {
                NavigationLink {
                    LocationUpdateFrequencyView(coordinator: coordinator)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("CLLocationUpdate 更新频率", systemImage: "timeline.selection")
                        Text("选择 LiveConfiguration，锁屏或进入后台后检查每次系统回调")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("后台定位")
    }
}

private struct LocationUpdateFrequencyView: View {
    @Bindable var coordinator: ExperimentCoordinator

    private var updates: [LocationFrequencyUpdate] {
        Array(coordinator.location.frequencyUpdates.reversed())
    }

    var body: some View {
        List {
            Section("测试设置") {
                Picker("LiveConfiguration", selection: $coordinator.selectedLiveConfiguration) {
                    ForEach(LocationLiveConfigurationOption.allCases) { configuration in
                        Text(configuration.title).tag(configuration)
                    }
                }
                .disabled(coordinator.location.isFrequencyTestRunning)

                Text(coordinator.selectedLiveConfiguration.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent(
                    "状态",
                    value: coordinator.location.isFrequencyTestRunning ? "正在记录" : "已停止"
                )
                LabeledContent("权限", value: coordinator.location.authorizationDescription)
                LabeledContent("回调数", value: String(coordinator.location.updateCount))
                LabeledContent(
                    "平均间隔",
                    value: formatSeconds(coordinator.location.averageFrequencyInterval)
                )
                LabeledContent(
                    "估算频率",
                    value: formatHertz(coordinator.location.estimatedFrequencyHertz)
                )
                LabeledContent(
                    "后台/锁屏回调",
                    value: String(coordinator.location.backgroundFrequencyUpdateCount)
                )
                if let startedAt = coordinator.location.frequencyTestStartedAt {
                    LabeledContent("开始时间", value: startedAt.formatted(date: .abbreviated, time: .standard))
                }
                if coordinator.location.discardedFrequencyUpdateCount > 0 {
                    LabeledContent(
                        "已从界面丢弃",
                        value: String(coordinator.location.discardedFrequencyUpdateCount)
                    )
                    .foregroundStyle(.orange)
                }

                HStack {
                    Button("开始新测试") { coordinator.startLocationFrequencyTest() }
                        .buttonStyle(.borderedProminent)
                    Button("停止", role: .destructive) { coordinator.stopLocationFrequencyTest() }
                        .disabled(!coordinator.location.isFrequencyTestRunning)
                }
            }

            Section("使用方式") {
                Text("开始后锁屏或将 app 放入后台。回来后按时间线检查回调接收时间与位置样本时间；两者差值可揭示系统是否延迟、排队后再投递更新。")
                Text("为了允许及时的后台回调，测试会同时持有 Always CLServiceSession 和 CLBackgroundActivitySession。系统仍会根据配置、移动状态、权限、设备状态和能耗策略调整频率。")
            }

            Section("回调时间线") {
                if updates.isEmpty {
                    ContentUnavailableView(
                        "尚无位置回调",
                        systemImage: "location.slash",
                        description: Text("选择配置并开始测试。")
                    )
                }
                ForEach(updates) { update in
                    NavigationLink {
                        LocationFrequencyUpdateDetailView(update: update)
                    } label: {
                        LocationFrequencyUpdateRow(update: update)
                    }
                }
            }
        }
        .navigationTitle("更新频率")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !updates.isEmpty && !coordinator.location.isFrequencyTestRunning {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空") { coordinator.location.clearFrequencyUpdates() }
                }
            }
        }
    }

    private func formatSeconds(_ value: TimeInterval?) -> String {
        value.map { String(format: "%.3f s", $0) } ?? "—"
    }

    private func formatHertz(_ value: Double?) -> String {
        value.map { String(format: "%.3f Hz", $0) } ?? "—"
    }
}

private struct LocationFrequencyUpdateRow: View {
    let update: LocationFrequencyUpdate

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("#\(update.sequence)")
                    .font(.headline.monospacedDigit())
                Text(update.receivedAt.formatted(date: .omitted, time: .standard))
                    .font(.headline.monospacedDigit())
                Spacer()
                Label(
                    update.appWasForeground ? "前台" : "后台",
                    systemImage: update.appWasForeground ? "sun.max" : "moon"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Text(update.hasLocation ? "位置" : "诊断")
                Text(update.configuration.title)
                Text("stationary: \(update.stationary ? "true" : "false")")
                if let interval = update.intervalSincePrevious {
                    Text("间隔 \(interval, format: .number.precision(.fractionLength(2))) s")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(update.hasLocation ? Color.secondary : Color.orange)
        }
    }
}

private struct LocationFrequencyUpdateDetailView: View {
    let update: LocationFrequencyUpdate

    var body: some View {
        List {
            Section("投递") {
                LabeledContent("序号", value: String(update.sequence))
                LabeledContent("LiveConfiguration", value: update.configuration.title)
                LabeledContent("接收时间", value: preciseDate(update.receivedAt))
                optionalDate("位置时间", update.locationTimestamp)
                optionalSeconds("相邻回调间隔", update.intervalSincePrevious)
                optionalSeconds("投递延迟", update.deliveryDelay)
                LabeledContent("App 状态", value: update.appWasForeground ? "前台" : "后台/锁屏")
                boolean("stationary", update.stationary)
            }

            Section("位置") {
                optionalNumber("纬度", update.latitude, digits: 7)
                optionalNumber("经度", update.longitude, digits: 7)
                optionalMeasurement("高度", update.altitude, unit: "m")
                optionalMeasurement("水平精度", update.horizontalAccuracy, unit: "m")
                optionalMeasurement("垂直精度", update.verticalAccuracy, unit: "m")
                optionalMeasurement("速度", update.speed, unit: "m/s")
                optionalMeasurement("速度精度", update.speedAccuracy, unit: "m/s")
                optionalMeasurement("航向", update.course, unit: "°")
                optionalMeasurement("航向精度", update.courseAccuracy, unit: "°")
                LabeledContent("楼层", value: update.floorLevel.map(String.init) ?? "—")
                optionalBoolean("软件模拟", update.isSimulatedBySoftware)
                optionalBoolean("外部配件产生", update.isProducedByAccessory)
            }

            Section("CLLocationUpdate 状态") {
                boolean("authorizationDenied", update.authorizationDenied)
                boolean("authorizationDeniedGlobally", update.authorizationDeniedGlobally)
                boolean("authorizationRestricted", update.authorizationRestricted)
                boolean("insufficientlyInUse", update.insufficientlyInUse)
                boolean("locationUnavailable", update.locationUnavailable)
                boolean("accuracyLimited", update.accuracyLimited)
                boolean("serviceSessionRequired", update.serviceSessionRequired)
                boolean("authorizationRequestInProgress", update.authorizationRequestInProgress)
            }
        }
        .navigationTitle("回调 #\(update.sequence)")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func boolean(_ title: String, _ value: Bool) -> some View {
        LabeledContent(title, value: value ? "true" : "false")
            .foregroundStyle(value ? Color.orange : Color.primary)
    }

    @ViewBuilder
    private func optionalBoolean(_ title: String, _ value: Bool?) -> some View {
        LabeledContent(title, value: value.map { $0 ? "true" : "false" } ?? "—")
    }

    @ViewBuilder
    private func optionalDate(_ title: String, _ value: Date?) -> some View {
        LabeledContent(title, value: value.map(preciseDate) ?? "—")
    }

    @ViewBuilder
    private func optionalSeconds(_ title: String, _ value: TimeInterval?) -> some View {
        LabeledContent(title, value: value.map { String(format: "%.3f s", $0) } ?? "—")
    }

    @ViewBuilder
    private func optionalNumber(_ title: String, _ value: Double?, digits: Int) -> some View {
        LabeledContent(title, value: value.map { String(format: "%.*f", digits, $0) } ?? "—")
    }

    @ViewBuilder
    private func optionalMeasurement(_ title: String, _ value: Double?, unit: String) -> some View {
        LabeledContent(title, value: value.map { String(format: "%.3f %@", $0, unit) } ?? "—")
    }

    private func preciseDate(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
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
                Text("BLE 承载入群认证和 offer/answer/end。接听后录音数据通过启用 peer-to-peer 的 Bonjour UDP 传输；CallKit 无法呈现时会记录错误边界，产品应降级为未接来电。")
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
