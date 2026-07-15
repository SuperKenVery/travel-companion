@preconcurrency import CoreBluetooth
import Foundation

public typealias TcBluetoothEventSink = @MainActor @Sendable (Data) -> Void

/// Core Bluetooth backend. All CoreBluetooth objects remain owned by this main-actor object;
/// callers only see JSON values and stable UInt64 handles.
@MainActor
public final class TcBluetoothAppleBackend: NSObject {
    public static let serviceUUID = CBUUID(string: "7D59F31B-FF93-4D06-9B34-1AF354A3D581")
    public static let controlUUID = CBUUID(string: "7D59F31C-FF93-4D06-9B34-1AF354A3D581")

    private static let centralRestoreID = "com.travelcompanion.tc-bluetooth.central"
    private static let peripheralRestoreID = "com.travelcompanion.tc-bluetooth.peripheral"
    private static let maximumControlPacket = 180

    private struct Command: Decodable {
        var type: String
        var requestID: String?
        var peerHandle: UInt64?
        var messageID: String?
        var sequence: UInt64?
        var ttlMillis: UInt64?
        var payloadBase64: String?
        var requiresAck: Bool?
    }

    private struct Event: Encodable {
        var type: String
        var requestID: String?
        var peerHandle: UInt64?
        var messageID: String?
        var sequence: UInt64?
        var payloadBase64: String?
        var fields: [String: String]?
        var error: String?
    }

    private struct WireEnvelope: Codable {
        enum Kind: String, Codable { case data, ack }
        var version: UInt8 = 1
        var kind: Kind
        var messageID: UUID
        var sequence: UInt64
        var createdAtMillis: UInt64
        var ttlMillis: UInt64
        var requiresAck: Bool
        var payload: Data?

        var isExpired: Bool {
            let now = UInt64(max(0, Date.now.timeIntervalSince1970 * 1_000))
            return now > createdAtMillis &+ ttlMillis
        }
    }

    private struct FragmentAssembly {
        var createdAt = Date.now
        var total: UInt16
        var pieces: [UInt16: Data] = [:]
    }

    private struct PendingNotification {
        var data: Data
        var central: CBCentral?
    }

    private let eventSink: TcBluetoothEventSink
    private var centralManager: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var controlCharacteristic: CBMutableCharacteristic?
    private var isRunning = false

    private var nextPeerHandle: UInt64 = 1
    private var handleByPlatformID: [UUID: UInt64] = [:]
    private var peripherals: [UInt64: CBPeripheral] = [:]
    private var writableCharacteristics: [UInt64: CBCharacteristic] = [:]
    private var subscribedCentrals: [UInt64: CBCentral] = [:]
    private var assemblies: [String: FragmentAssembly] = [:]
    private var seenMessageIDs: Set<UUID> = []
    private var seenMessageOrder: [UUID] = []
    private var pendingNotifications: [PendingNotification] = []
    private var pendingCentralWrites: [UInt64: [Data]] = [:]

    public init(eventSink: @escaping TcBluetoothEventSink) {
        self.eventSink = eventSink
        super.init()
    }

    public func submit(_ json: Data) {
        let command: Command
        do {
            command = try JSONDecoder().decode(Command.self, from: json)
        } catch {
            emit(.init(type: "commandFailed", error: String(describing: error)))
            return
        }
        do {
            switch command.type {
            case "start":
                start(requestID: command.requestID)
            case "stop":
                stop(requestID: command.requestID)
            case "snapshot":
                emitSnapshot(requestID: command.requestID)
            case "sendControl":
                try send(command)
            case "disconnect":
                disconnect(command)
            default:
                emit(.init(type: "commandFailed", requestID: command.requestID, error: "unknown command: \(command.type)"))
            }
        } catch {
            emit(.init(type: "commandFailed", requestID: command.requestID, peerHandle: command.peerHandle, error: String(describing: error)))
        }
    }

