import Foundation
import BluetoothApple
import CallSystemApple
import LocationApple
import NotificationsApple
import PeerTransportApple
import RangingApple
import SecureStorageApple

/// Owns the Swift implementations passed to Rust as UniFFI foreign traits.
///
/// UniFFI callbacks are synchronous and may arrive on any thread. Each adapter
/// therefore accepts work synchronously, preserves command order in a private
/// async queue, and performs the actual framework call on the backend's actor.
@MainActor
final class AppleCapabilityRuntime {
    let bluetooth: BluetoothBackend
    let peerTransport: PeerTransportBackend
    let location: LocationBackend
    let ranging: RangingBackend
    let notifications: NotificationsBackend
    let callSystem: CallSystemBackend
    let secureStorage: SecureStorageBackend

    private let notificationsAdapter: AppleNotificationsBackend

    init() {
        bluetooth = AppleBluetoothBackend()
        peerTransport = ApplePeerTransportBackend()
        location = AppleLocationBackend()
        ranging = AppleRangingBackend()
        let notificationsAdapter = AppleNotificationsBackend()
        self.notificationsAdapter = notificationsAdapter
        notifications = notificationsAdapter
        callSystem = AppleCallSystemBackend()
        secureStorage = AppleSecureStorageBackend()
    }

    func handleNotificationResponse(_ userInfo: [String: String]) {
        notificationsAdapter.handleNotificationResponse(userInfo)
    }
}

private final class OrderedAsyncQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    private var isClosed = false

    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        appendLocked(operation)
        lock.unlock()
    }

    func finish(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        appendLocked(operation)
        lock.unlock()
    }

    private func appendLocked(_ operation: @escaping @Sendable () async -> Void) {
        let previous = tail
        let next = Task.detached {
            await previous?.value
            await operation()
        }
        tail = next
    }
}

/// Stores the Rust-owned sink safely and serializes events away from MainActor.
/// Rust event ingestion may touch SQLite, so framework delegate callbacks must
/// never invoke it directly on the UI executor.
private final class BackendEventRelay<Sink: AnyObject & Sendable, Event: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let deliver: @Sendable (Sink, Event) -> Void
    private var sink: Sink?

    init(label: String, deliver: @escaping @Sendable (Sink, Event) -> Void) {
        queue = DispatchQueue(label: label)
        self.deliver = deliver
    }

    func attach(_ sink: Sink) {
        lock.lock()
        self.sink = sink
        lock.unlock()
    }

    func emit(_ event: Event) {
        lock.lock()
        let sink = sink
        lock.unlock()
        guard let sink else { return }
        queue.async { [deliver] in deliver(sink, event) }
    }

    func close() {
        lock.lock()
        sink = nil
        lock.unlock()
    }
}

private extension BluetoothCapabilities {
    init(_ snapshot: BluetoothCapabilitySnapshot) {
        self.init(
            central: snapshot.central,
            peripheral: snapshot.peripheral,
            stateRestoration: snapshot.stateRestoration,
            backgroundControl: snapshot.backgroundControl,
            maxPacketBytes: snapshot.maxPacketBytes
        )
    }
}

private extension TransportCapabilities {
    init(_ snapshot: PeerTransportCapabilitySnapshot) {
        self.init(
            localOnly: snapshot.localOnly,
            peerToPeer: snapshot.peerToPeer,
            authenticatedStreams: snapshot.authenticatedStreams,
            bulkStreams: snapshot.bulkStreams,
            realtimeStreams: snapshot.realtimeStreams,
            maxDataFrameBytes: snapshot.maxDataFrameBytes
        )
    }
}

private extension LocationCapabilities {
    init(_ snapshot: LocationCapabilitySnapshot) {
        self.init(
            preciseLocation: snapshot.preciseLocation,
            backgroundUpdates: snapshot.backgroundUpdates,
            serviceSession: snapshot.serviceSession,
            backgroundActivitySession: snapshot.backgroundActivitySession
        )
    }
}

