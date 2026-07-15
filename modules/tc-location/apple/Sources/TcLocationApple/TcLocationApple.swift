@preconcurrency import CoreLocation
import Foundation

public typealias TcLocationEventSink = @MainActor @Sendable (Data) -> Void

@MainActor
public final class TcLocationAppleBackend {
    private struct Command: Decodable {
        var type: String
        var requestID: String?
        var liveConfiguration: String?
        var sharingPaused: Bool?
        var foreground: Bool?
        var desiredFreshnessMillis: UInt64?
        var deadlineEpochMillis: UInt64?
        var minimumEmitIntervalMillis: UInt64?
        var minimumDistanceMeters: Double?
    }

    private struct Event: Encodable {
        var type: String
        var requestID: String?
        var sample: Sample?
        var status: String?
        var fields: [String: String]?
        var error: String?
    }

    public struct Sample: Codable, Sendable {
        public var latitude: Double
        public var longitude: Double
        public var altitude: Double
        public var horizontalAccuracy: Double
        public var verticalAccuracy: Double
        public var speed: Double
        public var speedAccuracy: Double
        public var course: Double
        public var courseAccuracy: Double
        public var sampledAtEpochMillis: UInt64
        public var stationary: Bool
        public var simulated: Bool?
        public var producedByAccessory: Bool?
    }

    private let eventSink: TcLocationEventSink
    private var serviceSession: CLServiceSession?
    private var backgroundSession: CLBackgroundActivitySession?
    private var updateTask: Task<Void, Never>?
    private var serviceDiagnosticTask: Task<Void, Never>?
    private var backgroundDiagnosticTask: Task<Void, Never>?
    private var sampleTasks: [String: Task<Void, Never>] = [:]
    private var sampleTaskTokens: [String: UUID] = [:]
    private var latestLocation: CLLocation?
    private var latestSample: Sample?
    private var lastEmittedLocation: CLLocation?
    private var lastEmittedAt: Date?
    private var isRunning = false
    private var sharingPaused = false
    private var appForeground = true
    private var minimumEmitInterval: TimeInterval = 10
    private var minimumDistanceMeters: CLLocationDistance = 10
    private var liveConfiguration: CLLocationUpdate.LiveConfiguration = .default
    private var emittedBlockingDiagnostic = false

    public init(eventSink: @escaping TcLocationEventSink) {
        self.eventSink = eventSink
    }

    public func submit(_ json: Data) {
        let command: Command
        do {
            command = try JSONDecoder().decode(Command.self, from: json)
        } catch {
            emit(.init(type: "commandFailed", error: String(describing: error)))
            return
        }
        switch command.type {
        case "start": start(command)
        case "stop": stop(requestID: command.requestID)
        case "setSharingPaused":
            sharingPaused = command.sharingPaused ?? true
            if sharingPaused { cancelSampleTasks(status: "sharingPaused") }
            emit(.init(type: "sharingStateChanged", requestID: command.requestID, status: sharingPaused ? "paused" : "active"))
        case "setForeground":
            appForeground = command.foreground ?? false
            emit(.init(type: "foregroundStateChanged", requestID: command.requestID, status: appForeground ? "foreground" : "background"))
        case "requestSample": requestSample(command)
        case "snapshot": emitSnapshot(requestID: command.requestID)
        default: emit(.init(type: "commandFailed", requestID: command.requestID, error: "unknown command: \(command.type)"))
        }
    }

    public func shutdown() { stop(requestID: nil) }

    private func start(_ command: Command) {
        tearDownSessions()
        let authorization = CLLocationManager().authorizationStatus
        guard CLLocationManager.locationServicesEnabled(), authorization != .denied, authorization != .restricted else {
            isRunning = false
            emit(.init(type: "commandFailed", requestID: command.requestID, error: "Location Services are disabled or authorization is denied"))
            return
        }
        minimumEmitInterval = TimeInterval(command.minimumEmitIntervalMillis ?? 10_000) / 1_000
        minimumDistanceMeters = max(0, command.minimumDistanceMeters ?? 10)
        liveConfiguration = Self.configuration(named: command.liveConfiguration)
        let background = command.liveConfiguration != nil && command.liveConfiguration != "default"
        serviceSession = CLServiceSession(authorization: background ? .always : .whenInUse)
        backgroundSession = background ? CLBackgroundActivitySession() : nil
        emittedBlockingDiagnostic = false
        isRunning = true
        observeDiagnostics()
        startLiveUpdates()
        emit(.init(type: "commandCompleted", requestID: command.requestID, fields: [
            "command": "start",
            "authorization": String(describing: CLLocationManager().authorizationStatus),
            "backgroundActivitySession": String(background),
        ]))
    }

