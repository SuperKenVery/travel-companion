import Foundation
import Network
import OSLog
@preconcurrency import Security

private let validationTLSLogger = Logger(
    subsystem: "com.ken.TravelCompanionValidation",
    category: "ValidationTLS"
)

struct ValidationTLSConfiguration: @unchecked Sendable {
    let identity: sec_identity_t
    let certificateData: Data

    static func load() throws -> Self {
        #if DEBUG
        guard
            let certificateData = Data(
                base64Encoded: certificateBase64,
                options: .ignoreUnknownCharacters
            ),
            let certificate = SecCertificateCreateWithData(nil, certificateData as CFData),
            let privateKeyData = Data(
                base64Encoded: privateKeyBase64,
                options: .ignoreUnknownCharacters
            )
        else {
            throw ValidationTLSError.invalidEmbeddedIdentity
        }

        let keyAttributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 2_048
        ]
        var keyError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateWithData(
            privateKeyData as CFData,
            keyAttributes as CFDictionary,
            &keyError
        ) else {
            throw keyError?.takeRetainedValue() ?? ValidationTLSError.invalidEmbeddedIdentity
        }
        guard
            let securityIdentity = SecIdentityCreate(nil, certificate, privateKey),
            let protocolIdentity = sec_identity_create(securityIdentity)
        else {
            throw ValidationTLSError.invalidEmbeddedIdentity
        }