    public func shutdown() {
        stop(requestID: nil)
    }

    private func start(requestID: String?) {
        guard !isRunning else {
            emit(.init(type: "commandCompleted", requestID: requestID, fields: ["command": "start", "reused": "true"]))
            return
        }
        isRunning = true
        centralManager = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: Self.centralRestoreID,
                CBCentralManagerOptionShowPowerAlertKey: true,
            ]
        )
        peripheralManager = CBPeripheralManager(
            delegate: self,
            queue: .main,
            options: [CBPeripheralManagerOptionRestoreIdentifierKey: Self.peripheralRestoreID]
        )
        emit(.init(type: "commandCompleted", requestID: requestID, fields: ["command": "start"]))
    }

    private func stop(requestID: String?) {
        centralManager?.stopScan()
        if let centralManager {
            for peripheral in peripherals.values { centralManager.cancelPeripheralConnection(peripheral) }
        }
        peripheralManager?.stopAdvertising()
        peripheralManager?.removeAllServices()
        centralManager = nil
        peripheralManager = nil
        controlCharacteristic = nil
        peripherals.removeAll()
        writableCharacteristics.removeAll()
        subscribedCentrals.removeAll()
        assemblies.removeAll()
        pendingNotifications.removeAll()
        pendingCentralWrites.removeAll()
        isRunning = false
        emit(.init(type: "commandCompleted", requestID: requestID, fields: ["command": "stop"]))
    }

    private func emitSnapshot(requestID: String?) {
        emit(.init(
            type: "capabilitySnapshot",
            requestID: requestID,
            fields: [
                "centralState": String(describing: centralManager?.state ?? .unknown),
                "peripheralState": String(describing: peripheralManager?.state ?? .unknown),
                "authorization": String(describing: CBManager.authorization),
                "connectedPeripheralCount": String(peripherals.values.filter { $0.state == .connected }.count),
                "subscribedCentralCount": String(subscribedCentrals.count),
                "serviceUUID": Self.serviceUUID.uuidString,
                "controlUUID": Self.controlUUID.uuidString,
                "stateRestoration": "true",
            ]
        ))
    }

    private func send(_ command: Command) throws {
        guard let messageIDText = command.messageID, let messageID = UUID(uuidString: messageIDText) else {
            throw BackendError.invalidField("messageID")
        }
        guard let payloadText = command.payloadBase64, let payload = Data(base64Encoded: payloadText) else {
            throw BackendError.invalidField("payloadBase64")
        }
        guard payload.count <= 4_096 else { throw BackendError.controlPayloadTooLarge }
        let envelope = WireEnvelope(
            kind: .data,
            messageID: messageID,
            sequence: command.sequence ?? 0,
            createdAtMillis: Self.nowMillis,
            ttlMillis: max(1, command.ttlMillis ?? 30_000),
            requiresAck: command.requiresAck ?? true,
            payload: payload
        )
        try transmit(envelope, to: command.peerHandle)
        emit(.init(
            type: "controlQueued",
            requestID: command.requestID,
            peerHandle: command.peerHandle,
            messageID: messageID.uuidString,
            sequence: envelope.sequence,
            fields: ["bytes": String(payload.count)]
        ))
    }

    private func disconnect(_ command: Command) {
        guard let handle = command.peerHandle, let peripheral = peripherals[handle] else {
            emit(.init(type: "commandFailed", requestID: command.requestID, peerHandle: command.peerHandle, error: "unknown peerHandle"))
            return
        }
        centralManager?.cancelPeripheralConnection(peripheral)
        emit(.init(type: "commandCompleted", requestID: command.requestID, peerHandle: handle, fields: ["command": "disconnect"]))
    }

    private func configurePeripheralService() {
        guard let peripheralManager, peripheralManager.state == .poweredOn else { return }
        if controlCharacteristic != nil {
            if !peripheralManager.isAdvertising {
                peripheralManager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]])
            }
            return
        }
        peripheralManager.removeAllServices()
        let characteristic = CBMutableCharacteristic(
            type: Self.controlUUID,
            properties: [.notify, .write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [characteristic]
        controlCharacteristic = characteristic
        peripheralManager.add(service)
    }

    private func handle(for platformID: UUID) -> UInt64 {
        if let existing = handleByPlatformID[platformID] { return existing }
        let handle = nextPeerHandle
        nextPeerHandle &+= 1
        handleByPlatformID[platformID] = handle
        emit(.init(type: "peerDiscovered", peerHandle: handle, fields: ["platformID": platformID.uuidString]))
        return handle
    }

    private func transmit(_ envelope: WireEnvelope, to target: UInt64?) throws {
        let encoded = try JSONEncoder().encode(envelope)
        var sentPaths = 0

        for (handle, characteristic) in writableCharacteristics where target == nil || target == handle {
            guard let peripheral = peripherals[handle], peripheral.state == .connected else { continue }
            let maximum = min(Self.maximumControlPacket, peripheral.maximumWriteValueLength(for: .withoutResponse))
            for packet in try Self.fragment(encoded, messageID: envelope.messageID, maximumPacketSize: maximum) {
                let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
                if writeType == .withoutResponse {
                    pendingCentralWrites[handle, default: []].append(packet)
                } else {
                    peripheral.writeValue(packet, for: characteristic, type: writeType)
                }
            }
            flushCentralWrites(to: handle)
            sentPaths += 1
        }

        if let peripheralManager, let characteristic = controlCharacteristic {
            for (handle, central) in subscribedCentrals where target == nil || target == handle {
                let maximum = min(Self.maximumControlPacket, central.maximumUpdateValueLength)
                for packet in try Self.fragment(encoded, messageID: envelope.messageID, maximumPacketSize: maximum) {
                    if !peripheralManager.updateValue(packet, for: characteristic, onSubscribedCentrals: [central]) {
                        pendingNotifications.append(.init(data: packet, central: central))
                    }
                }
                sentPaths += 1
            }
        }

        if sentPaths == 0 { throw BackendError.peerUnavailable }
    }

    private func flushCentralWrites(to handle: UInt64) {
        guard
            let peripheral = peripherals[handle],
            peripheral.state == .connected,
            let characteristic = writableCharacteristics[handle],
            var queued = pendingCentralWrites[handle]
        else { return }

        while !queued.isEmpty, peripheral.canSendWriteWithoutResponse {
            peripheral.writeValue(queued.removeFirst(), for: characteristic, type: .withoutResponse)
        }
        if queued.isEmpty {
            pendingCentralWrites.removeValue(forKey: handle)
        } else {
            pendingCentralWrites[handle] = queued
        }
    }

    private func ingest(_ packet: Data, from peerHandle: UInt64) {
        do {
            let fragment = try Self.parseFragment(packet)
            let key = "\(peerHandle):\(fragment.messageID.uuidString)"
            var assembly = assemblies[key] ?? FragmentAssembly(total: fragment.total)
            guard assembly.total == fragment.total else { throw BackendError.invalidFragment }
            assembly.pieces[fragment.index] = fragment.payload
            assemblies[key] = assembly
            purgeAssemblies()
            guard assembly.pieces.count == Int(assembly.total) else { return }
            assemblies.removeValue(forKey: key)
            var data = Data()
            for index in 0..<assembly.total {
                guard let piece = assembly.pieces[index] else { throw BackendError.invalidFragment }
                data.append(piece)
            }
            let envelope = try JSONDecoder().decode(WireEnvelope.self, from: data)
            guard envelope.version == 1 else { throw BackendError.protocolVersion }
            guard !envelope.isExpired else {
                emit(.init(type: "controlExpired", peerHandle: peerHandle, messageID: envelope.messageID.uuidString, sequence: envelope.sequence))
                return
            }
            switch envelope.kind {
            case .ack:
                emit(.init(type: "controlAcknowledged", peerHandle: peerHandle, messageID: envelope.messageID.uuidString, sequence: envelope.sequence))
            case .data:
                let duplicate = seenMessageIDs.contains(envelope.messageID)
                remember(envelope.messageID)
                if !duplicate {
                    emit(.init(
                        type: "controlReceived",
                        peerHandle: peerHandle,
                        messageID: envelope.messageID.uuidString,
                        sequence: envelope.sequence,
                        payloadBase64: envelope.payload?.base64EncodedString(),
                        fields: ["duplicate": "false"]
                    ))
                }
                if envelope.requiresAck {
                    let ack = WireEnvelope(
                        kind: .ack,
                        messageID: envelope.messageID,
                        sequence: envelope.sequence,
                        createdAtMillis: Self.nowMillis,
                        ttlMillis: 15_000,
                        requiresAck: false,
                        payload: nil
                    )
                    try? transmit(ack, to: peerHandle)
                }
            }
        } catch {
            emit(.init(type: "transportError", peerHandle: peerHandle, error: String(describing: error)))
        }
    }

    private func remember(_ id: UUID) {
        guard seenMessageIDs.insert(id).inserted else { return }
        seenMessageOrder.append(id)
        if seenMessageOrder.count > 1_024 {
            for old in seenMessageOrder.prefix(256) { seenMessageIDs.remove(old) }
            seenMessageOrder.removeFirst(256)
        }
    }

    private func purgeAssemblies() {
        let cutoff = Date.now.addingTimeInterval(-30)
        assemblies = assemblies.filter { $0.value.createdAt >= cutoff }
    }

    private func emit(_ event: Event) {
        do { eventSink(try JSONEncoder().encode(event)) }
        catch { /* Event consists only of JSON-safe values. */ }
    }

    private static var nowMillis: UInt64 { UInt64(max(0, Date.now.timeIntervalSince1970 * 1_000)) }

    private static func fragment(_ data: Data, messageID: UUID, maximumPacketSize: Int) throws -> [Data] {
        let headerSize = 23
        guard maximumPacketSize > headerSize else { throw BackendError.mtuTooSmall }
        let chunkSize = maximumPacketSize - headerSize
        let count = max(1, Int(ceil(Double(data.count) / Double(chunkSize))))
        guard count <= Int(UInt16.max) else { throw BackendError.controlPayloadTooLarge }
        return (0..<count).map { index in
            var packet = Data([0x54, 0x43, 1])
            var rawUUID = messageID.uuid
            withUnsafeBytes(of: &rawUUID) { packet.append(contentsOf: $0) }
            packet.appendUInt16(UInt16(index))
            packet.appendUInt16(UInt16(count))
            let start = index * chunkSize
            packet.append(data.subdata(in: start..<min(start + chunkSize, data.count)))
            return packet
        }
    }

    private static func parseFragment(_ data: Data) throws -> (messageID: UUID, index: UInt16, total: UInt16, payload: Data) {
        guard data.count >= 23, data[0] == 0x54, data[1] == 0x43, data[2] == 1 else { throw BackendError.invalidFragment }
        let uuidBytes = [UInt8](data[3..<19])
        let tuple: uuid_t = (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
        )
        let index = UInt16(data[19]) << 8 | UInt16(data[20])
        let total = UInt16(data[21]) << 8 | UInt16(data[22])
        guard total > 0, index < total else { throw BackendError.invalidFragment }
        return (UUID(uuid: tuple), index, total, data.subdata(in: 23..<data.count))
    }

    private enum BackendError: Error, CustomStringConvertible {
        case invalidField(String), controlPayloadTooLarge, peerUnavailable, mtuTooSmall, invalidFragment, protocolVersion
        var description: String {
            switch self {
            case let .invalidField(name): "invalid field: \(name)"
            case .controlPayloadTooLarge: "BLE control payload exceeds 4096 bytes"
            case .peerUnavailable: "requested BLE peer is unavailable"
            case .mtuTooSmall: "negotiated BLE MTU is too small"
            case .invalidFragment: "invalid BLE fragment"
            case .protocolVersion: "unsupported BLE control protocol version"
            }
        }
    }
}

