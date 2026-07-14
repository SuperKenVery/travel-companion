@preconcurrency import CoreLocation
import Foundation
import Observation

@MainActor
@Observable
final class LocationExperimentEngine {
    typealias EventSink = @Sendable (ExperimentRecord) async -> Void

    private let eventSink: EventSink
    private var serviceSession: CLServiceSession?
    private var backgroundSession: CLBackgroundActivitySession?
    private var updateTask: Task<Void, Never>?
    private var serviceDiagnosticTask: Task<Void, Never>?
    private var backgroundDiagnosticTask: Task<Void, Never>?

    private(set) var strategy: LocationExperimentStrategy = .hybrid
    private(set) var isRunning = false
    private(set) var latestSample: LocationSample?
    private(set) var updateCount = 0
    private(set) var diagnosticSummary = "not started"
    var sharingPaused = false

    init(eventSink: @escaping EventSink) {
        self.eventSink = eventSink
    }

    var authorizationDescription: String {
        String(describing: CLLocationManager().authorizationStatus)
    }

    func start(strategy: LocationExperimentStrategy) {
        stop()
        self.strategy = strategy
        isRunning = true
        serviceSession = CLServiceSession(authorization: .always)
        if strategy != .bleOnDemand {
            backgroundSession = CLBackgroundActivitySession()
        }
        observeDiagnostics()
        if strategy != .bleOnDemand {
            startLiveUpdates(configuration: .default)
        }
        log(name: "strategy", phase: "start", outcome: .success, metadata: [
            "strategy": strategy.rawValue,
            "authorization": authorizationDescription,
            "backgroundSession": String(backgroundSession != nil)
        ])
    }

    func stop() {
        updateTask?.cancel()
        updateTask = nil
        serviceDiagnosticTask?.cancel()
        serviceDiagnosticTask = nil
        backgroundDiagnosticTask?.cancel()
        backgroundDiagnosticTask = nil
        serviceSession?.invalidate()
        serviceSession = nil
        backgroundSession?.invalidate()
        backgroundSession = nil
        if isRunning {
            log(name: "strategy", phase: "stop", outcome: .success, metadata: ["strategy": strategy.rawValue])
        }
        isRunning = false
    }

    func sampleForRequest(
        desiredFreshness: TimeInterval,
        deadline: Date
    ) async -> (LocationSample?, LocationResponseStatus) {
        guard !sharingPaused else { return (nil, .sharingPaused) }
        if let latestSample, latestSample.age <= desiredFreshness {
            log(name: "locationRequest", phase: "cached", outcome: .success, metadata: ["sampleAge": String(format: "%.3f", latestSample.age)])
            return (latestSample, .fresh)
        }

        let shouldElevate = strategy == .bleOnDemand || strategy == .hybrid
        if shouldElevate, deadline > .now {
            let start = ContinuousClock.now
            if let fresh = await awaitOneLocation(until: deadline) {
                consume(location: fresh, stationary: false, source: "onDemand")
                log(name: "locationRequest", phase: "freshSample", outcome: .success, latencyMilliseconds: (ContinuousClock.now - start).milliseconds, metadata: ["strategy": strategy.rawValue])
                return (latestSample, .fresh)
            }
            log(name: "locationRequest", phase: "freshSample", outcome: .timeout, latencyMilliseconds: (ContinuousClock.now - start).milliseconds, metadata: ["strategy": strategy.rawValue])
        }

        if let latestSample {
            return (latestSample, .stale)
        }
        return (nil, deadline <= .now ? .timeout : .unavailable)
    }

    private func startLiveUpdates(configuration: CLLocationUpdate.LiveConfiguration) {
        updateTask = Task { [weak self] in
            guard let self else { return }
            do {
                let updates = CLLocationUpdate.liveUpdates(configuration)
                for try await update in updates {
                    if Task.isCancelled { return }
                    if let location = update.location {
                        self.consume(location: location, stationary: update.stationary, source: "adaptive")
                    } else {
                        self.logUpdateDiagnostic(update)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                self.log(name: "liveUpdates", phase: "stream", outcome: .failure, metadata: ["error": String(describing: error)])
            }
        }
    }

    private func awaitOneLocation(until deadline: Date) async -> CLLocation? {
        let remaining = max(0, deadline.timeIntervalSinceNow)
        return await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
                        if let location = update.location { return location }
                        if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted {
                            return nil
                        }
                    }
                } catch { return nil }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(remaining))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func consume(location: CLLocation, stationary: Bool, source: String) {
        let sample = LocationSample(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.altitude,
            horizontalAccuracy: location.horizontalAccuracy,
            speed: location.speed,
            course: location.course,
            sampledAt: location.timestamp,
            stationary: stationary
        )
        latestSample = sample
        updateCount += 1
        log(
            name: "sample",
            phase: "receive",
            outcome: .success,
            metadata: [
                "source": source,
                "strategy": strategy.rawValue,
                "sampleAge": String(format: "%.3f", sample.age),
                "horizontalAccuracy": String(format: "%.2f", sample.horizontalAccuracy),
                "stationary": String(stationary)
            ]
        )
    }