    private func stop(requestID: String?) {
        tearDownSessions()
        isRunning = false
        emit(.init(type: "commandCompleted", requestID: requestID, fields: ["command": "stop"]))
    }

    private func tearDownSessions() {
        updateTask?.cancel()
        serviceDiagnosticTask?.cancel()
        backgroundDiagnosticTask?.cancel()
        updateTask = nil
        serviceDiagnosticTask = nil
        backgroundDiagnosticTask = nil
        for task in sampleTasks.values { task.cancel() }
        sampleTasks.removeAll()
        sampleTaskTokens.removeAll()
        serviceSession?.invalidate()
        backgroundSession?.invalidate()
        serviceSession = nil
        backgroundSession = nil
    }

    private func startLiveUpdates() {
        let configuration = liveConfiguration
        updateTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await update in CLLocationUpdate.liveUpdates(configuration) {
                    try Task.checkCancellation()
                    if let location = update.location {
                        self.consume(location, stationary: update.stationary, source: "live")
                    } else {
                        self.emitUpdateDiagnostic(update)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                self.emit(.init(type: "locationStreamFailed", error: String(describing: error)))
            }
        }
    }

    @discardableResult
    private func consume(_ location: CLLocation, stationary: Bool, source: String) -> Sample? {
        guard
            CLLocationCoordinate2DIsValid(location.coordinate),
            location.horizontalAccuracy >= 0,
            latestLocation.map({ location.timestamp >= $0.timestamp }) ?? true
        else { return nil }
        latestLocation = location
        let sourceInfo = location.sourceInformation
        let sample = Sample(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.altitude,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy,
            speed: location.speed,
            speedAccuracy: location.speedAccuracy,
            course: location.course,
            courseAccuracy: location.courseAccuracy,
            sampledAtEpochMillis: UInt64(max(0, location.timestamp.timeIntervalSince1970 * 1_000)),
            stationary: stationary,
            simulated: sourceInfo?.isSimulatedBySoftware,
            producedByAccessory: sourceInfo?.isProducedByAccessory
        )
        latestSample = sample
        guard !sharingPaused else { return sample }

        let elapsed = lastEmittedAt.map { Date.now.timeIntervalSince($0) } ?? .infinity
        let distance = lastEmittedLocation.map { location.distance(from: $0) } ?? .infinity
        let intervalThreshold = stationary ? minimumEmitInterval * 4 : minimumEmitInterval
        guard elapsed >= intervalThreshold || distance >= minimumDistanceMeters else { return sample }
        lastEmittedAt = .now
        lastEmittedLocation = location
        emit(.init(type: "locationUpdated", sample: sample, status: "fresh", fields: [
            "source": source,
            "appForeground": String(appForeground),
        ]))
        return sample
    }

