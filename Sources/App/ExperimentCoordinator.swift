import CallKit
import CoreBluetooth
import CoreLocation
import Foundation
import NearbyInteraction
import Network
import Observation
import OSLog
import UIKit
import WiFiAware

private let coordinatorLogger = Logger(
    subsystem: "com.ken.TravelCompanionValidation",
    category: "Coordinator"
)

@MainActor
@Observable
final class ExperimentCoordinator {
    let deviceID: UUID
    let displayName: String
    let bluetooth: BluetoothControlPlane
    let location: LocationExperimentEngine
    let nearby: NearbyInteractionExperiment
    let calls: OfflineCallManager
    let notifications = LocalNotificationManager()

    private let logStore: ExperimentLogStore
    private let eventStore: ValidationEventStore
    private let transferStore: ResourceTransferStore
    private let wifi: WiFiAwareExperiment
    private var energyTask: Task<Void, Never>?
    private var pendingControlStarts: [UUID: ContinuousClock.Instant] = [:]
    private var precisionCooldowns: [UUID: Date] = [:]
    private var notificationTask: Task<Void, Never>?
    private var diagnosticsRefreshTask: Task<Void, Never>?
    private var mainActorHeartbeatTask: Task<Void, Never>?
    private var processHeartbeatTask: Task<Void, Never>?

    private(set) var isLabRunning = false
    private(set) var recentRecords: [ExperimentRecord] = []
    private(set) var summaries: [MetricSummary] = []
    private(set) var pendingPrecisionRequests: [PendingPrecisionRequest] = []
    private(set) var dataConnectionCount = 0
    private(set) var voiceConnectionCount = 0
    private(set) var wifiPairedDeviceNames: [String] = []
    private(set) var wifiDataPublisherState = "未启动"
    private(set) var wifiVoicePublisherState = "未启动"
    private(set) var wifiDiscoveryState = "未启动"
    private(set) var wifiConnectionState = "未连接"
    private(set) var wifiLastError: String?
    private(set) var lastExportURL: URL?
    private(set) var lastError: String?
    private(set) var openedPrecisionRequestID: UUID?
    var selectedLocationStrategy: LocationExperimentStrategy = .hybrid
    var isForeground = true

