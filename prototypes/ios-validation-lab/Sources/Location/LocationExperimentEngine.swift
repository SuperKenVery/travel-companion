@preconcurrency import CoreLocation
import Foundation
import Observation

enum LocationLiveConfigurationOption: String, CaseIterable, Identifiable, Sendable {
    case defaultActivity
    case automotiveNavigation
    case otherNavigation
    case fitness
    case airborne

    var id: String { rawValue }

    var title: String {
        switch self {
        case .defaultActivity: "Default"
        case .automotiveNavigation: "Automotive Navigation"
        case .otherNavigation: "Other Navigation"
        case .fitness: "Fitness"
        case .airborne: "Airborne"
        }
    }

    var detail: String {
        switch self {
        case .defaultActivity: "不属于其他活动类型的通用定位"
        case .automotiveNavigation: "沿道路网络行驶的汽车导航"
        case .otherNavigation: "骑行、火车、船舶和越野交通"
        case .fitness: "专门的健身活动"
        case .airborne: "空中活动"
        }
    }

    fileprivate var liveConfiguration: CLLocationUpdate.LiveConfiguration {
        switch self {
        case .defaultActivity: .default
        case .automotiveNavigation: .automotiveNavigation
        case .otherNavigation: .otherNavigation
        case .fitness: .fitness
        case .airborne: .airborne
        }
    }
}

struct LocationFrequencyUpdate: Identifiable, Sendable, Hashable {
    let id: UUID
    let sequence: Int
    let configuration: LocationLiveConfigurationOption
    let receivedAt: Date
    let locationTimestamp: Date?
    let intervalSincePrevious: TimeInterval?
    let deliveryDelay: TimeInterval?
    let appWasForeground: Bool
    let stationary: Bool
    let latitude: Double?
    let longitude: Double?
    let altitude: Double?
    let horizontalAccuracy: Double?
    let verticalAccuracy: Double?
    let speed: Double?
    let speedAccuracy: Double?
    let course: Double?
    let courseAccuracy: Double?
    let floorLevel: Int?
    let isSimulatedBySoftware: Bool?
    let isProducedByAccessory: Bool?
    let authorizationDenied: Bool
    let authorizationDeniedGlobally: Bool
    let authorizationRestricted: Bool
    let insufficientlyInUse: Bool
    let locationUnavailable: Bool
    let accuracyLimited: Bool
    let serviceSessionRequired: Bool
    let authorizationRequestInProgress: Bool

