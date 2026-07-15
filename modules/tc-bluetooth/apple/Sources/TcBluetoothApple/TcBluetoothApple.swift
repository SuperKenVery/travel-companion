@preconcurrency import CoreBluetooth
import Foundation

public enum TcBluetoothEvent: Sendable, Equatable {
    case started(requestID: String)
    case stopped(requestID: String)
    case peerDiscovered(peerID: String, handle: UInt64)
    case connected(requestID: String, handle: UInt64)
    case disconnected(handle: UInt64, reason: String)
    case packetReceived(handle: UInt64, packet: Data)
    case packetSent(requestID: String)
    case failed(requestID: String?, code: String, message: String, retryable: Bool)
}

public typealias TcBluetoothEventSink = @MainActor @Sendable (TcBluetoothEvent) -> Void

/// Platform capability values exposed without leaking CoreBluetooth objects.
public struct TcBluetoothCapabilitySnapshot: Sendable, Equatable {
    public let central: Bool
    public let peripheral: Bool
    public let stateRestoration: Bool
    public let backgroundControl: Bool
    public let maxPacketBytes: UInt32

    public init(
        central: Bool,
        peripheral: Bool,
        stateRestoration: Bool,
        backgroundControl: Bool,
        maxPacketBytes: UInt32
    ) {
        self.central = central
        self.peripheral = peripheral
        self.stateRestoration = stateRestoration
        self.backgroundControl = backgroundControl
        self.maxPacketBytes = maxPacketBytes
    }
}

/// Core Bluetooth backend. All CoreBluetooth objects remain owned by this main-actor object;
/// callers only see typed values and stable UInt64 handles.
@MainActor
public final class TcBluetoothAppleBackend: NSObject {
    private static let serviceUUID = CBUUID(string: "7D59F31B-FF93-4D06-9B34-1AF354A3D581")
    private static let controlUUID = CBUUID(string: "7D59F31C-FF93-4D06-9B34-1AF354A3D581")

    private static let centralRestoreID = "com.travelcompanion.tc-bluetooth.central"
    private static let peripheralRestoreID = "com.travelcompanion.tc-bluetooth.peripheral"
    private nonisolated static let maximumPacketBytes = 180

