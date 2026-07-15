@preconcurrency import CoreLocation
import Foundation

public enum LocationAuthorization: Sendable, Equatable {
    case notDetermined
    case denied
    case whenInUse
    case always
}

public struct LocationSample: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double
    public let altitudeM: Double?
    public let horizontalAccuracyM: Double
    public let speedMps: Double?
    public let courseDegrees: Double?
    public let sampledAtMs: Int64

    public init(
        latitude: Double,
        longitude: Double,
        altitudeM: Double?,
        horizontalAccuracyM: Double,
        speedMps: Double?,
        courseDegrees: Double?,
        sampledAtMs: Int64
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeM = altitudeM
        self.horizontalAccuracyM = horizontalAccuracyM
        self.speedMps = speedMps
        self.courseDegrees = courseDegrees
        self.sampledAtMs = sampledAtMs
    }
}

public enum LocationEvent: Sendable, Equatable {
    case started(requestID: String)
    case stopped(requestID: String)
    case authorizationChanged(status: LocationAuthorization)
    case sample(requestID: String?, sample: LocationSample, fromCache: Bool)
    case timedOut(requestID: String, staleSample: LocationSample?)
    case failed(requestID: String?, code: String, message: String, retryable: Bool)
}

public typealias LocationEventSink = @MainActor @Sendable (LocationEvent) -> Void

/// Platform capability values exposed without leaking Core Location objects.
public struct LocationCapabilitySnapshot: Sendable, Equatable {
    public let preciseLocation: Bool
    public let backgroundUpdates: Bool
    public let serviceSession: Bool
    public let backgroundActivitySession: Bool

    public init(
        preciseLocation: Bool,
        backgroundUpdates: Bool,
        serviceSession: Bool,
        backgroundActivitySession: Bool
    ) {
        self.preciseLocation = preciseLocation
        self.backgroundUpdates = backgroundUpdates
        self.serviceSession = serviceSession
        self.backgroundActivitySession = backgroundActivitySession
    }
}

@MainActor
public final class LocationAppleBackend {
    public nonisolated static var capabilitySnapshot: LocationCapabilitySnapshot {
        LocationCapabilitySnapshot(
            preciseLocation: true,
            backgroundUpdates: true,
            serviceSession: true,
            backgroundActivitySession: true
        )
    }

    private let eventSink: LocationEventSink
    private var serviceSession: CLServiceSession?
    private var backgroundSession: CLBackgroundActivitySession?
    private var updateTask: Task<Void, Never>?
    private var serviceDiagnosticTask: Task<Void, Never>?
    private var backgroundDiagnosticTask: Task<Void, Never>?
    private var sampleTasks: [String: Task<Void, Never>] = [:]
    private var sampleTaskTokens: [String: UUID] = [:]
    private var latestLocation: CLLocation?
    private var latestSample: LocationSample?
    private var lastEmittedLocation: CLLocation?
    private var lastEmittedAt: Date?
    private var isRunning = false
    private var minimumEmitInterval: TimeInterval = 10
    private var minimumDistanceMeters: CLLocationDistance = 10
    private var liveConfiguration: CLLocationUpdate.LiveConfiguration = .default
    private var emittedBlockingDiagnostic = false

    public init(eventSink: @escaping LocationEventSink) {
        self.eventSink = eventSink
    }

    public func shutdown() {
        tearDownSessions()
        isRunning = false
    }

    public func startTravelUpdates(requestID: String, background: Bool) {
        tearDownSessions()
        let authorization = CLLocationManager().authorizationStatus
        guard CLLocationManager.locationServicesEnabled(), authorization != .denied, authorization != .restricted else {
            isRunning = false
            emitFailure(
                requestID: requestID,
                code: "authorizationDenied",
                message: "Location Services are disabled or authorization is denied",
                retryable: false
            )
            return
        }
        minimumEmitInterval = 10
        minimumDistanceMeters = 10
        liveConfiguration = background ? .otherNavigation : .default
        serviceSession = CLServiceSession(authorization: background ? .always : .whenInUse)
        backgroundSession = background ? CLBackgroundActivitySession() : nil
        emittedBlockingDiagnostic = false
        isRunning = true
        observeDiagnostics()
        startLiveUpdates()
        emit(.started(requestID: requestID))
    }