private extension RangingCapabilities {
    init(_ snapshot: RangingCapabilitySnapshot) {
        self.init(
            distance: snapshot.distance,
            direction: snapshot.direction,
            foregroundOnly: snapshot.foregroundOnly,
            maxConcurrentSessions: snapshot.maxConcurrentSessions
        )
    }
}

private extension NotificationCapabilities {
    init(_ snapshot: NotificationsCapabilitySnapshot) {
        self.init(
            localNotifications: snapshot.localNotifications,
            actions: snapshot.actions,
            timeSensitive: snapshot.timeSensitive
        )
    }
}

private extension CallSystemCapabilities {
    init(_ snapshot: CallSystemCapabilitySnapshot) {
        self.init(
            incomingCallUi: snapshot.incomingCallUI,
            backgroundAudio: snapshot.backgroundAudio,
            voiceProcessing: snapshot.voiceProcessing,
            bluetoothRoutes: snapshot.bluetoothRoutes
        )
    }
}

private extension SecureStorageCapabilities {
    init(_ snapshot: SecureStorageCapabilitySnapshot) {
        self.init(
            hardwareBackedWhenAvailable: snapshot.hardwareBackedWhenAvailable,
            deviceOnlyAccessibility: snapshot.deviceOnlyAccessibility,
            biometricPolicy: snapshot.biometricPolicy
        )
    }
}

private extension PeerTransportChannel {
    init(_ channel: TransportChannel) {
        switch channel {
        case .control: self = .control
        case .event: self = .event
        case .chunk: self = .chunk
        case .audio: self = .audio
        }
    }
}

private extension TransportChannel {
    init(_ channel: PeerTransportChannel) {
        switch channel {
        case .control: self = .control
        case .event: self = .event
        case .chunk: self = .chunk
        case .audio: self = .audio
        }
    }
}

private extension TransportConnectionSource {
    init(_ source: PeerTransportConnectionSource) {
        switch source {
        case .inbound: self = .inbound
        case .outbound: self = .outbound
        }
    }
}

private extension LocationAuthorization {
    init(_ authorization: LocationApple.LocationAuthorization) {
        switch authorization {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .whenInUse: self = .whenInUse
        case .always: self = .always
        }
    }
}

private extension LocationSampleRecord {
    init(_ sample: LocationApple.LocationSample) {
        self.init(
            latitude: sample.latitude,
            longitude: sample.longitude,
            altitudeM: sample.altitudeM,
            horizontalAccuracyM: sample.horizontalAccuracyM,
            speedMps: sample.speedMps,
            courseDegrees: sample.courseDegrees,
            sampledAtMs: sample.sampledAtMs
        )
    }
}

private extension NotificationAuthorization {
    init(_ authorization: NotificationsApple.NotificationAuthorization) {
        switch authorization {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .authorized: self = .authorized
        case .provisional: self = .provisional
        }
    }
}

private extension CallSystemAudioRoute {
    init(_ route: AudioRoute) {
        switch route {
        case .receiver: self = .receiver
        case .speaker: self = .speaker
        case .wiredHeadset: self = .wiredHeadset
        case .bluetooth: self = .bluetooth
        }
    }
}

private extension AudioRoute {
    init(_ route: CallSystemAudioRoute) {
        switch route {
        case .receiver: self = .receiver
        case .speaker: self = .speaker
        case .wiredHeadset: self = .wiredHeadset
        case .bluetooth: self = .bluetooth
        }
    }
}

private func deliverBluetoothEvent(_ event: BluetoothEvent, to sink: BluetoothEventSink) {
    switch event {
    case let .started(requestID):
        sink.started(requestId: requestID)
    case let .stopped(requestID):
        sink.stopped(requestId: requestID)
    case let .peerDiscovered(peerID, handle):
        sink.peerDiscovered(peerId: peerID, handle: handle)
    case let .connected(requestID, handle, maxPacketBytes):
        sink.connected(
            requestId: requestID,
            handle: handle,
            maxPacketBytes: maxPacketBytes
        )
    case let .disconnected(handle, reason):
        sink.disconnected(handle: handle, reason: reason)
    case let .packetReceived(handle, packet):
        sink.packetReceived(handle: handle, packet: packet)
    case let .packetSent(requestID):
        sink.packetSent(requestId: requestID)
    case let .failed(requestID, code, message, retryable):
        sink.failed(requestId: requestID, code: code, message: message, retryable: retryable)
    }
}