extension TcBluetoothAppleBackend: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        emit(.init(type: "centralStateChanged", fields: ["state": String(describing: central.state)]))
        guard isRunning, central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let handle = handle(for: peripheral.identifier)
        peripherals[handle] = peripheral
        peripheral.delegate = self
        emit(.init(type: "peerAdvertisement", peerHandle: handle, fields: ["rssi": RSSI.stringValue]))
        if peripheral.state == .disconnected {
            central.connect(peripheral, options: [CBConnectPeripheralOptionEnableAutoReconnect: true])
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let handle = handle(for: peripheral.identifier)
        peripherals[handle] = peripheral
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
        // The ACL is not yet a bidirectional application channel. Rust only
        // receives `peerReady` after GATT discovery and notify subscription.
        emit(.init(type: "gattLinkConnected", peerHandle: handle))
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        emit(.init(type: "peerConnectionFailed", peerHandle: handle(for: peripheral.identifier), error: String(describing: error)))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, timestamp: CFAbsoluteTime, isReconnecting: Bool, error: (any Error)?) {
        let handle = handle(for: peripheral.identifier)
        writableCharacteristics.removeValue(forKey: handle)
        pendingCentralWrites.removeValue(forKey: handle)
        if !isReconnecting { peripherals.removeValue(forKey: handle) }
        emit(.init(type: "peerDisconnected", peerHandle: handle, fields: ["reconnecting": String(isReconnecting)], error: error.map(String.init(describing:))))
    }

    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        for peripheral in restored {
            let handle = handle(for: peripheral.identifier)
            peripherals[handle] = peripheral
            peripheral.delegate = self
            if peripheral.state == .connected { peripheral.discoverServices([Self.serviceUUID]) }
        }
        emit(.init(type: "stateRestored", fields: ["role": "central", "peerCount": String(restored.count)]))
    }
}