    public nonisolated static var capabilitySnapshot: TcBluetoothCapabilitySnapshot {
        TcBluetoothCapabilitySnapshot(
            central: true,
            peripheral: true,
            stateRestoration: true,
            backgroundControl: true,
            maxPacketBytes: UInt32(maximumPacketBytes)
        )
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
    private var readyHandles: Set<UInt64> = []
    private var pendingConnectRequests: [UInt64: String] = [:]
    private var pendingNotifications: [PendingNotification] = []
    private var pendingCentralWrites: [UInt64: [Data]] = [:]

    public init(eventSink: @escaping TcBluetoothEventSink) {
        self.eventSink = eventSink
        super.init()
    }

    public func shutdown() {
        tearDown()
    }

    public func start(requestID: String) {
        guard !isRunning else {
            emit(.started(requestID: requestID))
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
        emit(.started(requestID: requestID))
    }

    public func stop(requestID: String) {
        tearDown()
        emit(.stopped(requestID: requestID))
    }

    private func tearDown() {
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
        readyHandles.removeAll()
        pendingConnectRequests.removeAll()
        pendingNotifications.removeAll()
        pendingCentralWrites.removeAll()
        isRunning = false
    }

    public func connect(requestID: String, handle: UInt64) {
        do {
            try connectOperation(requestID: requestID, handle: handle)
        } catch {
            fail(
                requestID: requestID,
                code: "commandFailed",
                message: String(describing: error),
                retryable: error.isRetryableBluetoothError
            )
        }
    }

    private func connectOperation(requestID: String, handle: UInt64) throws {
        if readyHandles.contains(handle) {
            emit(.connected(requestID: requestID, handle: handle))
            return
        }

        pendingConnectRequests[handle] = requestID
        guard let peripheral = peripherals[handle] else {
            // A subscribed central becomes ready through the peripheral role and
            // will complete this request from didSubscribeTo.
            if subscribedCentrals[handle] != nil { return }
            pendingConnectRequests.removeValue(forKey: handle)
            throw BackendError.peerUnavailable
        }
        switch peripheral.state {
        case .disconnected:
            centralManager?.connect(peripheral, options: [CBConnectPeripheralOptionEnableAutoReconnect: true])
        case .connected:
            peripheral.discoverServices([Self.serviceUUID])
        case .connecting, .disconnecting:
            break
        @unknown default:
            break
        }
    }

    public func sendPacket(
        requestID: String,
        handle: UInt64,
        packet: Data
    ) {
        do {
            try sendPacketOperation(handle: handle, packet: packet)
            emit(.packetSent(requestID: requestID))
        } catch {
            fail(
                requestID: requestID,
                code: "commandFailed",
                message: String(describing: error),
                retryable: error.isRetryableBluetoothError
            )
        }
    }

    public func disconnect(requestID: String, handle: UInt64) {
        do {
            guard let peripheral = peripherals[handle] else { throw BackendError.peerUnavailable }
            pendingConnectRequests.removeValue(forKey: handle)
            centralManager?.cancelPeripheralConnection(peripheral)
        } catch {
            fail(
                requestID: requestID,
                code: "commandFailed",
                message: String(describing: error),
                retryable: error.isRetryableBluetoothError
            )
        }
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
        if let existing = handleByPlatformID[platformID] {
            return existing
        }
        let handle = nextPeerHandle
        nextPeerHandle &+= 1
        handleByPlatformID[platformID] = handle
        let peerID = platformID.uuidString.lowercased()
        emit(.peerDiscovered(peerID: peerID, handle: handle))
        return handle
    }

    private func markReady(_ handle: UInt64) {
        readyHandles.insert(handle)
        guard let requestID = pendingConnectRequests.removeValue(forKey: handle) else { return }
        emit(.connected(requestID: requestID, handle: handle))
    }

    private func sendPacketOperation(handle target: UInt64, packet: Data) throws {
        guard !packet.isEmpty, packet.count <= Self.maximumPacketBytes else {
            throw BackendError.packetTooLarge
        }
        var sentPaths = 0

        for (handle, characteristic) in writableCharacteristics where target == handle {
            guard let peripheral = peripherals[handle], peripheral.state == .connected else { continue }
            let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            let maximum = peripheral.maximumWriteValueLength(for: writeType)
            guard packet.count <= maximum else { throw BackendError.mtuTooSmall }
            if writeType == .withoutResponse {
                pendingCentralWrites[handle, default: []].append(packet)
            } else {
                peripheral.writeValue(packet, for: characteristic, type: writeType)
            }
            flushCentralWrites(to: handle)
            sentPaths += 1
        }

        if let peripheralManager, let characteristic = controlCharacteristic {
            for (handle, central) in subscribedCentrals where target == handle {
                guard packet.count <= central.maximumUpdateValueLength else {
                    throw BackendError.mtuTooSmall
                }
                if !peripheralManager.updateValue(packet, for: characteristic, onSubscribedCentrals: [central]) {
                    pendingNotifications.append(.init(data: packet, central: central))
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

    private func receive(_ packet: Data, from peerHandle: UInt64) {
        emit(.packetReceived(handle: peerHandle, packet: packet))
    }

    private func emit(_ event: TcBluetoothEvent) {
        eventSink(event)
    }

    private func fail(
        requestID: String? = nil,
        code: String,
        message: String,
        retryable: Bool
    ) {
        emit(.failed(
            requestID: requestID,
            code: code,
            message: message,
            retryable: retryable
        ))
    }

    fileprivate enum BackendError: Error, CustomStringConvertible {
        case packetTooLarge, peerUnavailable, mtuTooSmall
        var description: String {
            switch self {
            case .packetTooLarge: "BLE packet exceeds the advertised platform packet limit"
            case .peerUnavailable: "requested BLE peer is unavailable"
            case .mtuTooSmall: "negotiated BLE MTU is too small"
            }
        }
    }
}

private extension Error {
    var isRetryableBluetoothError: Bool {
        guard let error = self as? TcBluetoothAppleBackend.BackendError else { return false }
        switch error {
        case .peerUnavailable, .mtuTooSmall:
            return true
        case .packetTooLarge:
            return false
        }
    }
}

extension TcBluetoothAppleBackend: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard isRunning, central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let handle = handle(for: peripheral.identifier)
        peripherals[handle] = peripheral
        peripheral.delegate = self
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
        // receives `connected` after GATT discovery and notify subscription.
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        let handle = handle(for: peripheral.identifier)
        fail(
            requestID: pendingConnectRequests.removeValue(forKey: handle),
            code: "peerConnectionFailed",
            message: error.map(String.init(describing:)) ?? "CoreBluetooth failed to connect",
            retryable: true
        )
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, timestamp: CFAbsoluteTime, isReconnecting: Bool, error: (any Error)?) {
        let handle = handle(for: peripheral.identifier)
        writableCharacteristics.removeValue(forKey: handle)
        pendingCentralWrites.removeValue(forKey: handle)
        readyHandles.remove(handle)
        if !isReconnecting { peripherals.removeValue(forKey: handle) }
        emit(.disconnected(
            handle: handle,
            reason: error.map(String.init(describing:)) ?? (isReconnecting ? "reconnecting" : "disconnected")
        ))
    }

    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        for peripheral in restored {
            let handle = handle(for: peripheral.identifier)
            peripherals[handle] = peripheral
            peripheral.delegate = self
            if peripheral.state == .connected { peripheral.discoverServices([Self.serviceUUID]) }
        }
    }
}

extension TcBluetoothAppleBackend: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard error == nil else {
            let handle = handle(for: peripheral.identifier)
            fail(
                requestID: pendingConnectRequests.removeValue(forKey: handle),
                code: "gattError",
                message: error.map(String.init(describing:)) ?? "service discovery failed",
                retryable: true
            )
            return
        }
        for service in peripheral.services ?? [] where service.uuid == Self.serviceUUID {
            peripheral.discoverCharacteristics([Self.controlUUID], for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        guard error == nil else {
            let handle = handle(for: peripheral.identifier)
            fail(
                requestID: pendingConnectRequests.removeValue(forKey: handle),
                code: "gattError",
                message: error.map(String.init(describing:)) ?? "characteristic discovery failed",
                retryable: true
            )
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
            fail(
                requestID: pendingConnectRequests.removeValue(forKey: handle),
                code: "gattError",
                message: error.map(String.init(describing:)) ?? "notification subscription failed",
                retryable: true
            )
            return
        }
        guard characteristic.uuid == Self.controlUUID, characteristic.isNotifying else { return }
        markReady(handle)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard error == nil, let value = characteristic.value else {
            fail(
                code: "gattError",
                message: error.map(String.init(describing:)) ?? "characteristic update had no value",
                retryable: true
            )
            return
        }
        receive(value, from: handle(for: peripheral.identifier))
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        flushCentralWrites(to: handle(for: peripheral.identifier))
    }
}

extension TcBluetoothAppleBackend: @preconcurrency CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard isRunning, peripheral.state == .poweredOn else { return }
        configurePeripheralService()
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: (any Error)?) {
        guard error == nil else {
            fail(
                code: "gattError",
                message: error.map(String.init(describing:)) ?? "failed to publish BLE service",
                retryable: true
            )
            return
        }
        if !peripheral.isAdvertising {
            peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]])
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        let handle = handle(for: central.identifier)
        subscribedCentrals[handle] = central
        markReady(handle)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        let handle = handle(for: central.identifier)
        subscribedCentrals.removeValue(forKey: handle)
        readyHandles.remove(handle)
        emit(.disconnected(handle: handle, reason: "subscription ended"))
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            let handle = handle(for: request.central.identifier)
            if request.characteristic.uuid == Self.controlUUID, let value = request.value {
                receive(value, from: handle)
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
    }
}