private func deliverPeerTransportEvent(
    _ event: PeerTransportEvent,
    to sink: PeerTransportEventSink
) {
    switch event {
    case let .discoveryStarted(requestID):
        sink.discoveryStarted(requestId: requestID)
    case let .discoveryStopped(requestID):
        sink.discoveryStopped(requestId: requestID)
    case let .peerFound(peerID):
        sink.peerFound(peerId: peerID)
    case let .connectionOpened(connection, source, expectedPeerID):
        sink.connectionOpened(
            connection: connection,
            source: TransportConnectionSource(source),
            expectedPeerId: expectedPeerID
        )
    case let .disconnected(connection, reason):
        sink.disconnected(connection: connection, reason: reason)
    case let .frameReceived(connection, channel, bytes):
        sink.frameReceived(
            connection: connection,
            channel: TransportChannel(channel),
            bytes: Data(bytes)
        )
    case let .sent(requestID):
        sink.sent(requestId: requestID)
    case let .failed(requestID, code, message, retryable):
        sink.failed(requestId: requestID, code: code, message: message, retryable: retryable)
    }
}

private func deliverLocationEvent(_ event: LocationEvent, to sink: LocationEventSink) {
    switch event {
    case let .started(requestID):
        sink.started(requestId: requestID)
    case let .stopped(requestID):
        sink.stopped(requestId: requestID)
    case let .authorizationChanged(status):
        sink.authorizationChanged(status: LocationAuthorization(status))
    case let .sample(requestID, sample, fromCache):
        sink.sample(
            requestId: requestID,
            sample: LocationSampleRecord(sample),
            fromCache: fromCache
        )
    case let .timedOut(requestID, staleSample):
        sink.timedOut(
            requestId: requestID,
            staleSample: staleSample.map { LocationSampleRecord($0) }
        )
    case let .failed(requestID, code, message, retryable):
        sink.failed(requestId: requestID, code: code, message: message, retryable: retryable)
    }
}

private func deliverRangingEvent(_ event: RangingEvent, to sink: RangingEventSink) {
    switch event {
    case let .discoveryToken(requestID, token):
        sink.discoveryToken(requestId: requestID, token: token)
    case let .started(requestID, peerID):
        sink.started(requestId: requestID, peerId: peerID)
    case let .measurement(peerID, distanceM, directionRadians, observedAtMs):
        sink.measurement(
            peerId: peerID,
            distanceM: distanceM,
            directionRadians: directionRadians,
            observedAtMs: observedAtMs
        )
    case let .suspended(peerID, reason):
        sink.suspended(peerId: peerID, reason: reason)
    case let .ended(peerID, reason):
        sink.ended(peerId: peerID, reason: reason)
    case let .failed(requestID, code, message, retryable):
        sink.failed(requestId: requestID, code: code, message: message, retryable: retryable)
    }
}

private func deliverNotificationEvent(
    _ event: NotificationsEvent,
    to sink: NotificationsEventSink
) {
    switch event {
    case let .authorizationChanged(status):
        sink.authorizationChanged(status: NotificationAuthorization(status))
    case let .scheduled(requestID, identifier):
        sink.scheduled(requestId: requestID, identifier: identifier)
    case let .cancelled(requestID, identifier):
        sink.cancelled(requestId: requestID, identifier: identifier)
    case let .opened(identifier, deepLink, action):
        sink.opened(identifier: identifier, deepLink: deepLink, action: action)
    case let .failed(requestID, code, message):
        sink.failed(requestId: requestID, code: code, message: message)
    }
}