    init() {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: "validationDeviceID").flatMap(UUID.init(uuidString:)) {
            deviceID = stored
        } else {
            let created = UUID()
            defaults.set(created.uuidString, forKey: "validationDeviceID")
            deviceID = created
        }
        displayName = UIDevice.current.name
        let logStore = ExperimentLogStore()
        let eventStore = ValidationEventStore()
        let transferStore = ResourceTransferStore()
        let sink: @Sendable (ExperimentRecord) async -> Void = { record in
            await logStore.append(record)
        }
        self.logStore = logStore
        self.eventStore = eventStore
        self.transferStore = transferStore
        bluetooth = BluetoothControlPlane(deviceID: deviceID, eventSink: sink)
        location = LocationExperimentEngine(eventSink: sink)
        nearby = NearbyInteractionExperiment(eventSink: sink)
        calls = OfflineCallManager(deviceID: deviceID, eventSink: sink)
        wifi = WiFiAwareExperiment(
            deviceID: deviceID,
            displayName: displayName,
            eventStore: eventStore,
            transferStore: transferStore,
            eventSink: sink
        )
        bind()
    }

    func restoreIfNeeded() async {
        coordinatorLogger.notice("restoreIfNeeded begin")
        startDebugHeartbeatsIfNeeded()
        coordinatorLogger.debug("restore notification observer begin")
        notificationTask = Task { [weak self] in
            let stream = NotificationCenter.default.notifications(named: .precisionNotificationOpened)
            coordinatorLogger.debug("restore notification observer ready")
            for await notification in stream {
                coordinatorLogger.notice("notification stream received begin")
                guard let self else {
                    coordinatorLogger.error("notification stream coordinator released")
                    return
                }
                let value = notification.userInfo?["requestID"] as? String
                self.openedPrecisionRequestID = value.flatMap(UUID.init(uuidString:))
                coordinatorLogger.notice("notification stream received end requestID=\(value ?? "none", privacy: .public)")
            }
        }
        coordinatorLogger.debug("refresh notification authorization begin")
        await notifications.refreshAuthorization()
        coordinatorLogger.debug("refresh notification authorization end")
        coordinatorLogger.debug("record capabilities begin")
        await recordCapabilities()
        coordinatorLogger.debug("record capabilities end")
        if UserDefaults.standard.bool(forKey: "validationLabActive") {
            coordinatorLogger.notice("restore active lab begin")
            startLab(restored: true)
            coordinatorLogger.notice("restore active lab end")
        }
        coordinatorLogger.debug("refresh diagnostics begin")
        await refreshDiagnostics()
        coordinatorLogger.notice("restoreIfNeeded end")
    }

    func startLab(restored: Bool = false) {
        guard !isLabRunning else { return }
        isLabRunning = true
        UserDefaults.standard.set(true, forKey: "validationLabActive")
        bluetooth.start()
        Task { await wifi.start(); await updateConnectionCounts() }
        startEnergySampling()
        let launchReason = UserDefaults.standard.string(forKey: "lastLaunchReason") ?? "unknown"
        append(
            ExperimentRecord(
                kind: .lifecycle,
                name: "application",
                phase: restored ? "restored" : "started",
                outcome: .success,
                metadata: ["launchReason": launchReason, "foreground": String(isForeground)]
            )
        )
    }

    func stopLab() {
        guard isLabRunning else { return }
        isLabRunning = false
        UserDefaults.standard.set(false, forKey: "validationLabActive")
        bluetooth.stop()
        location.stop()
        nearby.stopAll(reason: "labStopped")
        if let callID = calls.activeCallID { calls.end(callID: callID) }
        energyTask?.cancel()
        energyTask = nil
        Task { await wifi.stop(); await updateConnectionCounts(); await refreshDiagnostics() }
    }

    func setForeground(_ foreground: Bool) {
        coordinatorLogger.notice("scenePhase setForeground begin foreground=\(foreground)")
        isForeground = foreground
        nearby.setForeground(foreground)
        append(
            ExperimentRecord(
                kind: .lifecycle,
                name: "scenePhase",
                phase: foreground ? "foreground" : "background",
                outcome: .info
            )
        )
        coordinatorLogger.notice("scenePhase setForeground end foreground=\(foreground)")
    }

    func startLocationExperiment() {
        location.start(strategy: selectedLocationStrategy)
    }

    func stopLocationExperiment() {
        location.stop()
    }

    func requestLocation() {
        let message = bluetooth.send(
            .locationRequest(desiredFreshness: 15, deadline: .now.addingTimeInterval(8)),
            ttl: 10
        )
        pendingControlStarts[message.id] = .now
    }

    func sendTextAndHint() {
        Task {
            let event = await wifi.publishText("验证消息 \(Date.now.formatted(date: .omitted, time: .standard))")
            _ = bluetooth.send(.dataAvailable(cursor: event.sequence), ttl: 60)
            await updateConnectionCounts()
            await refreshDiagnostics()
        }
    }

    func requestAntiEntropy() {
        Task {
            let success = await wifi.requestSync()
            if !success { await notifications.genericDataAvailableFailure() }
            await refreshDiagnostics()
        }
    }

    func sendPing() {
        Task { await wifi.sendPing(); await updateConnectionCounts() }
    }

    func sendLargeFile(megabytes: Int = 5) {
        Task { await wifi.sendResource(byteCount: megabytes * 1_024 * 1_024) }
    }

    func startWiFiPublishing() {
        Task { await wifi.startPublishing() }
    }

    func connectPickedEndpoint(_ endpoint: WAEndpoint) {
        Task { await wifi.connectPickedEndpoint(endpoint); await updateConnectionCounts() }
    }

    func requestPrecisionLocation() {
        let message = bluetooth.send(
            .precisionLocateRequest(deadline: .now.addingTimeInterval(120)),
            ttl: 120
        )
        pendingControlStarts[message.id] = .now
    }

    func acceptPrecisionRequest(_ request: PendingPrecisionRequest) {
        pendingPrecisionRequests.removeAll { $0.id == request.id }
        guard !request.isExpired else {
            _ = bluetooth.send(.precisionLocateResponse(requestID: request.id, accepted: false, reason: "expired"))
            return
        }
        guard isForeground, !location.sharingPaused else {
            _ = bluetooth.send(.precisionLocateResponse(requestID: request.id, accepted: false, reason: isForeground ? "sharingPaused" : "notForeground"))
            return
        }
        _ = bluetooth.send(.precisionLocateResponse(requestID: request.id, accepted: true, reason: nil))
        nearby.begin(peerID: request.senderID, requestID: request.id)
    }

    func ignorePrecisionRequest(_ request: PendingPrecisionRequest) {
        pendingPrecisionRequests.removeAll { $0.id == request.id }
        _ = bluetooth.send(.precisionLocateResponse(requestID: request.id, accepted: false, reason: "ignored"))
    }

    func startOutgoingCall() {
        let callID = UUID()
        let peerID = UUID.zero
        _ = bluetooth.send(.callOffer(callID: callID, displayName: displayName), ttl: 30)
        calls.startOutgoing(callID: callID, peerID: peerID)
    }

    func endCurrentCall() {
        guard let callID = calls.activeCallID else { return }
        calls.end(callID: callID)
    }

    func exportDiagnostics() {
        Task {
            do {
                lastExportURL = try await logStore.exportArchive(deviceMetadata: capabilityMetadata())
            } catch {
                lastError = String(describing: error)
            }
        }
    }

    func clearDiagnostics() {
        Task {
            await logStore.clear()
            await refreshDiagnostics()
        }
    }

    func refreshDiagnostics() async {
        recentRecords = await logStore.recent()
        summaries = await logStore.summaries()
        await updateConnectionCounts()
    }

    func capabilityMetadata() -> [String: String] {
        var system = utsname()
        uname(&system)
        let machine = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return [
            "deviceName": displayName,
            "deviceID": deviceID.uuidString,
            "hardware": machine,
            "systemName": UIDevice.current.systemName,
            "systemVersion": UIDevice.current.systemVersion,
            "wifiAware": String(WACapabilities.supportedFeatures.contains(.wifiAware)),
            "wifiAwareMaximumPeers": String(WACapabilities.maximumConnectableDevices),
            "uwbPreciseDistance": String(NISession.deviceCapabilities.supportsPreciseDistanceMeasurement),
            "uwbDirection": String(NISession.deviceCapabilities.supportsDirectionMeasurement),
            "bluetoothAuthorization": String(describing: CBManager.authorization),
            "locationAuthorization": location.authorizationDescription,
            "notificationAuthorization": notifications.authorizationStatus,
            "appState": String(describing: UIApplication.shared.applicationState)
        ]
    }

    private func bind() {
        diagnosticsRefreshTask = Task { [weak self] in
            guard let self else { return }
            let updates = await logStore.updates()
            for await _ in updates {
                await refreshDiagnostics()
            }
        }
        bluetooth.onMessage = { [weak self] message in self?.handleControl(message) }
        nearby.onLocalToken = { [weak self] peerID, requestID, data in
            guard let self else { return }
            Task { await self.wifi.sendNearbyToken(peerID: peerID, requestID: requestID, token: data) }
        }
        calls.onAnswer = { [weak self] callID in
            guard let self else { return }
            _ = self.bluetooth.send(.callAnswer(callID: callID), ttl: 30)
            Task { await self.updateConnectionCounts() }
        }
        calls.onEnd = { [weak self] callID in
            guard let self else { return }
            _ = self.bluetooth.send(.callEnd(callID: callID), ttl: 30)
        }
        calls.onStartOutgoing = { [weak self] _ in
            guard let self else { return }
            Task { await self.updateConnectionCounts() }
        }
        calls.onVoicePacket = { [weak self] packet in
            guard let self else { return }
            Task { await self.wifi.sendVoice(packet) }
        }
        Task {
            await wifi.setStatusSink { [weak self] status in
                await self?.applyWiFiStatus(status)
            }
            await wifi.setMessageSink { [weak self] message in
                await self?.handleDataMessage(message)
            }
            await wifi.setVoiceSink { [weak self] packet in
                await self?.handleVoicePacket(packet)
            }
        }
    }

    private func applyWiFiStatus(_ status: WiFiAwareExperimentStatus) {
        wifiPairedDeviceNames = status.pairedDeviceNames
        wifiDataPublisherState = status.dataPublisherState
        wifiVoicePublisherState = status.voicePublisherState
        wifiDiscoveryState = status.discoveryState
        wifiConnectionState = status.connectionState
        dataConnectionCount = status.dataConnectionCount
        voiceConnectionCount = status.voiceConnectionCount
        wifiLastError = status.lastError
    }

    private func handleControl(_ message: ControlMessage) {
        switch message.kind {
        case .dataAvailable:
            coordinatorLogger.notice("BLE dataAvailable received messageID=\(message.id.uuidString, privacy: .public)")
            Task {
                coordinatorLogger.notice("BLE dataAvailable WiFi sync begin messageID=\(message.id.uuidString, privacy: .public)")
                let success = await wifi.requestSync()
                coordinatorLogger.notice("BLE dataAvailable WiFi sync end success=\(success) messageID=\(message.id.uuidString, privacy: .public)")
                if !success {
                    coordinatorLogger.notice("BLE dataAvailable fallback notification begin")
                    await notifications.genericDataAvailableFailure()
                    coordinatorLogger.notice("BLE dataAvailable fallback notification end")
                }
            }
        case let .locationRequest(freshness, deadline):
            Task {
                let (sample, status) = await location.sampleForRequest(desiredFreshness: freshness, deadline: deadline)
                _ = bluetooth.send(.locationResponse(requestID: message.id, sample: sample, status: status), ttl: 30)
            }
        case let .locationResponse(requestID, sample, status):
            let latency = pendingControlStarts.removeValue(forKey: requestID).map { ContinuousClock.now - $0 }
            append(ExperimentRecord(
                kind: .location,
                name: "requestResponse",
                phase: status.rawValue,
                outcome: status == .fresh || status == .stale ? .success : (status == .timeout ? .timeout : .failure),
                latencyMilliseconds: latency?.milliseconds,
                metadata: [
                    "requestID": requestID.uuidString,
                    "sampleAge": sample.map { String(format: "%.3f", $0.age) } ?? "unavailable",
                    "horizontalAccuracy": sample.map { String(format: "%.2f", $0.horizontalAccuracy) } ?? "unavailable"
                ]
            ))
        case let .precisionLocateRequest(deadline):
            if location.sharingPaused {
                _ = bluetooth.send(.precisionLocateResponse(requestID: message.id, accepted: false, reason: "sharingPaused"))
                return
            }
            if let last = precisionCooldowns[message.senderID], Date.now.timeIntervalSince(last) < 60 {
                _ = bluetooth.send(.precisionLocateResponse(requestID: message.id, accepted: false, reason: "rateLimited"))
                return
            }
            precisionCooldowns[message.senderID] = .now
            let request = PendingPrecisionRequest(id: message.id, senderID: message.senderID, receivedAt: .now, deadline: deadline)
            pendingPrecisionRequests.append(request)
            Task { await notifications.precisionRequest(request) }
        case let .precisionLocateResponse(requestID, accepted, reason):
            if accepted {
                nearby.begin(peerID: message.senderID, requestID: requestID)
            } else {
                append(ExperimentRecord(kind: .uwb, name: "precisionRequest", phase: "rejected", outcome: .failure, metadata: ["reason": reason ?? "unknown"]))
            }
        case let .precisionLocateCancel(requestID):
            pendingPrecisionRequests.removeAll { $0.id == requestID }
            nearby.cancel(peerID: message.senderID, reason: "remoteCancelled")
        case let .callOffer(callID, name):
            calls.reportIncoming(callID: callID, callerID: message.senderID, displayName: name)
        case let .callAnswer(callID):
            calls.markRemoteAnswered(callID: callID)
        case let .callReject(callID, _):
            calls.markRemoteEnded(callID: callID, reason: .declinedElsewhere)
        case let .callEnd(callID):
            calls.markRemoteEnded(callID: callID)
        case let .ack(messageID):
            if let start = pendingControlStarts.removeValue(forKey: messageID) {
                append(ExperimentRecord(kind: .bluetooth, name: "ack", phase: "roundTrip", outcome: .success, latencyMilliseconds: (ContinuousClock.now - start).milliseconds, metadata: ["messageID": messageID.uuidString]))
            }
        }
    }

    private func handleDataMessage(_ message: DataPlaneMessage) async {
        switch message {
        case let .syncBatch(events, _):
            if !events.isEmpty { await notifications.synchronizedMessage(count: events.count) }
        case .text:
            await notifications.synchronizedMessage(count: 1)
        case let .nearbyToken(senderID, peerID, requestID, token):
            guard peerID == deviceID else { return }
            nearby.receiveToken(from: senderID, requestID: requestID, data: token)
        default:
            break
        }
        await refreshDiagnostics()
    }

    private func handleVoicePacket(_ packet: VoicePacket) async {
        calls.receive(packet)
    }

    private func startEnergySampling() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        energyTask?.cancel()
        energyTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let device = UIDevice.current
                self.append(ExperimentRecord(
                    kind: .energy,
                    name: "battery",
                    phase: "sample",
                    outcome: .info,
                    metadata: [
                        "level": String(format: "%.4f", device.batteryLevel),
                        "state": String(describing: device.batteryState),
                        "thermalState": String(describing: ProcessInfo.processInfo.thermalState),
                        "lowPowerMode": String(ProcessInfo.processInfo.isLowPowerModeEnabled)
                    ]
                ))
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func startDebugHeartbeatsIfNeeded() {
        if mainActorHeartbeatTask == nil {
            mainActorHeartbeatTask = Task {
                while !Task.isCancelled {
                    coordinatorLogger.debug("heartbeat mainActor")
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
        if processHeartbeatTask == nil {
            processHeartbeatTask = Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    coordinatorLogger.debug("heartbeat process")
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    private func updateConnectionCounts() async {
        let counts = await wifi.connectionCounts()
        dataConnectionCount = counts.data
        voiceConnectionCount = counts.voice
    }

    private func recordCapabilities() async {
        await logStore.append(ExperimentRecord(kind: .capability, name: "device", phase: "snapshot", outcome: .info, metadata: capabilityMetadata()))
    }

    private func append(_ record: ExperimentRecord) {
        Task { await logStore.append(record); await refreshDiagnostics() }
    }
}

private extension UUID {
    static let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}