    private func requestSample(_ command: Command) {
        guard let requestID = command.requestID else {
            emit(.init(type: "commandFailed", error: "requestSample requires requestID"))
            return
        }
        let freshness = TimeInterval(command.desiredFreshnessMillis ?? 15_000) / 1_000
        let deadline = command.deadlineEpochMillis.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) } ?? Date.now.addingTimeInterval(8)
        guard !sharingPaused else {
            emit(.init(type: "sampleResponse", requestID: command.requestID, status: "sharingPaused"))
            return
        }
        if let latestLocation, let latestSample, Date.now.timeIntervalSince(latestLocation.timestamp) <= freshness {
            emit(.init(type: "sampleResponse", requestID: command.requestID, sample: latestSample, status: "fresh", fields: ["source": "cache"]))
            return
        }
        guard deadline > .now else {
            emit(.init(type: "sampleResponse", requestID: command.requestID, sample: latestSample, status: latestSample == nil ? "timeout" : "stale"))
            return
        }

        sampleTasks[requestID]?.cancel()
        let taskToken = UUID()
        sampleTaskTokens[requestID] = taskToken
        sampleTasks[requestID] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.sampleTaskTokens[requestID] == taskToken {
                    self.sampleTasks.removeValue(forKey: requestID)
                    self.sampleTaskTokens.removeValue(forKey: requestID)
                }
            }
            let minimumTimestamp = Date.now.addingTimeInterval(-freshness)
            if let location = await self.awaitOneLocation(until: deadline, minimumTimestamp: minimumTimestamp),
               !Task.isCancelled,
               !self.sharingPaused,
               let sample = self.consume(location, stationary: false, source: "onDemand")
            {
                self.emit(.init(type: "sampleResponse", requestID: requestID, sample: sample, status: "fresh", fields: ["source": "onDemand"]))
            } else if !Task.isCancelled {
                self.emit(.init(
                    type: "sampleResponse",
                    requestID: requestID,
                    sample: self.sharingPaused ? nil : self.latestSample,
                    status: self.sharingPaused ? "sharingPaused" : (self.latestSample == nil ? "timeout" : "stale")
                ))
            }
        }
    }

    private func cancelSampleTasks(status: String) {
        let requestIDs = Array(sampleTasks.keys)
        for task in sampleTasks.values { task.cancel() }
        sampleTasks.removeAll()
        sampleTaskTokens.removeAll()
        for requestID in requestIDs {
            emit(.init(type: "sampleResponse", requestID: requestID, status: status))
        }
    }

    private func awaitOneLocation(until deadline: Date, minimumTimestamp: Date) async -> CLLocation? {
        let seconds = max(0, deadline.timeIntervalSinceNow)
        return await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
                        if let location = update.location,
                           location.timestamp >= minimumTimestamp,
                           location.horizontalAccuracy >= 0,
                           CLLocationCoordinate2DIsValid(location.coordinate)
                        {
                            return location
                        }
                        if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted { return nil }
                    }
                } catch { return nil }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func emitSnapshot(requestID: String?) {
        let age = latestLocation.map { max(0, Date.now.timeIntervalSince($0.timestamp)) }
        emit(.init(type: "capabilitySnapshot", requestID: requestID, sample: latestSample, fields: [
            "authorization": String(describing: CLLocationManager().authorizationStatus),
            "locationServicesEnabled": String(CLLocationManager.locationServicesEnabled()),
            "running": String(isRunning),
            "sharingPaused": String(sharingPaused),
            "backgroundActivitySession": String(backgroundSession != nil),
            "cachedAgeMillis": age.map { String(Int($0 * 1_000)) } ?? "none",
        ]))
    }

    private func observeDiagnostics() {
        if let serviceSession {
            serviceDiagnosticTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await diagnostic in serviceSession.diagnostics {
                        self.reportBlockingDiagnostic(
                            denied: diagnostic.authorizationDenied || diagnostic.alwaysAuthorizationDenied,
                            deniedGlobally: diagnostic.authorizationDeniedGlobally,
                            restricted: diagnostic.authorizationRestricted,
                            source: "serviceSession"
                        )
                        self.emit(.init(type: "serviceDiagnostic", fields: [
                            "authorizationDenied": String(diagnostic.authorizationDenied),
                            "authorizationDeniedGlobally": String(diagnostic.authorizationDeniedGlobally),
                            "authorizationRestricted": String(diagnostic.authorizationRestricted),
                            "insufficientlyInUse": String(diagnostic.insufficientlyInUse),
                            "serviceSessionRequired": String(diagnostic.serviceSessionRequired),
                            "fullAccuracyDenied": String(diagnostic.fullAccuracyDenied),
                            "alwaysAuthorizationDenied": String(diagnostic.alwaysAuthorizationDenied),
                            "authorizationRequestInProgress": String(diagnostic.authorizationRequestInProgress),
                        ]))
                    }
                } catch is CancellationError { return }
                catch { self.emit(.init(type: "serviceDiagnosticFailed", error: String(describing: error))) }
            }
        }
        if let backgroundSession {
            backgroundDiagnosticTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await diagnostic in backgroundSession.diagnostics {
                        self.reportBlockingDiagnostic(
                            denied: diagnostic.authorizationDenied,
                            deniedGlobally: diagnostic.authorizationDeniedGlobally,
                            restricted: diagnostic.authorizationRestricted,
                            source: "backgroundActivitySession"
                        )
                        self.emit(.init(type: "backgroundDiagnostic", fields: [
                            "authorizationDenied": String(diagnostic.authorizationDenied),
                            "authorizationDeniedGlobally": String(diagnostic.authorizationDeniedGlobally),
                            "authorizationRestricted": String(diagnostic.authorizationRestricted),
                            "insufficientlyInUse": String(diagnostic.insufficientlyInUse),
                            "serviceSessionRequired": String(diagnostic.serviceSessionRequired),
                            "authorizationRequestInProgress": String(diagnostic.authorizationRequestInProgress),
                        ]))
                    }
                } catch is CancellationError { return }
                catch { self.emit(.init(type: "backgroundDiagnosticFailed", error: String(describing: error))) }
            }
        }
    }

    private func emitUpdateDiagnostic(_ update: CLLocationUpdate) {
        reportBlockingDiagnostic(
            denied: update.authorizationDenied,
            deniedGlobally: update.authorizationDeniedGlobally,
            restricted: update.authorizationRestricted,
            source: "liveUpdates"
        )
        emit(.init(type: "updateDiagnostic", fields: [
            "authorizationDenied": String(update.authorizationDenied),
            "authorizationDeniedGlobally": String(update.authorizationDeniedGlobally),
            "authorizationRestricted": String(update.authorizationRestricted),
            "insufficientlyInUse": String(update.insufficientlyInUse),
            "locationUnavailable": String(update.locationUnavailable),
            "accuracyLimited": String(update.accuracyLimited),
            "serviceSessionRequired": String(update.serviceSessionRequired),
            "authorizationRequestInProgress": String(update.authorizationRequestInProgress),
        ]))
    }

    private func reportBlockingDiagnostic(
        denied: Bool,
        deniedGlobally: Bool,
        restricted: Bool,
        source: String
    ) {
        guard (denied || deniedGlobally || restricted), !emittedBlockingDiagnostic else { return }
        emittedBlockingDiagnostic = true
        emit(.init(
            type: "locationStreamFailed",
            fields: ["source": source],
            error: "Core Location authorization is denied or restricted"
        ))
    }

    private func emit(_ event: Event) {
        if let data = try? JSONEncoder().encode(event) { eventSink(data) }
    }

    private static func configuration(named name: String?) -> CLLocationUpdate.LiveConfiguration {
        switch name {
        case "automotiveNavigation": .automotiveNavigation
        case "otherNavigation": .otherNavigation
        case "fitness": .fitness
        case "airborne": .airborne
        default: .default
        }
    }
}

