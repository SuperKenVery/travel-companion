@preconcurrency import CoreBluetooth
import CryptoKit
import Foundation
import Observation
import OSLog

private let bluetoothRuntimeLogger = Logger(
    subsystem: "com.ken.TravelCompanionValidation",
    category: "BluetoothRuntime"
)

@MainActor
@Observable
final class BluetoothControlPlane: NSObject {
    typealias EventSink = @Sendable (ExperimentRecord) async -> Void

    static let serviceUUID = CBUUID(string: "7D59F31B-FF93-4D06-9B34-1AF354A3D581")
    private static let controlUUID = CBUUID(string: "7D59F31C-FF93-4D06-9B34-1AF354A3D581")
    private static let centralRestoreID = "travel.validation.bluetooth.central"
    private static let peripheralRestoreID = "travel.validation.bluetooth.peripheral"

    private let deviceID: UUID
    private let displayName: String
    private let eventSink: EventSink
    private var codec: BLEControlCodec?
    private(set) var groupCredentials: NearbyGroupCredentials?
    private var centralManager: CBCentralManager!
    private var peripheralManager: CBPeripheralManager!
    private var mutableCharacteristic: CBMutableCharacteristic?
    private var connectedPeripherals: [UUID: CBPeripheral] = [:]
    private var writableCharacteristics: [UUID: CBCharacteristic] = [:]
    private var subscribedCentrals: [UUID: CBCentral] = [:]
    private var pendingNotifications: [Data] = []
    private var assemblies: [UUID: BLEAssembly] = [:]
    private var seenMessageIDs: Set<UUID> = []
    private var sequence: UInt64
    private var benchmarkTask: Task<Void, Never>?
    private var pairedMembers: [UUID: String] = [:]

    var onMessage: ((ControlMessage) -> Void)?
    var onGroupChanged: ((NearbyGroupCredentials?) -> Void)?
    private(set) var centralState = "unknown"
    private(set) var peripheralState = "unknown"
    private(set) var connectedPeerCount = 0
    private(set) var sentMessageCount = 0
    private(set) var receivedMessageCount = 0
    private(set) var restorationCount = 0
    private(set) var isRunning = false

    var groupID: String? { groupCredentials?.id }
    var pairedMemberNames: [String] { pairedMembers.values.sorted() }

