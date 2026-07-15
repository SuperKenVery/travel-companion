import Foundation
@preconcurrency import Security

public typealias TcSecureStorageEventSink = @Sendable (Data) -> Void

/// Keychain backend for small credentials and keys. Values never leave the Keychain except in
/// direct responses to an explicit `get` command.
public actor TcSecureStorageAppleBackend {
    private struct Command: Decodable, Sendable {
        var type: String
        var requestID: String?
        var service: String?
        var accessGroup: String?
        var key: String?
        var dataBase64: String?
        var accessibility: String?
    }

    private struct Event: Encodable, Sendable {
        var type: String
        var requestID: String?
        var key: String?
        var dataBase64: String?
        var keys: [String]?
        var fields: [String: String]?
        var error: String?
        var osStatus: Int32?
    }

    private let eventSink: TcSecureStorageEventSink
    private var service = "com.travelcompanion.credentials"
    private var accessGroup: String?

    public init(eventSink: @escaping TcSecureStorageEventSink) {
        self.eventSink = eventSink
    }

    public func submit(_ json: Data) {
        do {
            let command = try JSONDecoder().decode(Command.self, from: json)
            switch command.type {
            case "configure": configure(command)
            case "set": try set(command)
            case "get": try get(command)
            case "delete": try delete(command)
            case "contains": try contains(command)
            case "listKeys": try listKeys(requestID: command.requestID)
            case "snapshot": snapshot(requestID: command.requestID)
            default: emit(.init(type: "commandFailed", requestID: command.requestID, error: "unknown command: \(command.type)"))
            }
        } catch let error as KeychainError {
            emit(.init(type: "commandFailed", requestID: error.requestID, key: error.key, error: error.description, osStatus: error.status))
        } catch {
            emit(.init(type: "commandFailed", error: String(describing: error)))
        }
    }

    private func configure(_ command: Command) {
        if let service = command.service, !service.isEmpty { self.service = service }
        accessGroup = command.accessGroup?.isEmpty == false ? command.accessGroup : nil
        emit(.init(type: "commandCompleted", requestID: command.requestID, fields: [
            "command": "configure",
            "service": service,
            "accessGroupConfigured": String(accessGroup != nil),
        ]))
    }

    private func set(_ command: Command) throws {
        let key = try requiredKey(command)
        guard let encoded = command.dataBase64, let value = Data(base64Encoded: encoded) else {
            throw KeychainError(status: errSecParam, requestID: command.requestID, key: key, message: "invalid dataBase64")
        }
        guard value.count <= 64 * 1_024 else {
            throw KeychainError(status: errSecParam, requestID: command.requestID, key: key, message: "Keychain value exceeds 64 KiB module limit")
        }

        let query = baseQuery(key: key)
        let attributes: [CFString: Any] = [
            kSecValueData: value,
            kSecAttrAccessible: accessibility(command.accessibility),
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            attributes.forEach { add[$0.key] = $0.value }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status, requestID: command.requestID, key: key) }
        emit(.init(type: "valueStored", requestID: command.requestID, key: key, fields: [
            "byteCount": String(value.count),
            "accessibility": command.accessibility ?? "afterFirstUnlockThisDeviceOnly",
        ]))
    }

    private func get(_ command: Command) throws {
        let key = try requiredKey(command)
        var query = baseQuery(key: key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            emit(.init(type: "valueMissing", requestID: command.requestID, key: key))
            return
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status, requestID: command.requestID, key: key)
        }
        emit(.init(type: "valueLoaded", requestID: command.requestID, key: key, dataBase64: data.base64EncodedString(), fields: ["byteCount": String(data.count)]))
    }

    private func delete(_ command: Command) throws {
        let key = try requiredKey(command)
        let status = SecItemDelete(baseQuery(key: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status, requestID: command.requestID, key: key)
        }
        emit(.init(type: "valueDeleted", requestID: command.requestID, key: key, fields: ["existed": String(status == errSecSuccess)]))
    }

    private func contains(_ command: Command) throws {
        let key = try requiredKey(command)
        var query = baseQuery(key: key)
        query[kSecReturnData] = false
        query[kSecMatchLimit] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status, requestID: command.requestID, key: key)
        }
        emit(.init(type: "containsResult", requestID: command.requestID, key: key, fields: ["contains": String(status == errSecSuccess)]))
    }

    private func listKeys(requestID: String?) throws {
        var query = baseQuery(key: nil)
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            emit(.init(type: "keysListed", requestID: requestID, keys: []))
            return
        }
        guard status == errSecSuccess else { throw KeychainError(status: status, requestID: requestID, key: nil) }
        let rows: [[String: Any]]
        if let values = result as? [[String: Any]] { rows = values }
        else if let value = result as? [String: Any] { rows = [value] }
        else { rows = [] }
        let keys = rows.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
        emit(.init(type: "keysListed", requestID: requestID, keys: keys))
    }

    private func snapshot(requestID: String?) {
        emit(.init(type: "capabilitySnapshot", requestID: requestID, fields: [
            "service": service,
            "accessGroupConfigured": String(accessGroup != nil),
            "defaultAccessibility": "afterFirstUnlockThisDeviceOnly",
            "synchronizable": "false",
            "hardwareBackedKeyOperations": "notClaimed",
        ]))
    }

    private func requiredKey(_ command: Command) throws -> String {
        guard let key = command.key, !key.isEmpty, key.utf8.count <= 512 else {
            throw KeychainError(status: errSecParam, requestID: command.requestID, key: command.key, message: "key is required and must be <= 512 bytes")
        }
        return key
    }

    private func baseQuery(key: String?) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrSynchronizable: false,
        ]
        if let key { query[kSecAttrAccount] = key }
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        return query
    }

    private func accessibility(_ value: String?) -> CFString {
        switch value {
        case "whenUnlockedThisDeviceOnly": kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        case "whenPasscodeSetThisDeviceOnly": kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        default: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }

    private func emit(_ event: Event) {
        if let data = try? JSONEncoder().encode(event) { eventSink(data) }
    }

    private struct KeychainError: Error, CustomStringConvertible {
        var status: OSStatus
        var requestID: String?
        var key: String?
        var message: String?
        var description: String {
            message ?? (SecCopyErrorMessageString(status, nil) as String? ?? "Keychain OSStatus \(status)")
        }
    }
}