        validationTLSLogger.notice("loaded embedded Debug TLS identity")
        return Self(identity: protocolIdentity, certificateData: certificateData)
        #else
        throw ValidationTLSError.debugIdentityUnavailable
        #endif
    }

    func protocolOptions() -> TLS {
        let pinnedCertificate = certificateData
        return TLS {
            TCP()
                .noDelay(true)
                .keepalive(idleTimeInSeconds: 5, count: 3, intervalInSeconds: 2)
        }
        .localIdentity(identity)
        .peerAuthentication(.none)
        .applicationProtocols(["travel-companion-validation/1"])
        .certificateValidator { _, trust in
            let securityTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard
                let certificateChain = SecTrustCopyCertificateChain(securityTrust) as? [SecCertificate],
                let leafCertificate = certificateChain.first
            else {
                validationTLSLogger.error("TLS peer certificate validation failed: no leaf certificate")
                return false
            }
            let matchesPin = SecCertificateCopyData(leafCertificate) as Data == pinnedCertificate
            if matchesPin {
                validationTLSLogger.notice("TLS peer certificate matched Debug pin")
            } else {
                validationTLSLogger.error("TLS peer certificate validation failed: pin mismatch")
            }
            return matchesPin
        }
    }

    #if DEBUG
    private static let certificateBase64 = """
    MIICxDCCAawCCQCnZH5Gq9s06TANBgkqhkiG9w0BAQsFADAkMSIwIAYDVQQDDBlUcmF2ZWxDb21w
    YW5pb25WYWxpZGF0aW9uMB4XDTI2MDcxNDExNTYwNloXDTM2MDcxMTExNTYwNlowJDEiMCAGA1UE
    AwwZVHJhdmVsQ29tcGFuaW9uVmFsaWRhdGlvbjCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoC
    ggEBAKlD/jMNQqm5gqcQeccWGvNAgRPDsnhSpBiOq7b2eZ0XN7xOs9hkTQ6IEAqVnJhur7nsCEGW
    XFW7uy6nifdaHyDP0aoR2aDAqGrdZidYTXjDKrvXFW+GCb5agY+FBOG0JOMnD2nXgAXi3X+ux9Tw
    okAgFzp22beDCo/fqCyTwtNyR0wKsEEAUII7M8BrJimutEe/Wr7mKYjWY8ecP332niHaFuskpgXB
    GnshIW2lANSOeW2nxwscBZhkIIFMH2mmAy2ggVyhAC4cax386saCn/ZiZ1gbgol3ODeIgALFMYY9
    gTzZ6shW9PAA/JidEdfIghhf0rTHzd9M9xXS7xcQXWUCAwEAATANBgkqhkiG9w0BAQsFAAOCAQEA
    hBoWS9Q9I/UQWHhrHJuLwlfSRerTMJLHWT+zWFUoa6RUC88kTqlf/Q1GJ7z0AvUkwjluVn9NtUbk
    mKyiq8IbS72ge6oD6z6fjhKi4gBmgAPjLNfqKUDC/WkyY4/us18uofPn3s6bS7C81V2Il5fg4moB
    4nKib2O7SLStvhOW5LFaGLHw5QB2ZpZnxusZtC0OjkqMjpkMJGMS8d7Tp1oiq++q/yOnOGbWyKPU
    O4h4YaqcY0RdwqDABItqfYA1nkdZGFtxOq1nHWiyrHBlwSwhCqzXHOm71S95NRji9FjSRmLae7RQ
    BttWlFI0b2kQk76LYifc5vPKGItZ2l8ZycmByA==
    """

    private static let privateKeyBase64 = """
    MIIEogIBAAKCAQEAqUP+Mw1CqbmCpxB5xxYa80CBE8OyeFKkGI6rtvZ5nRc3vE6z2GRNDogQCpWc
    mG6vuewIQZZcVbu7LqeJ91ofIM/RqhHZoMCoat1mJ1hNeMMqu9cVb4YJvlqBj4UE4bQk4ycPadeA
    BeLdf67H1PCiQCAXOnbZt4MKj9+oLJPC03JHTAqwQQBQgjszwGsmKa60R79avuYpiNZjx5w/ffae
    IdoW6ySmBcEaeyEhbaUA1I55bafHCxwFmGQggUwfaaYDLaCBXKEALhxrHfzqxoKf9mJnWBuCiXc4
    N4iAAsUxhj2BPNnqyFb08AD8mJ0R18iCGF/StMfN30z3FdLvFxBdZQIDAQABAoIBAGwH/WHQANAa
    mozOMyshrKm8baWTrYCmHh2eUXJA9XWRr/z7rkVaHuQ7ayGWQ4/2dSmQv+Q8d0owu1MXkzLPzjY+
    7W5CXkf/Ln6mN+C8txVwWwHwULoRLn7TfQWAvJDhTPm9oFTJOeiH1x77CoeZ3bRXxvuFh4dcl40k
    Dk4FML+KksOmkmbQzhFFkq+xGbqlopvHY0WRQCD6YkOz5eMVS2yRXh2PWbEBJMRS0O96d0oRTV7e
    X4r0YHS36P0/CL8FHDoiU8FGi/9vn+8kWcwS3nOeTG7lJ8RHquvZkFtwSDF7dIXlo/5zrQ8xy5+/
    2rWSKVvmU7RbqOkykE1rnThh9gECgYEA0i13wFPIC7bRB92o4Lr23PP6W5aiUg/KObD1WUobdueC
    BwboJtArpctCjDOG10kKrdSSoZN7OMh3eDSiOLw9kehZZ75wl9xGXk7NEUQweH0SddF/ZkIt90Xr
    jsjT/CjtUJF8CSjAoE5vST9CQRlfqYfOg/V6kQyqLrl2sH2qOYUCgYEAzisf6XSCAC9/AVRm5g4k
    xlpkRvqzyKwsYuWHh3Epek5EUFUovsKm0527P7M64uOR8unrzqxcc74sXx45AYuQRyrlVcVLxQrX
    ysQ9+DS2HrgHTrGpm5iwi3exlCSEao0m1D6boseRKwUd4yB8857r4D08SWsdXnqtmBvBQycZ6mEC
    gYAQRBSQfettfKiQw0benZmdYARwMig90ZsE+/0A/AtEGIanpJEy78lw+1obH6G/55c7/MecWZ2f
    t2QHmYs0eN0K/cBtlv9/wTxw8AhO3cgiiwtystP5RgXorTCdzE0bps82/Qtsagr+XROfx5WJFD2j
    ES+aZtUlhKVnGFNnNVKHQQKBgFk841g6fNa1uESMEun7L0HH+GWcuFrg42l/LlWazrhIzlrzMWq4
    eFtah6U/3/o7RH4fcFkJ1A6pPy2AuG4Jyc50K8YfWveUBOmYXbZkonvTbh5K2j4mLiyAB5Y25DX2
    mNr/qoAf357+XPxloJAWtsRd3Q1uVs0BTshrIxD9CMOhAoGAbRcUPA0ALXlA8v9ZHUIRSvfu7EYj
    aas1Axxf/EyBSPubp41y6D5SvBNf7YQjSQ7Sh2GE3yRD36Nd8aqn5xKs1T79SOiUs+GWiQeDg5z7
    N4zhlx/w7+MZHjrH7+E1fZO9l23BRbBkUniH2U1QZMbGpGGtH3Rau9G9tHKM+w/3v4w=
    """
    #endif
}

enum ValidationTLSError: LocalizedError {
    case invalidEmbeddedIdentity
    case debugIdentityUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidEmbeddedIdentity:
            "无法读取 Debug TLS 测试 identity"
        case .debugIdentityUnavailable:
            "固定 TLS 测试 identity 仅在 Debug 构建可用"
        }
    }
}