    init(deviceID: UUID, displayName: String, eventSink: @escaping EventSink) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.eventSink = eventSink
        let storedCredentials = NearbyGroupCredentials.load()
        groupCredentials = storedCredentials
        codec = storedCredentials.map { BLEControlCodec(keyData: $0.keyData) }
        sequence = UInt64(UserDefaults.standard.integer(forKey: "bleSequence"))
        if let values = UserDefaults.standard.array(forKey: "bleSeenMessageIDs") as? [String] {
            seenMessageIDs = Set(values.compactMap(UUID.init(uuidString:)))
        }
        super.init()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        centralManager = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: Self.centralRestoreID,
                CBCentralManagerOptionShowPowerAlertKey: true
            ]
        )
        peripheralManager = CBPeripheralManager(
            delegate: self,
            queue: .main,
            options: [CBPeripheralManagerOptionRestoreIdentifierKey: Self.peripheralRestoreID]
        )
        log(name: "lifecycle", phase: "start", outcome: .success)
    }

    func stop() {
        benchmarkTask?.cancel()
        benchmarkTask = nil
        centralManager?.stopScan()
        for peripheral in connectedPeripherals.values {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        peripheralManager?.stopAdvertising()
        if mutableCharacteristic != nil { peripheralManager?.removeAllServices() }
        self.mutableCharacteristic = nil
        connectedPeripherals.removeAll()
        writableCharacteristics.removeAll()
        subscribedCentrals.removeAll()
        pendingNotifications.removeAll()
        updatePeerCount()
        isRunning = false
        log(name: "lifecycle", phase: "stop", outcome: .success)
    }

    func createGroup() throws -> String {
        let pin = NearbyGroupCredentials.generatePIN()
        try joinGroup(pin: pin)
        return pin
    }

    func joinGroup(pin: String) throws {
        let credentials = try NearbyGroupCredentials.derive(fromPIN: pin)
        try credentials.save()
        groupCredentials = credentials
        codec = BLEControlCodec(keyData: credentials.keyData)
        pairedMembers.removeAll()
        onGroupChanged?(credentials)
        log(name: "groupPairing", phase: "configured", outcome: .success, metadata: ["groupID": credentials.id])
        announceGroupMembership()
    }

    func leaveGroup() {
        NearbyGroupCredentials.clear()
        groupCredentials = nil
        codec = nil
        pairedMembers.removeAll()
        onGroupChanged?(nil)
        log(name: "groupPairing", phase: "left", outcome: .success)
    }

    @discardableResult
    func send(_ kind: ControlKind, ttl: TimeInterval = 30) -> ControlMessage {
        sequence &+= 1
        UserDefaults.standard.set(Int(sequence), forKey: "bleSequence")
        let message = ControlMessage(senderID: deviceID, sequence: sequence, ttl: ttl, kind: kind)
        transmit(message)
        return message
    }

    func startRepeatedRequestBenchmark(
        duration: Duration = .seconds(30 * 60),
        interval: Duration = .seconds(10)
    ) {
        benchmarkTask?.cancel()
        benchmarkTask = Task { [weak self] in
            guard let self else { return }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: duration)
            var attempts = 0
            self.log(name: "lockedScreenBenchmark", phase: "start", outcome: .info, metadata: [
                "durationSeconds": String(format: "%.0f", duration.milliseconds / 1_000),
                "intervalSeconds": String(format: "%.0f", interval.milliseconds / 1_000)
            ])
            while !Task.isCancelled, clock.now < deadline {
                attempts += 1
                _ = self.send(
                    .locationRequest(desiredFreshness: 15, deadline: .now.addingTimeInterval(8)),
                    ttl: 10
                )
                try? await Task.sleep(for: interval)
            }
            self.log(name: "lockedScreenBenchmark", phase: "complete", outcome: Task.isCancelled ? .skipped : .success, metadata: ["attempts": String(attempts)])
        }
    }

    func cancelBenchmark() {
        benchmarkTask?.cancel()
        benchmarkTask = nil
    }

    private func transmit(_ message: ControlMessage) {
        do {
            guard let codec else {
                log(name: controlName(message.kind), phase: "send", outcome: .failure, metadata: ["reason": "groupPINRequired"])
                return
            }
            let encrypted = try codec.encode(message)
            let packets = codec.fragment(encrypted, messageID: message.id, maximumPacketSize: 140)
            for (id, characteristic) in writableCharacteristics {
                guard let peripheral = connectedPeripherals[id] else { continue }
                for packet in packets {
                    let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.writeWithoutResponse)
                        ? .withoutResponse : .withResponse
                    peripheral.writeValue(packet, for: characteristic, type: writeType)
                }
            }
            for packet in packets {
                guard let mutableCharacteristic else { break }
                if !peripheralManager.updateValue(packet, for: mutableCharacteristic, onSubscribedCentrals: nil) {
                    pendingNotifications.append(packet)
                }
            }
            sentMessageCount += 1
            log(
                name: controlName(message.kind),
                phase: "send",
                outcome: writableCharacteristics.isEmpty && subscribedCentrals.isEmpty ? .failure : .success,
                byteCount: encrypted.count,
                metadata: [
                    "messageID": message.id.uuidString,
                    "sequence": String(message.sequence),
                    "fragments": String(packets.count),
                    "centralLinks": String(writableCharacteristics.count),
                    "peripheralSubscribers": String(subscribedCentrals.count)
                ]
            )
        } catch {
            log(name: controlName(message.kind), phase: "encode", outcome: .failure, metadata: ["error": String(describing: error)])
        }
    }

    private func ingest(_ packet: Data, source: String) {
        do {
            guard let codec else {
                log(name: "controlFrame", phase: "decode", outcome: .failure, metadata: ["source": source, "reason": "groupPINRequired"])
                return
            }
            let fragment = try codec.parse(packet)
            var assembly = assemblies[fragment.messageID] ?? BLEAssembly(total: fragment.total, createdAt: .now)
            assembly.chunks[Int(fragment.index)] = fragment.payload
            assemblies[fragment.messageID] = assembly
            purgeExpiredAssemblies()
            guard assembly.chunks.count == Int(assembly.total) else { return }
            assemblies.removeValue(forKey: fragment.messageID)
            let encrypted = try (0..<Int(assembly.total)).reduce(into: Data()) { result, index in
                guard let part = assembly.chunks[index] else { throw BLEControlError.incompleteMessage }
                result.append(part)
            }
            let message = try codec.decode(encrypted)
            let name = controlName(message.kind)
            bluetoothRuntimeLogger.notice(
                "ingest decoded kind=\(name, privacy: .public) id=\(message.id.uuidString, privacy: .public) source=\(source, privacy: .public)"
            )
            guard message.protocolVersion == ControlMessage.currentProtocolVersion else {
                throw BLEControlError.protocolVersion
            }
            guard !message.isExpired else {
                log(name: controlName(message.kind), phase: "receive", outcome: .timeout, metadata: ["source": source, "messageID": message.id.uuidString])
                return
            }
            let isDuplicate = seenMessageIDs.contains(message.id)
            if !isDuplicate {
                remember(message.id)
                receivedMessageCount += 1
                if case let .groupHello(groupID, name) = message.kind,
                   groupID == groupCredentials?.id,
                   message.senderID != deviceID {
                    pairedMembers[message.senderID] = name
                }
                bluetoothRuntimeLogger.notice(
                    "onMessage begin kind=\(name, privacy: .public) id=\(message.id.uuidString, privacy: .public)"
                )
                onMessage?(message)
                bluetoothRuntimeLogger.notice(
                    "onMessage end kind=\(name, privacy: .public) id=\(message.id.uuidString, privacy: .public)"
                )
            }
            log(
                name: controlName(message.kind),
                phase: "receive",
                outcome: isDuplicate ? .skipped : .success,
                byteCount: encrypted.count,
                metadata: ["source": source, "messageID": message.id.uuidString, "deduplicated": String(isDuplicate)]
            )
            if case .ack = message.kind { return }
            _ = send(.ack(messageID: message.id), ttl: 15)
        } catch {
            log(name: "controlFrame", phase: "decode", outcome: .failure, metadata: ["source": source, "error": String(describing: error)])
        }
    }

    private func remember(_ id: UUID) {
        seenMessageIDs.insert(id)
        if seenMessageIDs.count > 512 {
            seenMessageIDs = Set(seenMessageIDs.prefix(384))
        }
        UserDefaults.standard.set(seenMessageIDs.map(\.uuidString), forKey: "bleSeenMessageIDs")
    }

    private func purgeExpiredAssemblies() {
        let cutoff = Date.now.addingTimeInterval(-30)
        assemblies = assemblies.filter { $0.value.createdAt >= cutoff }
    }

    private func configurePeripheralService() {
        peripheralManager.removeAllServices()
        let characteristic = CBMutableCharacteristic(
            type: Self.controlUUID,
            properties: [.notify, .read, .write, .writeWithoutResponse],
            value: nil,
            permissions: [.readable, .writeable]
        )
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [characteristic]
        mutableCharacteristic = characteristic
        peripheralManager.add(service)
    }

    private func updatePeerCount() {
        connectedPeerCount = Set(connectedPeripherals.keys).union(subscribedCentrals.keys).count
    }

    private func announceGroupMembership() {
        guard let groupID = groupCredentials?.id else { return }
        _ = send(.groupHello(groupID: groupID, name: displayName), ttl: 120)
    }

    private func log(
        name: String,
        phase: String,
        outcome: ExperimentOutcome,
        latencyMilliseconds: Double? = nil,
        byteCount: Int? = nil,
        metadata: [String: String] = [:]
    ) {
        let record = ExperimentRecord(
            kind: .bluetooth,
            name: name,
            phase: phase,
            outcome: outcome,
            latencyMilliseconds: latencyMilliseconds,
            byteCount: byteCount,
            metadata: metadata
        )
        Task { await eventSink(record) }
    }

    private func controlName(_ kind: ControlKind) -> String {
        switch kind {
        case .groupHello: "groupHello"
        case .dataAvailable: "dataAvailable"
        case .locationRequest: "locationRequest"
        case .locationResponse: "locationResponse"
        case .precisionLocateRequest: "precisionLocateRequest"
        case .precisionLocateResponse: "precisionLocateResponse"
        case .precisionLocateCancel: "precisionLocateCancel"
        case .callOffer: "callOffer"
        case .callAnswer: "callAnswer"
        case .callReject: "callReject"
        case .callEnd: "callEnd"
        case .ack: "ack"
        }
    }
}