    private func observeDiagnostics() {
        if let serviceSession {
            serviceDiagnosticTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await diagnostic in serviceSession.diagnostics {
                        let fields = Self.serviceDiagnosticFields(diagnostic)
                        self.diagnosticSummary = fields.filter { $0.value == "true" }.keys.sorted().joined(separator: ", ")
                        if self.diagnosticSummary.isEmpty { self.diagnosticSummary = "healthy" }
                        self.log(name: "serviceDiagnostic", phase: "update", outcome: fields.values.contains("true") ? .failure : .success, metadata: fields)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    self.log(name: "serviceDiagnostic", phase: "stream", outcome: .failure, metadata: ["error": String(describing: error)])
                }
            }
        }
        if let backgroundSession {
            backgroundDiagnosticTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await diagnostic in backgroundSession.diagnostics {
                        let fields = Self.backgroundDiagnosticFields(diagnostic)
                        self.log(name: "backgroundDiagnostic", phase: "update", outcome: fields.values.contains("true") ? .failure : .success, metadata: fields)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    self.log(name: "backgroundDiagnostic", phase: "stream", outcome: .failure, metadata: ["error": String(describing: error)])
                }
            }
        }
    }

    private func logUpdateDiagnostic(_ update: CLLocationUpdate) {
        let fields = [
            "authorizationDenied": String(update.authorizationDenied),
            "authorizationDeniedGlobally": String(update.authorizationDeniedGlobally),
            "authorizationRestricted": String(update.authorizationRestricted),
            "insufficientlyInUse": String(update.insufficientlyInUse),
            "locationUnavailable": String(update.locationUnavailable),
            "accuracyLimited": String(update.accuracyLimited),
            "serviceSessionRequired": String(update.serviceSessionRequired),
            "authorizationRequestInProgress": String(update.authorizationRequestInProgress)
        ]
        log(name: "updateDiagnostic", phase: "update", outcome: .failure, metadata: fields)
    }

    private static func serviceDiagnosticFields(_ value: CLServiceSession.Diagnostic) -> [String: String] {
        [
            "authorizationDenied": String(value.authorizationDenied),
            "authorizationDeniedGlobally": String(value.authorizationDeniedGlobally),
            "authorizationRestricted": String(value.authorizationRestricted),
            "insufficientlyInUse": String(value.insufficientlyInUse),
            "serviceSessionRequired": String(value.serviceSessionRequired),
            "fullAccuracyDenied": String(value.fullAccuracyDenied),
            "alwaysAuthorizationDenied": String(value.alwaysAuthorizationDenied),
            "authorizationRequestInProgress": String(value.authorizationRequestInProgress)
        ]
    }

    private static func backgroundDiagnosticFields(_ value: CLBackgroundActivitySession.Diagnostic) -> [String: String] {
        [
            "authorizationDenied": String(value.authorizationDenied),
            "authorizationDeniedGlobally": String(value.authorizationDeniedGlobally),
            "authorizationRestricted": String(value.authorizationRestricted),
            "insufficientlyInUse": String(value.insufficientlyInUse),
            "serviceSessionRequired": String(value.serviceSessionRequired),
            "authorizationRequestInProgress": String(value.authorizationRequestInProgress)
        ]
    }

    private func log(
        name: String,
        phase: String,
        outcome: ExperimentOutcome,
        latencyMilliseconds: Double? = nil,
        metadata: [String: String] = [:]
    ) {
        let record = ExperimentRecord(
            kind: .location,
            name: name,
            phase: phase,
            outcome: outcome,
            latencyMilliseconds: latencyMilliseconds,
            metadata: metadata
        )
        Task { await eventSink(record) }
    }
}