// MARK: - Module-private C ABI

public typealias SecureStorageCEventCallback = @convention(c) (UnsafePointer<UInt8>?, Int, UInt) -> Void
private final class SecureStorageCallbackBox: @unchecked Sendable {
    let callback: SecureStorageCEventCallback
    let context: UInt
    init(callback: @escaping SecureStorageCEventCallback, context: UInt) { self.callback = callback; self.context = context }
    func send(_ data: Data) { data.withUnsafeBytes { callback($0.bindMemory(to: UInt8.self).baseAddress, data.count, context) } }
}
private final class SecureStorageHandleSource: @unchecked Sendable {
    static let shared = SecureStorageHandleSource()
    private let lock = NSLock()
    private var next: UInt64 = 1
    func allocate() -> UInt64 { lock.withLock { defer { next &+= 1 }; return next } }
}
private actor SecureStorageRuntime {
    static let shared = SecureStorageRuntime()
    private var backends: [UInt64: TcSecureStorageAppleBackend] = [:]
    func create(handle: UInt64, sink: @escaping TcSecureStorageEventSink) { backends[handle] = TcSecureStorageAppleBackend(eventSink: sink) }
    func submit(handle: UInt64, data: Data) async { await backends[handle]?.submit(data) }
    func destroy(handle: UInt64) { backends.removeValue(forKey: handle) }
}

@_cdecl("tc_secure_storage_apple_create")
public func tc_secure_storage_apple_create(_ callback: SecureStorageCEventCallback?, _ context: UInt) -> UInt64 {
    guard let callback else { return 0 }
    let handle = SecureStorageHandleSource.shared.allocate()
    let box = SecureStorageCallbackBox(callback: callback, context: context)
    Task { await SecureStorageRuntime.shared.create(handle: handle, sink: box.send) }
    return handle
}

@_cdecl("tc_secure_storage_apple_submit")
public func tc_secure_storage_apple_submit(_ handle: UInt64, _ bytes: UnsafePointer<UInt8>?, _ length: Int) -> Bool {
    guard length >= 0, length == 0 || bytes != nil else { return false }
    let data = length == 0 ? Data() : Data(bytes: bytes!, count: length)
    Task { await SecureStorageRuntime.shared.submit(handle: handle, data: data) }
    return true
}

@_cdecl("tc_secure_storage_apple_destroy")
public func tc_secure_storage_apple_destroy(_ handle: UInt64) {
    Task { await SecureStorageRuntime.shared.destroy(handle: handle) }
}
