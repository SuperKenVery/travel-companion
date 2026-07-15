import Foundation
@preconcurrency import Security

/// Typed events emitted by the Keychain backend. `Data` appears only where the
/// domain operation genuinely carries credential bytes.
public enum TcSecureStorageEvent: Sendable, Equatable {
    case stored(requestID: String, key: String)
    case loaded(requestID: String, key: String, value: Data?)
    case deleted(requestID: String, key: String)
    case failed(requestID: String?, code: String, message: String)
}

public typealias TcSecureStorageEventSink = @Sendable (TcSecureStorageEvent) -> Void

/// Platform capability values exposed without leaking Security.framework objects.
public struct TcSecureStorageCapabilitySnapshot: Sendable, Equatable {
    public let hardwareBackedWhenAvailable: Bool
    public let deviceOnlyAccessibility: Bool
    public let biometricPolicy: Bool

    public init(
        hardwareBackedWhenAvailable: Bool,
        deviceOnlyAccessibility: Bool,
        biometricPolicy: Bool
    ) {
        self.hardwareBackedWhenAvailable = hardwareBackedWhenAvailable
        self.deviceOnlyAccessibility = deviceOnlyAccessibility
        self.biometricPolicy = biometricPolicy
    }
}

/// Keychain backend for small credentials and keys. Values never leave the Keychain except in
/// direct responses to an explicit `get` operation.
public actor TcSecureStorageAppleBackend {
    public nonisolated static var capabilitySnapshot: TcSecureStorageCapabilitySnapshot {
        TcSecureStorageCapabilitySnapshot(
            hardwareBackedWhenAvailable: false,
            deviceOnlyAccessibility: true,
            biometricPolicy: false
        )
    }

    private let eventSink: TcSecureStorageEventSink
    private let service = "com.travelcompanion.credentials"

    public init(eventSink: @escaping TcSecureStorageEventSink) {
        self.eventSink = eventSink
    }

    public func put(requestID: String, key: String, value: Data) {
        do {
            try validate(requestID: requestID, key: key)
            guard value.count <= 64 * 1_024 else {
                throw KeychainError(
                    status: errSecParam,
                    requestID: requestID,
                    message: "Keychain value exceeds 64 KiB module limit"
                )
            }

            // Keep a uniquely owned mutable buffer scoped to this operation and
            // wipe the same allocation after Security.framework has consumed it.
            // Rust SecretValue also zeroizes its owned command buffer on drop.
            guard let secret = NSMutableData(length: value.count) else {
                throw KeychainError(
                    status: errSecAllocate,
                    requestID: requestID,
                    message: "could not allocate transient credential buffer"
                )
            }
            value.withUnsafeBytes { bytes in
                guard let source = bytes.baseAddress else { return }
                secret.mutableBytes.copyMemory(from: source, byteCount: bytes.count)
            }
            defer {
                secret.mutableBytes.initializeMemory(
                    as: UInt8.self,
                    repeating: 0,
                    count: secret.length
                )
            }

            let query = baseQuery(key: key)
            let attributes: [CFString: Any] = [
                kSecValueData: secret,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var add = query
                attributes.forEach { add[$0.key] = $0.value }
                status = SecItemAdd(add as CFDictionary, nil)
            }
            guard status == errSecSuccess else {
                throw KeychainError(status: status, requestID: requestID)
            }
            eventSink(.stored(requestID: requestID, key: key))
        } catch {
            emitFailure(error, fallbackRequestID: requestID)
        }
    }

    public func get(requestID: String, key: String) {
        do {
            try validate(requestID: requestID, key: key)
            var query = baseQuery(key: key)
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound {
                eventSink(.loaded(requestID: requestID, key: key, value: nil))
                return
            }
            guard status == errSecSuccess, let data = result as? Data else {
                throw KeychainError(status: status, requestID: requestID)
            }
            eventSink(.loaded(requestID: requestID, key: key, value: data))
        } catch {
            emitFailure(error, fallbackRequestID: requestID)
        }
    }

    public func delete(requestID: String, key: String) {
        do {
            try validate(requestID: requestID, key: key)
            let status = SecItemDelete(baseQuery(key: key) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(status: status, requestID: requestID)
            }
            eventSink(.deleted(requestID: requestID, key: key))
        } catch {
            emitFailure(error, fallbackRequestID: requestID)
        }
    }

    public func shutdown() {}

    private func validate(requestID: String, key: String) throws {
        guard !requestID.isEmpty else {
            throw KeychainError(status: errSecParam, requestID: nil, message: "requestID is required")
        }
        guard !key.isEmpty, key.utf8.count <= 512 else {
            throw KeychainError(
                status: errSecParam,
                requestID: requestID,
                message: "key is required and must be <= 512 bytes"
            )
        }
    }

    private func baseQuery(key: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrSynchronizable: false,
            kSecAttrAccount: key,
        ]
    }

    private func emitFailure(_ error: any Error, fallbackRequestID: String) {
        if let error = error as? KeychainError {
            eventSink(.failed(
                requestID: error.requestID ?? fallbackRequestID,
                code: "osStatus:\(error.status)",
                message: error.description
            ))
        } else {
            eventSink(.failed(
                requestID: fallbackRequestID,
                code: "operationFailed",
                message: String(describing: error)
            ))
        }
    }

    private struct KeychainError: Error, CustomStringConvertible {
        var status: OSStatus
        var requestID: String?
        var message: String?
        var description: String {
            message ?? (SecCopyErrorMessageString(status, nil) as String? ?? "Keychain OSStatus \(status)")
        }
    }
}