extension BluetoothControlPlane: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        centralState = String(describing: central.state)
        log(name: "central", phase: centralState, outcome: central.state == .poweredOn ? .success : .info)
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        connectedPeripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self
        central.connect(
            peripheral,
            options: [CBConnectPeripheralOptionEnableAutoReconnect: true]
        )
        log(name: "discovery", phase: "found", outcome: .success, metadata: ["peripheral": peripheral.identifier.uuidString, "rssi": RSSI.stringValue])
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedPeripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
        updatePeerCount()
        log(name: "connection", phase: "connected", outcome: .success, metadata: ["peripheral": peripheral.identifier.uuidString])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log(name: "connection", phase: "failed", outcome: .failure, metadata: ["peripheral": peripheral.identifier.uuidString, "error": String(describing: error)])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        writableCharacteristics.removeValue(forKey: peripheral.identifier)
        if !isReconnecting { connectedPeripherals.removeValue(forKey: peripheral.identifier) }
        updatePeerCount()
        log(name: "connection", phase: "disconnected", outcome: error == nil ? .info : .failure, metadata: ["peripheral": peripheral.identifier.uuidString, "reconnecting": String(isReconnecting), "error": String(describing: error)])
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        restorationCount += 1
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        for peripheral in peripherals {
            connectedPeripherals[peripheral.identifier] = peripheral
            peripheral.delegate = self
            if peripheral.state == .connected { peripheral.discoverServices([Self.serviceUUID]) }
        }
        updatePeerCount()
        log(name: "stateRestoration", phase: "central", outcome: .success, metadata: ["peripherals": String(peripherals.count)])
    }
}