extension TcBluetoothAppleBackend: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard error == nil else {
            emit(.init(type: "gattError", peerHandle: handle(for: peripheral.identifier), error: String(describing: error)))
            return
        }
        for service in peripheral.services ?? [] where service.uuid == Self.serviceUUID {
            peripheral.discoverCharacteristics([Self.controlUUID], for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        guard error == nil else {
            emit(.init(type: "gattError", peerHandle: handle(for: peripheral.identifier), error: String(describing: error)))
            return
        }
        let handle = handle(for: peripheral.identifier)
        for characteristic in service.characteristics ?? [] where characteristic.uuid == Self.controlUUID {
            writableCharacteristics[handle] = characteristic
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        let handle = handle(for: peripheral.identifier)
        guard error == nil else {
            emit(.init(type: "gattError", peerHandle: handle, error: String(describing: error)))
            return
        }
        guard characteristic.uuid == Self.controlUUID, characteristic.isNotifying else { return }
        emit(.init(type: "peerReady", peerHandle: handle))
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard error == nil, let value = characteristic.value else {
            emit(.init(type: "gattError", peerHandle: handle(for: peripheral.identifier), error: String(describing: error)))
            return
        }
        ingest(value, from: handle(for: peripheral.identifier))
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        flushCentralWrites(to: handle(for: peripheral.identifier))
    }
}

extension TcBluetoothAppleBackend: @preconcurrency CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        emit(.init(type: "peripheralStateChanged", fields: ["state": String(describing: peripheral.state)]))
        guard isRunning, peripheral.state == .poweredOn else { return }
        configurePeripheralService()
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: (any Error)?) {
        guard error == nil else {
            emit(.init(type: "gattError", error: String(describing: error)))
            return
        }
        if !peripheral.isAdvertising {
            peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]])
        }
        emit(.init(type: "advertisingStarted"))
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        let handle = handle(for: central.identifier)
        subscribedCentrals[handle] = central
        emit(.init(type: "peerReady", peerHandle: handle, fields: ["role": "subscribedCentral"]))
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        let handle = handle(for: central.identifier)
        subscribedCentrals.removeValue(forKey: handle)
        emit(.init(type: "peerDisconnected", peerHandle: handle, fields: ["role": "subscribedCentral"]))
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            let handle = handle(for: request.central.identifier)
            if request.characteristic.uuid == Self.controlUUID, let value = request.value {
                ingest(value, from: handle)
                peripheral.respond(to: request, withResult: .success)
            } else {
                peripheral.respond(to: request, withResult: .requestNotSupported)
            }
        }
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard let characteristic = controlCharacteristic else { return }
        while !pendingNotifications.isEmpty {
            let pending = pendingNotifications.removeFirst()
            let targets = pending.central.map { [$0] }
            if !peripheral.updateValue(pending.data, for: characteristic, onSubscribedCentrals: targets) {
                pendingNotifications.insert(pending, at: 0)
                return
            }
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        if let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] {
            controlCharacteristic = services
                .flatMap { $0.characteristics ?? [] }
                .compactMap { $0 as? CBMutableCharacteristic }
                .first { $0.uuid == Self.controlUUID }
        }
        emit(.init(type: "stateRestored", fields: ["role": "peripheral"]))
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }
}