    var hasLocation: Bool { latitude != nil && longitude != nil }
}

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
    private(set) var isFrequencyTestRunning = false
    private(set) var frequencyConfiguration: LocationLiveConfigurationOption = .defaultActivity
    private(set) var frequencyTestStartedAt: Date?
    private(set) var frequencyUpdates: [LocationFrequencyUpdate] = []
    private(set) var discardedFrequencyUpdateCount = 0
    private(set) var frequencyIntervalTotal: TimeInterval = 0
    private(set) var frequencyIntervalCount = 0
    private(set) var backgroundFrequencyUpdateCount = 0
    var sharingPaused = false
    private var appIsForeground = true

    private static let maximumFrequencyUpdates = 20_000

    init(eventSink: @escaping EventSink) {
        self.eventSink = eventSink
    }

    var authorizationDescription: String {
        String(describing: CLLocationManager().authorizationStatus)
    }

    var averageFrequencyInterval: TimeInterval? {
        guard frequencyIntervalCount > 0 else { return nil }
        return frequencyIntervalTotal / Double(frequencyIntervalCount)
    }

    var estimatedFrequencyHertz: Double? {
        guard let averageFrequencyInterval, averageFrequencyInterval > 0 else { return nil }
        return 1 / averageFrequencyInterval
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
        if isFrequencyTestRunning {
            log(name: "frequencyTest", phase: "stop", outcome: .success, metadata: [
                "configuration": frequencyConfiguration.rawValue,
                "callbackCount": String(frequencyUpdates.count),
                "discardedCallbackCount": String(discardedFrequencyUpdateCount)
            ])
        }
        isRunning = false
        isFrequencyTestRunning = false
    }

    func setAppForeground(_ foreground: Bool) {
        appIsForeground = foreground
    }

    func startFrequencyTest(configuration: LocationLiveConfigurationOption) {
        stop()
        frequencyConfiguration = configuration
        frequencyTestStartedAt = .now
        frequencyUpdates = []
        discardedFrequencyUpdateCount = 0
        frequencyIntervalTotal = 0
        frequencyIntervalCount = 0
        backgroundFrequencyUpdateCount = 0
        updateCount = 0
        latestSample = nil
        isFrequencyTestRunning = true
        serviceSession = CLServiceSession(authorization: .always)
        backgroundSession = CLBackgroundActivitySession()
        observeDiagnostics()
        startFrequencyUpdates(configuration: configuration)
        log(name: "frequencyTest", phase: "start", outcome: .success, metadata: [
            "configuration": configuration.rawValue,
            "authorization": authorizationDescription,
            "backgroundSession": String(backgroundSession != nil)
        ])
    }

    func clearFrequencyUpdates() {
        frequencyUpdates = []
        discardedFrequencyUpdateCount = 0
        frequencyIntervalTotal = 0
        frequencyIntervalCount = 0
        backgroundFrequencyUpdateCount = 0
        updateCount = 0
        latestSample = nil
        frequencyTestStartedAt = nil
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

    private func startFrequencyUpdates(configuration: LocationLiveConfigurationOption) {
        updateTask = Task { [weak self] in
            guard let self else { return }
            do {
                let updates = CLLocationUpdate.liveUpdates(configuration.liveConfiguration)
                for try await update in updates {
                    if Task.isCancelled { return }
                    self.consumeFrequencyUpdate(update)
                }
            } catch is CancellationError {
                return
            } catch {
                self.log(name: "frequencyTest", phase: "stream", outcome: .failure, metadata: [
                    "configuration": configuration.rawValue,
                    "error": String(describing: error)
                ])
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

    private func consumeFrequencyUpdate(_ update: CLLocationUpdate) {
        let receivedAt = Date.now
        let previousReceivedAt = frequencyUpdates.last?.receivedAt
        let location = update.location
        let sourceInformation = location?.sourceInformation
        let event = LocationFrequencyUpdate(
            id: UUID(),
            sequence: updateCount + 1,
            configuration: frequencyConfiguration,
            receivedAt: receivedAt,
            locationTimestamp: location?.timestamp,
            intervalSincePrevious: previousReceivedAt.map { receivedAt.timeIntervalSince($0) },
            deliveryDelay: location.map { receivedAt.timeIntervalSince($0.timestamp) },
            appWasForeground: appIsForeground,
            stationary: update.stationary,
            latitude: location?.coordinate.latitude,
            longitude: location?.coordinate.longitude,
            altitude: location?.altitude,
            horizontalAccuracy: location?.horizontalAccuracy,
            verticalAccuracy: location?.verticalAccuracy,
            speed: location?.speed,
            speedAccuracy: location?.speedAccuracy,
            course: location?.course,
            courseAccuracy: location?.courseAccuracy,
            floorLevel: location?.floor?.level,
            isSimulatedBySoftware: sourceInformation?.isSimulatedBySoftware,
            isProducedByAccessory: sourceInformation?.isProducedByAccessory,
            authorizationDenied: update.authorizationDenied,
            authorizationDeniedGlobally: update.authorizationDeniedGlobally,
            authorizationRestricted: update.authorizationRestricted,
            insufficientlyInUse: update.insufficientlyInUse,
            locationUnavailable: update.locationUnavailable,
            accuracyLimited: update.accuracyLimited,
            serviceSessionRequired: update.serviceSessionRequired,
            authorizationRequestInProgress: update.authorizationRequestInProgress
        )

        if frequencyUpdates.count == Self.maximumFrequencyUpdates {
            frequencyUpdates.removeFirst()
            discardedFrequencyUpdateCount += 1
        }
        frequencyUpdates.append(event)
        updateCount += 1
        if let interval = event.intervalSincePrevious {
            frequencyIntervalTotal += interval
            frequencyIntervalCount += 1
        }
        if !event.appWasForeground {
            backgroundFrequencyUpdateCount += 1
        }

        if let location {
            latestSample = LocationSample(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                altitude: location.altitude,
                horizontalAccuracy: location.horizontalAccuracy,
                speed: location.speed,
                course: location.course,
                sampledAt: location.timestamp,
                stationary: update.stationary
            )
        }

        var metadata = frequencyMetadata(for: event)
        metadata["configuration"] = frequencyConfiguration.rawValue
        log(
            name: "frequencyUpdate",
            phase: event.hasLocation ? "location" : "diagnostic",
            outcome: event.hasLocation ? .success : .info,
            metadata: metadata
        )
    }

    private func frequencyMetadata(for event: LocationFrequencyUpdate) -> [String: String] {
        var fields: [String: String] = [
            "sequence": String(event.sequence),
            "receivedAt": event.receivedAt.ISO8601Format(),
            "appWasForeground": String(event.appWasForeground),
            "stationary": String(event.stationary),
            "authorizationDenied": String(event.authorizationDenied),
            "authorizationDeniedGlobally": String(event.authorizationDeniedGlobally),
            "authorizationRestricted": String(event.authorizationRestricted),
            "insufficientlyInUse": String(event.insufficientlyInUse),
            "locationUnavailable": String(event.locationUnavailable),
            "accuracyLimited": String(event.accuracyLimited),
            "serviceSessionRequired": String(event.serviceSessionRequired),
            "authorizationRequestInProgress": String(event.authorizationRequestInProgress)
        ]
        func add(_ key: String, _ value: CustomStringConvertible?) {
            if let value { fields[key] = String(describing: value) }
        }
        add("locationTimestamp", event.locationTimestamp?.ISO8601Format())
        add("intervalSincePrevious", event.intervalSincePrevious)
        add("deliveryDelay", event.deliveryDelay)
        add("latitude", event.latitude)
        add("longitude", event.longitude)
        add("altitude", event.altitude)
        add("horizontalAccuracy", event.horizontalAccuracy)
        add("verticalAccuracy", event.verticalAccuracy)
        add("speed", event.speed)
        add("speedAccuracy", event.speedAccuracy)
        add("course", event.course)
        add("courseAccuracy", event.courseAccuracy)
        add("floorLevel", event.floorLevel)
        add("isSimulatedBySoftware", event.isSimulatedBySoftware)
        add("isProducedByAccessory", event.isProducedByAccessory)
        return fields
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