private func deliverCallSystemEvent(_ event: CallSystemEvent, to sink: CallSystemEventSink) {
    switch event {
    case let .incomingReported(requestID, callID):
        sink.incomingReported(requestId: requestID, callId: callID)
    case let .outgoingReported(requestID, callID):
        sink.outgoingReported(requestId: requestID, callId: callID)
    case let .userAnswered(callID):
        sink.userAnswered(callId: callID)
    case let .userRejected(callID):
        sink.userRejected(callId: callID)
    case let .userEnded(callID):
        sink.userEnded(callId: callID)
    case let .audioActivated(callID):
        sink.audioActivated(callId: callID)
    case let .audioDeactivated(callID):
        sink.audioDeactivated(callId: callID)
    case let .audioInterrupted(callID, shouldResume):
        sink.audioInterrupted(callId: callID, shouldResume: shouldResume)
    case let .routeChanged(route):
        sink.routeChanged(route: AudioRoute(route))
    case let .audioFrame(callID, pcm16, sampleRate, channelCount, sequence, timestampMs):
        sink.audioFrame(
            callId: callID,
            pcm16: pcm16,
            sampleRate: sampleRate,
            channelCount: channelCount,
            sequence: sequence,
            timestampMs: timestampMs
        )
    case let .mutedChanged(callID, muted):
        sink.mutedChanged(callId: callID, muted: muted)
    case let .failed(requestID, code, message):
        sink.failed(requestId: requestID, code: code, message: message)
    }
}

private func deliverSecureStorageEvent(
    _ event: SecureStorageEvent,
    to sink: SecureStorageEventSink
) {
    switch event {
    case let .stored(requestID, key):
        sink.stored(requestId: requestID, key: key)
    case let .loaded(requestID, key, value):
        sink.loaded(requestId: requestID, key: key, value: value)
    case let .deleted(requestID, key):
        sink.deleted(requestId: requestID, key: key)
    case let .failed(requestID, code, message):
        sink.failed(requestId: requestID, code: code, message: message)
    }
}

private final class AppleBluetoothBackend: BluetoothBackend, @unchecked Sendable {
    private let capabilitySnapshot = BluetoothCapabilities(
        BluetoothAppleBackend.capabilitySnapshot
    )
    private let commands = OrderedAsyncQueue()
    private let relay: BackendEventRelay<BluetoothEventSink, BluetoothEvent>
    private let backend: BluetoothAppleBackend

    @MainActor
    init() {
        let relay = BackendEventRelay<BluetoothEventSink, BluetoothEvent>(
            label: "com.travelcompanion.uniffi.bluetooth-events",
            deliver: { sink, event in deliverBluetoothEvent(event, to: sink) }
        )
        self.relay = relay
        backend = BluetoothAppleBackend { [weak relay] in relay?.emit($0) }
    }

    func capabilities() -> BluetoothCapabilities { capabilitySnapshot }

    func attachEventSink(eventSink: BluetoothEventSink) { relay.attach(eventSink) }

    func start(requestId: String) {
        commands.enqueue { [backend] in await backend.start(requestID: requestId) }
    }

    func stop(requestId: String) {
        commands.enqueue { [backend] in await backend.stop(requestID: requestId) }
    }

    func connect(requestId: String, handle: UInt64) {
        commands.enqueue { [backend] in
            await backend.connect(requestID: requestId, handle: handle)
        }
    }

    func disconnect(requestId: String, handle: UInt64) {
        commands.enqueue { [backend] in
            await backend.disconnect(requestID: requestId, handle: handle)
        }
    }

    func sendPacket(
        requestId: String,
        handle: UInt64,
        packet: Data
    ) {
        commands.enqueue { [backend] in
            await backend.sendPacket(
                requestID: requestId,
                handle: handle,
                packet: packet
            )
        }
    }

    func shutdown() {
        relay.close()
        commands.finish { [backend] in await backend.shutdown() }
    }
}

private final class ApplePeerTransportBackend: PeerTransportBackend, @unchecked Sendable {
    private let capabilitySnapshot = TransportCapabilities(
        PeerTransportAppleBackend.capabilitySnapshot
    )
    private let commands = OrderedAsyncQueue()
    private let relay: BackendEventRelay<PeerTransportEventSink, PeerTransportEvent>
    private let backend: PeerTransportAppleBackend