// MARK: - Module-private C ABI

public typealias BluetoothCEventCallback = @convention(c) (UnsafePointer<UInt8>?, Int, UInt) -> Void

private final class BluetoothCallbackBox: @unchecked Sendable {
    let callback: BluetoothCEventCallback
    let context: UInt
    init(callback: @escaping BluetoothCEventCallback, context: UInt) { self.callback = callback; self.context = context }
    @MainActor func send(_ data: Data) {
        data.withUnsafeBytes { bytes in callback(bytes.bindMemory(to: UInt8.self).baseAddress, data.count, context) }
    }
}

private final class BluetoothHandleSource: @unchecked Sendable {
    static let shared = BluetoothHandleSource()
    private let lock = NSLock()
    private var next: UInt64 = 1
    func allocate() -> UInt64 { lock.withLock { defer { next &+= 1 }; return next } }
}

@MainActor private enum BluetoothRuntime {
    static var backends: [UInt64: TcBluetoothAppleBackend] = [:]
}

@_cdecl("tc_bluetooth_apple_create")
public func tc_bluetooth_apple_create(_ callback: BluetoothCEventCallback?, _ context: UInt) -> UInt64 {
    guard let callback else { return 0 }
    let handle = BluetoothHandleSource.shared.allocate()
    let box = BluetoothCallbackBox(callback: callback, context: context)
    Task { @MainActor in BluetoothRuntime.backends[handle] = TcBluetoothAppleBackend(eventSink: box.send) }
    return handle
}

@_cdecl("tc_bluetooth_apple_submit")
public func tc_bluetooth_apple_submit(_ handle: UInt64, _ bytes: UnsafePointer<UInt8>?, _ length: Int) -> Bool {
    guard length >= 0, length == 0 || bytes != nil else { return false }
    let data = length == 0 ? Data() : Data(bytes: bytes!, count: length)
    Task { @MainActor in BluetoothRuntime.backends[handle]?.submit(data) }
    return true
}

@_cdecl("tc_bluetooth_apple_destroy")
public func tc_bluetooth_apple_destroy(_ handle: UInt64) {
    Task { @MainActor in
        BluetoothRuntime.backends.removeValue(forKey: handle)?.shutdown()
    }
}
