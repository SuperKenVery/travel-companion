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

    @ObservationIgnored private var handle: OpaquePointer?
    @ObservationIgnored private var capabilityRuntime: AppleCapabilityRuntime?
    @ObservationIgnored private var notificationTask: Task<Void, Never>?

    func bootstrap() async {
        guard !isBootstrapped else { return }
        isProcessing = true
        defer { isProcessing = false }

        do {
            let configuration = try Self.configurationJSON()
            let created = configuration.withCString { tc_core_create($0) }
            guard let created else {
                throw Self.consumeLastCoreError()
            }
            handle = created

            capabilityRuntime = AppleCapabilityRuntime { [weak self] module, event in
                guard let self else { return }
                Task { @MainActor in
                    await self.ingestModuleEvent(module: module, event: event)
                }
            }
            try refreshSnapshot()
            try drainModuleCommands()
            startNotificationObservation()
            isBootstrapped = true
            lastError = nil
        } catch {
            lastError = Self.errorPayload(from: error)
        }
    }

    func send(_ command: CoreCommand) async {
        if !isBootstrapped {
            await bootstrap()
        }
        guard let handle else { return }

        isProcessing = true
        defer { isProcessing = false }

        do {
            let json = try Self.string(from: Self.encoder.encode(command))
            let response = try json.withCString { commandPointer in
                try Self.consume(tc_core_dispatch_json(handle, commandPointer))
            }
            try applyReply(response)
            try drainModuleCommands()
            lastError = nil
        } catch {
            lastError = Self.errorPayload(from: error)
        }
    }

    func refresh() async {
        guard handle != nil else {
            await bootstrap()
            return
        }
        do {
            try refreshSnapshot()
            try drainModuleCommands()
            lastError = nil
        } catch {
            lastError = Self.errorPayload(from: error)
        }
    }

    func shutdown() {
        notificationTask?.cancel()
        notificationTask = nil
        capabilityRuntime?.shutdown()
        capabilityRuntime = nil
        if let handle {
            tc_core_destroy(handle)
            self.handle = nil
        }
        isBootstrapped = false
    }

    private func ingestModuleEvent(module: String, event: Data) async {
        guard let handle else { return }
        do {
            let value = try Self.decoder.decode(JSONValue.self, from: event)
            let envelope = ModuleEventEnvelope(module: module, event: value)
            let json = try Self.string(from: Self.encoder.encode(envelope))
            let response = try json.withCString { eventPointer in
                try Self.consume(tc_core_ingest_module_event_json(handle, eventPointer))
            }
            try applyReply(response)
            try drainModuleCommands()
        } catch {
            lastError = Self.errorPayload(from: error)
        }
    }

    private func refreshSnapshot() throws {
        guard let handle else { throw TravelCoreError.notInitialized }
        let data = try Self.consume(tc_core_snapshot_json(handle))
        snapshot = try Self.decoder.decode(AppSnapshot.self, from: data)
    }

    private func applyReply(_ data: Data) throws {
        let reply = try Self.decoder.decode(CoreReply.self, from: data)
        if let error = reply.error {
            throw TravelCoreError.core(error)
        }
        if let snapshot = reply.snapshot {
            self.snapshot = snapshot
        } else {
            try refreshSnapshot()
        }
    }

    private func drainModuleCommands() throws {
        guard let handle, let capabilityRuntime else { return }
        let data = try Self.consume(tc_core_drain_module_commands_json(handle))
        let commands = try Self.decoder.decode([ModuleCommandEnvelope].self, from: data)
        for command in commands {
            let payload = try Self.encoder.encode(command.command)
            capabilityRuntime.submit(module: command.module, command: payload)
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

    private static func consume(_ pointer: UnsafeMutablePointer<CChar>?) throws -> Data {
        guard let pointer else { throw consumeLastCoreError() }
        defer { tc_core_string_free(pointer) }
        guard let data = String(validatingCString: pointer)?.data(using: .utf8) else {
            throw TravelCoreError.invalidUTF8
        }
        return data
    }

    private static func consumeLastCoreError() -> TravelCoreError {
        guard let pointer = tc_core_last_error_json() else { return .notInitialized }
        defer { tc_core_string_free(pointer) }
        guard
            let data = String(validatingCString: pointer)?.data(using: .utf8),
            let payload = try? decoder.decode(CoreErrorPayload.self, from: data)
        else {
            return .notInitialized
        }
        return .core(payload)
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

private struct ModuleEventEnvelope: Encodable {
    var module: String
    var event: JSONValue
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