    init() {
        let relay = BackendEventRelay<PeerTransportEventSink, PeerTransportEvent>(
            label: "com.travelcompanion.uniffi.peer-transport-events",
            deliver: { sink, event in deliverPeerTransportEvent(event, to: sink) }
        )
        self.relay = relay
        backend = PeerTransportAppleBackend { [weak relay] in relay?.emit($0) }
    }

    func capabilities() -> TransportCapabilities { capabilitySnapshot }

    func attachEventSink(eventSink: PeerTransportEventSink) { relay.attach(eventSink) }

    func startDiscovery(
        requestId: String,
        localPeerId: String,
        discoveryScope: String,
        displayName: String,
        protocolVersion: UInt16,
        certificateDer: Data,
        privateKeyPkcs8: Data
    ) {
        commands.enqueue { [backend] in
            await backend.startDiscovery(
                requestID: requestId,
                localPeerID: localPeerId,
                discoveryScope: discoveryScope,
                displayName: displayName,
                protocolVersion: protocolVersion,
                certificateDER: [UInt8](certificateDer),
                privateKeyPKCS8: [UInt8](privateKeyPkcs8)
            )
        }
    }

    func stopDiscovery(requestId: String) {
        commands.enqueue { [backend] in await backend.stopDiscovery(requestID: requestId) }
    }

    func connect(requestId: String, peerId: String) {
        commands.enqueue { [backend] in
            await backend.connect(requestID: requestId, peerID: peerId)
        }
    }

    func disconnect(requestId: String, connection: UInt64) {
        commands.enqueue { [backend] in
            await backend.disconnect(requestID: requestId, connection: connection)
        }
    }

    func sendFrame(
        requestId: String,
        connection: UInt64,
        channel: TransportChannel,
        bytes: Data
    ) {
        commands.enqueue { [backend] in
            await backend.sendFrame(
                requestID: requestId,
                connection: connection,
                channel: PeerTransportChannel(channel),
                bytes: [UInt8](bytes)
            )
        }
    }

    func setRealtime(requestId: String, realtime: Bool) {
        commands.enqueue { [backend] in
            await backend.setRealtime(requestID: requestId, realtime: realtime)
        }
    }

    func shutdown() {
        relay.close()
        commands.finish { [backend] in await backend.shutdown() }
    }
}

private final class AppleLocationBackend: LocationBackend, @unchecked Sendable {
    private let capabilitySnapshot = LocationCapabilities(
        LocationAppleBackend.capabilitySnapshot
    )
    private let commands = OrderedAsyncQueue()
    private let relay: BackendEventRelay<LocationEventSink, LocationEvent>
    private let backend: LocationAppleBackend

    @MainActor
    init() {
        let relay = BackendEventRelay<LocationEventSink, LocationEvent>(
            label: "com.travelcompanion.uniffi.location-events",
            deliver: { sink, event in deliverLocationEvent(event, to: sink) }
        )
        self.relay = relay
        backend = LocationAppleBackend { [weak relay] in relay?.emit($0) }
    }

    func capabilities() -> LocationCapabilities { capabilitySnapshot }

    func attachEventSink(eventSink: LocationEventSink) { relay.attach(eventSink) }

    func startTravelUpdates(requestId: String, background: Bool) {
        commands.enqueue { [backend] in
            await backend.startTravelUpdates(requestID: requestId, background: background)
        }
    }

    func stopTravelUpdates(requestId: String) {
        commands.enqueue { [backend] in
            await backend.stopTravelUpdates(requestID: requestId)
        }
    }

    func requestSample(requestId: String, desiredFreshnessMs: Int64, deadlineMs: Int64) {
        commands.enqueue { [backend] in
            await backend.requestSample(
                requestID: requestId,
                desiredFreshnessMs: desiredFreshnessMs,
                deadlineMs: deadlineMs
            )
        }
    }

    func shutdown() {
        relay.close()
        commands.finish { [backend] in await backend.shutdown() }
    }
}