extension BluetoothControlPlane: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log(name: "gatt", phase: "services", outcome: .failure, metadata: ["error": String(describing: error)])
            return
        }
        peripheral.services?.filter { $0.uuid == Self.serviceUUID }.forEach {
            peripheral.discoverCharacteristics([Self.controlUUID], for: $0)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            log(name: "gatt", phase: "characteristics", outcome: .failure, metadata: ["error": String(describing: error)])
            return
        }
        for characteristic in service.characteristics ?? [] where characteristic.uuid == Self.controlUUID {
            writableCharacteristics[peripheral.identifier] = characteristic
            peripheral.setNotifyValue(true, for: characteristic)
        }
        updatePeerCount()
        announceGroupMembership()
        log(name: "gatt", phase: "ready", outcome: .success, metadata: ["peripheral": peripheral.identifier.uuidString])
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else {
            log(name: "notification", phase: "receive", outcome: .failure, metadata: ["error": String(describing: error)])
            return
        }
        ingest(value, source: "centralNotification")
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log(name: "gattWrite", phase: "ack", outcome: .failure, metadata: ["error": String(describing: error)])
        }
    }
}

extension BluetoothControlPlane: @preconcurrency CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        peripheralState = String(describing: peripheral.state)
        log(name: "peripheral", phase: peripheralState, outcome: peripheral.state == .poweredOn ? .success : .info)
        guard peripheral.state == .poweredOn else { return }
        configurePeripheralService()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil else {
            log(name: "advertising", phase: "service", outcome: .failure, metadata: ["error": String(describing: error)])
            return
        }
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
            CBAdvertisementDataLocalNameKey: "Travel Validation"
        ])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        log(name: "advertising", phase: "started", outcome: error == nil ? .success : .failure, metadata: ["error": String(describing: error)])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        subscribedCentrals[central.identifier] = central
        updatePeerCount()
        announceGroupMembership()
        log(name: "subscription", phase: "subscribed", outcome: .success, metadata: ["central": central.identifier.uuidString, "maximumUpdateLength": String(central.maximumUpdateValueLength)])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribedCentrals.removeValue(forKey: central.identifier)
        updatePeerCount()
        log(name: "subscription", phase: "unsubscribed", outcome: .info, metadata: ["central": central.identifier.uuidString])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard request.characteristic.uuid == Self.controlUUID, let value = request.value else {
                peripheral.respond(to: request, withResult: .requestNotSupported)
                continue
            }
            ingest(value, source: "peripheralWrite")
            peripheral.respond(to: request, withResult: .success)
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard let characteristic = mutableCharacteristic else { return }
        while let packet = pendingNotifications.first {
            guard peripheral.updateValue(packet, for: characteristic, onSubscribedCentrals: nil) else { return }
            pendingNotifications.removeFirst()
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        restorationCount += 1
        let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] ?? []
        mutableCharacteristic = services
            .flatMap { $0.characteristics ?? [] }
            .compactMap { $0 as? CBMutableCharacteristic }
            .first { $0.uuid == Self.controlUUID }
        log(name: "stateRestoration", phase: "peripheral", outcome: .success, metadata: ["services": String(services.count)])
    }
}