    public func stopTravelUpdates(requestID: String) {
        tearDownSessions()
        isRunning = false
        emit(.stopped(requestID: requestID))
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
                        self.consume(location, stationary: update.stationary)
                    } else {
                        self.emitUpdateDiagnostic(update)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                self.emitFailure(code: "locationStreamFailed", message: String(describing: error), retryable: true)
            }
        }
    }

    @discardableResult
    private func consume(_ location: CLLocation, stationary: Bool) -> LocationSample? {
        guard
            CLLocationCoordinate2DIsValid(location.coordinate),
            location.horizontalAccuracy >= 0,
            latestLocation.map({ location.timestamp >= $0.timestamp }) ?? true
        else { return nil }
        latestLocation = location
        let sample = LocationSample(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitudeM: location.altitude.isFinite ? location.altitude : nil,
            horizontalAccuracyM: location.horizontalAccuracy,
            speedMps: location.speed >= 0 && location.speed.isFinite ? location.speed : nil,
            courseDegrees: location.course >= 0 && location.course.isFinite ? location.course : nil,
            sampledAtMs: Int64(max(0, location.timestamp.timeIntervalSince1970 * 1_000))
        )
        latestSample = sample

        let elapsed = lastEmittedAt.map { Date.now.timeIntervalSince($0) } ?? .infinity
        let distance = lastEmittedLocation.map { location.distance(from: $0) } ?? .infinity
        let intervalThreshold = stationary ? minimumEmitInterval * 4 : minimumEmitInterval
        guard elapsed >= intervalThreshold || distance >= minimumDistanceMeters else { return sample }
        lastEmittedAt = .now
        lastEmittedLocation = location
        emit(.sample(requestID: nil, sample: sample, fromCache: false))
        return sample
    }

    public func requestSample(
        requestID: String,
        desiredFreshnessMs: Int64,
        deadlineMs: Int64
    ) {
        let freshness = TimeInterval(max(0, desiredFreshnessMs)) / 1_000
        let deadlineMillis = deadlineMs
        let deadline = Date(timeIntervalSince1970: TimeInterval(deadlineMillis) / 1_000)
        if let latestLocation, let latestSample, Date.now.timeIntervalSince(latestLocation.timestamp) <= freshness {
            emit(.sample(requestID: requestID, sample: latestSample, fromCache: true))
            return
        }
        guard deadline > .now else {
            emit(.timedOut(requestID: requestID, staleSample: latestSample))
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
               let sample = self.consume(location, stationary: false)
            {
                self.emit(.sample(requestID: requestID, sample: sample, fromCache: false))
            } else if !Task.isCancelled {
                self.emit(.timedOut(requestID: requestID, staleSample: self.latestSample))
            }
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
                    }
                } catch is CancellationError { return }
                catch {
                    self.emitFailure(code: "serviceDiagnosticFailed", message: String(describing: error), retryable: true)
                }
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
                    }
                } catch is CancellationError { return }
                catch {
                    self.emitFailure(code: "backgroundDiagnosticFailed", message: String(describing: error), retryable: true)
                }
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
    }

    private func reportBlockingDiagnostic(
        denied: Bool,
        deniedGlobally: Bool,
        restricted: Bool,
        source: String
    ) {
        guard (denied || deniedGlobally || restricted), !emittedBlockingDiagnostic else { return }
        emittedBlockingDiagnostic = true
        emitFailure(
            code: "authorizationDenied",
            message: "Core Location authorization is denied or restricted (\(source))",
            retryable: false
        )
    }

    private func emitFailure(
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

    private func emit(_ event: LocationEvent) {
        eventSink(event)
    }

}