private final class AppleRangingBackend: RangingBackend, @unchecked Sendable {
    private let capabilitySnapshot = RangingCapabilities(
        RangingAppleBackend.capabilitySnapshot
    )
    private let commands = OrderedAsyncQueue()
    private let relay: BackendEventRelay<RangingEventSink, RangingEvent>
    private let backend: RangingAppleBackend

    @MainActor
    init() {
        let relay = BackendEventRelay<RangingEventSink, RangingEvent>(
            label: "com.travelcompanion.uniffi.ranging-events",
            deliver: { sink, event in deliverRangingEvent(event, to: sink) }
        )
        self.relay = relay
        backend = RangingAppleBackend { [weak relay] in relay?.emit($0) }
    }

    func capabilities() -> RangingCapabilities { capabilitySnapshot }

    func attachEventSink(eventSink: RangingEventSink) { relay.attach(eventSink) }

    func createDiscoveryToken(requestId: String, peerId: String) {
        commands.enqueue { [backend] in
            await backend.createDiscoveryToken(requestID: requestId, peerID: peerId)
        }
    }

    func start(requestId: String, peerId: String, remoteDiscoveryToken: Data) {
        commands.enqueue { [backend] in
            await backend.start(
                requestID: requestId,
                peerID: peerId,
                remoteDiscoveryToken: remoteDiscoveryToken
            )
        }
    }

    func cancel(requestId: String, peerId: String, reason: String) {
        commands.enqueue { [backend] in
            await backend.cancel(requestID: requestId, peerID: peerId, reason: reason)
        }
    }

    func shutdown() {
        relay.close()
        commands.finish { [backend] in await backend.shutdown() }
    }
}

private final class AppleNotificationsBackend: NotificationsBackend, @unchecked Sendable {
    private let capabilitySnapshot = NotificationCapabilities(
        NotificationsAppleBackend.capabilitySnapshot
    )
    private let commands = OrderedAsyncQueue()
    private let relay: BackendEventRelay<NotificationsEventSink, NotificationsEvent>
    private let backend: NotificationsAppleBackend

    @MainActor
    init() {
        let relay = BackendEventRelay<NotificationsEventSink, NotificationsEvent>(
            label: "com.travelcompanion.uniffi.notifications-events",
            deliver: { sink, event in deliverNotificationEvent(event, to: sink) }
        )
        self.relay = relay
        backend = NotificationsAppleBackend { [weak relay] in relay?.emit($0) }
    }

    func capabilities() -> NotificationCapabilities { capabilitySnapshot }

    func attachEventSink(eventSink: NotificationsEventSink) { relay.attach(eventSink) }

    func requestAuthorization(requestId: String) {
        commands.enqueue { [backend] in
            await backend.requestAuthorization(requestID: requestId)
        }
    }

    func schedule(
        requestId: String,
        identifier: String,
        title: String,
        body: String,
        deepLink: String?,
        mergeKey: String?,
        timeSensitive: Bool
    ) {
        commands.enqueue { [backend] in
            await backend.schedule(
                requestID: requestId,
                identifier: identifier,
                title: title,
                body: body,
                deepLink: deepLink,
                mergeKey: mergeKey,
                timeSensitive: timeSensitive
            )
        }
    }

    func cancel(requestId: String, identifier: String) {
        commands.enqueue { [backend] in
            await backend.cancel(requestID: requestId, identifier: identifier)
        }
    }

    func shutdown() {
        relay.close()
        commands.finish { [backend] in await backend.shutdown() }
    }

    @MainActor
    func handleNotificationResponse(_ userInfo: [String: String]) {
        backend.handleNotificationResponse(userInfo: userInfo)
    }
}

private final class AppleCallSystemBackend: CallSystemBackend, @unchecked Sendable {
    private let capabilitySnapshot = CallSystemCapabilities(
        CallSystemAppleBackend.capabilitySnapshot
    )
    private let commands = OrderedAsyncQueue()
    private let relay: BackendEventRelay<CallSystemEventSink, CallSystemEvent>
    private let backend: CallSystemAppleBackend

