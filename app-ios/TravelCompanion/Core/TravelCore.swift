import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class TravelCore {
    private(set) var snapshot: AppSnapshot = .empty
    private(set) var isBootstrapped = false
    private(set) var isProcessing = false
    private(set) var lastError: CoreErrorPayload?

    @ObservationIgnored private var binding: TravelCoreBinding?
    @ObservationIgnored private var capabilityRuntime: AppleCapabilityRuntime?
    @ObservationIgnored private var coreListener: AppleCoreEventListener?
    @ObservationIgnored private var notificationTask: Task<Void, Never>?

    func bootstrap() async {
        guard !isBootstrapped else { return }
        isProcessing = true
        defer { isProcessing = false }

        do {
            let configuration = try Self.configurationJSON()
            let runtime = AppleCapabilityRuntime()
            let listener = AppleCoreEventListener { [weak self] replyJSON in
                guard let self, self.binding != nil else { return }
                do {
                    try self.applyReply(replyJSON)
                    self.lastError = nil
                } catch {
                    self.lastError = Self.errorPayload(from: error)
                }
            }
            let created = try TravelCoreBinding(
                configJson: configuration,
                bluetooth: runtime.bluetooth,
                peerTransport: runtime.peerTransport,
                location: runtime.location,
                ranging: runtime.ranging,
                notifications: runtime.notifications,
                callSystem: runtime.callSystem,
                secureStorage: runtime.secureStorage,
                listener: listener
            )
            binding = created
            capabilityRuntime = runtime
            coreListener = listener
            try refreshSnapshot()
            startNotificationObservation()
            isBootstrapped = true
            lastError = nil
        } catch {
            notificationTask?.cancel()
            notificationTask = nil
            try? binding?.shutdown()
            binding = nil
            capabilityRuntime = nil
            coreListener = nil
            lastError = Self.errorPayload(from: error)
        }
    }

    func send(_ command: CoreCommand) async {
        if !isBootstrapped {
            await bootstrap()
        }
        guard let binding else { return }

        isProcessing = true
        defer { isProcessing = false }

        do {
            let json = try Self.string(from: Self.encoder.encode(command))
            let response = binding.dispatchJson(commandJson: json)
            try applyReply(response)
            lastError = nil
        } catch {
            lastError = Self.errorPayload(from: error)
        }
    }

    func refresh() async {
        guard binding != nil else {
            await bootstrap()
            return
        }
        do {
            try refreshSnapshot()
            lastError = nil
        } catch {
            lastError = Self.errorPayload(from: error)
        }
    }

    func shutdown() {
        notificationTask?.cancel()
        notificationTask = nil
        try? binding?.shutdown()
        binding = nil
        capabilityRuntime = nil
        coreListener = nil
        isBootstrapped = false
    }

    private func refreshSnapshot() throws {
        guard let binding else { throw TravelCoreError.notInitialized }
        let data = Data(binding.snapshotJson().utf8)
        snapshot = try Self.decoder.decode(AppSnapshot.self, from: data)
    }

    private func applyReply(_ json: String) throws {
        let data = Data(json.utf8)
        let reply = try Self.decoder.decode(CoreReply.self, from: data)
        if let error = reply.error {
            throw TravelCoreError.core(error)
        }
        if let snapshot = reply.snapshot {
            // Foreign callbacks can originate on different framework queues.
            // Never let a delayed callback roll the UI back to an older core revision.
            if snapshot.revision >= self.snapshot.revision {
                self.snapshot = snapshot
            }
        } else {
            try refreshSnapshot()
        }
    }

    private func startNotificationObservation() {
        notificationTask?.cancel()
        notificationTask = Task { [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: .travelCompanionNotificationResponse
            )
            for await notification in notifications {
                guard !Task.isCancelled, let self else { return }
                let values = notification.userInfo?.reduce(into: [String: String]()) { result, pair in
                    result[String(describing: pair.key)] = String(describing: pair.value)
                } ?? [:]
                capabilityRuntime?.handleNotificationResponse(values)
            }
        }
    }

    private static func configurationJSON() throws -> String {
        let fileManager = FileManager.default
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = applicationSupport.appending(path: "TravelCompanion", directoryHint: .isDirectory)
        let resources = root.appending(path: "Resources", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)

        let configuration = CoreConfiguration(
            storagePath: root.appending(path: "travel-companion.sqlite").path(),
            resourcesPath: resources.path(),
            displayName: UIDevice.current.name
        )
        return try string(from: encoder.encode(configuration))
    }

    private static func string(from data: Data) throws -> String {
        guard let string = String(data: data, encoding: .utf8) else {
            throw TravelCoreError.invalidUTF8
        }
        return string
    }

    private static func errorPayload(from error: Error) -> CoreErrorPayload {
        if case TravelCoreError.core(let payload) = error { return payload }
        return CoreErrorPayload(code: "swiftBridge", message: error.localizedDescription)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1_000 : seconds)
            }
            let value = try container.decode(String.self)
            if let date = try? Date(value, strategy: .iso8601) { return date }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(value)")
        }
        return decoder
    }()
}

private struct CoreConfiguration: Encodable {
    var storagePath: String
    var resourcesPath: String
    var displayName: String
}

private enum TravelCoreError: LocalizedError {
    case notInitialized
    case invalidUTF8
    case core(CoreErrorPayload)

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            "无法初始化本地旅行核心"
        case .invalidUTF8:
            "核心返回了无效数据"
        case .core(let payload):
            payload.message
        }
    }
}

private final class AppleCoreEventListener: CoreEventListener, @unchecked Sendable {
    typealias Handler = @MainActor @Sendable (String) -> Void

    private let handler: Handler
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func onUpdate(replyJson: String) {
        lock.lock()
        let previous = tail
        let handler = handler
        let next = Task.detached {
            await previous?.value
            await MainActor.run { handler(replyJson) }
        }
        tail = next
        lock.unlock()
    }
}