// MARK: - Module-private C ABI

public typealias LocationCEventCallback = @convention(c) (UnsafePointer<UInt8>?, Int, UInt) -> Void
private final class LocationCallbackBox: @unchecked Sendable {
    let callback: LocationCEventCallback
    let context: UInt
    init(callback: @escaping LocationCEventCallback, context: UInt) { self.callback = callback; self.context = context }
    @MainActor func send(_ data: Data) { data.withUnsafeBytes { callback($0.bindMemory(to: UInt8.self).baseAddress, data.count, context) } }
}
private final class LocationHandleSource: @unchecked Sendable {
    static let shared = LocationHandleSource()
    private let lock = NSLock()
    private var next: UInt64 = 1
    func allocate() -> UInt64 { lock.withLock { defer { next &+= 1 }; return next } }
}
@MainActor private enum LocationRuntime {
    static var backends: [UInt64: TcLocationAppleBackend] = [:]
}

@_cdecl("tc_location_apple_create")
public func tc_location_apple_create(_ callback: LocationCEventCallback?, _ context: UInt) -> UInt64 {
    guard let callback else { return 0 }
    let handle = LocationHandleSource.shared.allocate()
    let box = LocationCallbackBox(callback: callback, context: context)
    Task { @MainActor in LocationRuntime.backends[handle] = TcLocationAppleBackend(eventSink: box.send) }
    return handle
}

@_cdecl("tc_location_apple_submit")
public func tc_location_apple_submit(_ handle: UInt64, _ bytes: UnsafePointer<UInt8>?, _ length: Int) -> Bool {
    guard length >= 0, length == 0 || bytes != nil else { return false }
    let data = length == 0 ? Data() : Data(bytes: bytes!, count: length)
    Task { @MainActor in LocationRuntime.backends[handle]?.submit(data) }
    return true
}

@_cdecl("tc_location_apple_destroy")
public func tc_location_apple_destroy(_ handle: UInt64) {
    Task { @MainActor in LocationRuntime.backends.removeValue(forKey: handle)?.shutdown() }
}