private struct BLEAssembly {
    let total: UInt16
    let createdAt: Date
    var chunks: [Int: Data] = [:]
}

struct BLEFragment {
    let messageID: UUID
    let index: UInt16
    let total: UInt16
    let payload: Data
}

struct BLEControlCodec {
    private let key: SymmetricKey

    init(keyData: Data) {
        key = SymmetricKey(data: keyData)
    }

    func encode(_ message: ControlMessage) throws -> Data {
        let encoded = try JSONEncoder().encode(message)
        let sealed = try AES.GCM.seal(encoded, using: key)
        guard let combined = sealed.combined else { throw BLEControlError.encryption }
        return combined
    }

    func decode(_ encrypted: Data) throws -> ControlMessage {
        let box = try AES.GCM.SealedBox(combined: encrypted)
        let clear = try AES.GCM.open(box, using: key)
        return try JSONDecoder().decode(ControlMessage.self, from: clear)
    }

    func fragment(_ data: Data, messageID: UUID, maximumPacketSize: Int) -> [Data] {
        let headerSize = 21
        let payloadSize = max(1, maximumPacketSize - headerSize)
        let total = UInt16((data.count + payloadSize - 1) / payloadSize)
        let uuidBytes = messageID.uuid
        return (0..<Int(total)).map { index in
            var packet = Data([1])
            withUnsafeBytes(of: uuidBytes) { packet.append(contentsOf: $0) }
            packet.append(UInt8(truncatingIfNeeded: UInt16(index) >> 8))
            packet.append(UInt8(truncatingIfNeeded: UInt16(index)))
            packet.append(UInt8(truncatingIfNeeded: total >> 8))
            packet.append(UInt8(truncatingIfNeeded: total))
            let lower = index * payloadSize
            let upper = min(lower + payloadSize, data.count)
            packet.append(data.subdata(in: lower..<upper))
            return packet
        }
    }

    func parse(_ packet: Data) throws -> BLEFragment {
        guard packet.count >= 21, packet[0] == 1 else { throw BLEControlError.invalidFragment }
        let bytes = Array(packet[1..<17])
        guard bytes.count == 16 else { throw BLEControlError.invalidFragment }
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        let index = (UInt16(packet[17]) << 8) | UInt16(packet[18])
        let total = (UInt16(packet[19]) << 8) | UInt16(packet[20])
        guard total > 0, index < total else { throw BLEControlError.invalidFragment }
        return BLEFragment(messageID: uuid, index: index, total: total, payload: packet.subdata(in: 21..<packet.count))
    }
}

enum BLEControlError: Error {
    case encryption
    case invalidFragment
    case incompleteMessage
    case protocolVersion
}