    @MainActor
    init() {
        let relay = BackendEventRelay<CallSystemEventSink, CallSystemEvent>(
            label: "com.travelcompanion.uniffi.call-system-events",
            deliver: { sink, event in deliverCallSystemEvent(event, to: sink) }
        )
        self.relay = relay
        backend = CallSystemAppleBackend { [weak relay] in relay?.emit($0) }
    }

    func capabilities() -> CallSystemCapabilities { capabilitySnapshot }

    func attachEventSink(eventSink: CallSystemEventSink) { relay.attach(eventSink) }

    func reportIncoming(requestId: String, callId: String, peerId: String, displayName: String) {
        commands.enqueue { [backend] in
            await backend.reportIncoming(
                requestID: requestId,
                callID: callId,
                peerID: peerId,
                displayName: displayName
            )
        }
    }

    func reportOutgoing(requestId: String, callId: String, peerId: String, displayName: String) {
        commands.enqueue { [backend] in
            await backend.reportOutgoing(
                requestID: requestId,
                callID: callId,
                peerID: peerId,
                displayName: displayName
            )
        }
    }

    func activateAudio(requestId: String, callId: String) {
        commands.enqueue { [backend] in
            await backend.activateAudio(requestID: requestId, callID: callId)
        }
    }

    func deactivateAudio(requestId: String, callId: String) {
        commands.enqueue { [backend] in
            await backend.deactivateAudio(requestID: requestId, callID: callId)
        }
    }

    func setMuted(requestId: String, callId: String, muted: Bool) {
        commands.enqueue { [backend] in
            await backend.setMuted(requestID: requestId, callID: callId, muted: muted)
        }
    }

    func setRoute(requestId: String, route: AudioRoute) {
        commands.enqueue { [backend] in
            await backend.setRoute(requestID: requestId, route: CallSystemAudioRoute(route))
        }
    }

    func playAudio(
        requestId: String,
        callId: String,
        pcm16: Data,
        sampleRate: UInt32,
        channelCount: UInt32,
        sequence: UInt64,
        timestampMs: Int64
    ) {
        commands.enqueue { [backend] in
            await backend.playAudio(
                requestID: requestId,
                callID: callId,
                pcm16: pcm16,
                sampleRate: sampleRate,
                channelCount: channelCount,
                sequence: sequence,
                timestampMs: timestampMs
            )
        }
    }

    func end(requestId: String, callId: String, reason: String) {
        commands.enqueue { [backend] in
            await backend.end(requestID: requestId, callID: callId, reason: reason)
        }
    }

    func shutdown() {
        relay.close()
        commands.finish { [backend] in await backend.shutdown() }
    }
}

private final class AppleSecureStorageBackend: SecureStorageBackend, @unchecked Sendable {
    private let capabilitySnapshot = SecureStorageCapabilities(
        SecureStorageAppleBackend.capabilitySnapshot
    )
    private let commands = OrderedAsyncQueue()
    private let relay: BackendEventRelay<SecureStorageEventSink, SecureStorageEvent>
    private let backend: SecureStorageAppleBackend

    init() {
        let relay = BackendEventRelay<SecureStorageEventSink, SecureStorageEvent>(
            label: "com.travelcompanion.uniffi.secure-storage-events",
            deliver: { sink, event in deliverSecureStorageEvent(event, to: sink) }
        )
        self.relay = relay
        backend = SecureStorageAppleBackend { [weak relay] in relay?.emit($0) }
    }

    func capabilities() -> SecureStorageCapabilities { capabilitySnapshot }

    func attachEventSink(eventSink: SecureStorageEventSink) { relay.attach(eventSink) }

    func put(requestId: String, key: String, value: Data) {
        commands.enqueue { [backend] in
            await backend.put(requestID: requestId, key: key, value: value)
        }
    }

    func get(requestId: String, key: String) {
        commands.enqueue { [backend] in await backend.get(requestID: requestId, key: key) }
    }

    func delete(requestId: String, key: String) {
        commands.enqueue { [backend] in await backend.delete(requestID: requestId, key: key) }
    }

    func shutdown() {
        relay.close()
        commands.finish { [backend] in await backend.shutdown() }
    }
}
