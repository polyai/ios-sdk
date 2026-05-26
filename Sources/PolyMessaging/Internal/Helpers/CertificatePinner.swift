// Copyright PolyAI Limited

// FUTURE: TLS certificate pinning — disabled for now, may be revived.
//
// To re-enable:
//   1. Remove this `#if false` ... `#endif` wrapper.
//   2. Re-enable the `CertificatePinning` enum in Configuration.swift
//      (also wrapped in `#if false`) and add the property + init param.
//   3. Wire it into `PolyMessagingClient.init` (build the URLSession via
//      `URLSession.poly_pinned(...)` for RestApi, pass `pinning:` to
//      `WebSocketTransport`).
//   4. Add the `didReceive challenge:` delegate method back to
//      `WebSocketSessionDelegate` in WebSocketTransport.swift.
//   5. Re-enable tests in Tests/PolyMessagingTests/Helpers/CertificatePinnerTests.swift.
#if false
import Foundation
import CryptoKit
import Security

/// Validates incoming TLS server-trust challenges against a pinned set of
/// hashes. Sits on the URLSession delegate path for both REST and WebSocket.
///
/// Modes:
/// - `.none` → falls through to OS default validation.
/// - `.spki` / `.certificate` → runs OS chain validation first, then matches
///   the leaf cert's SPKI or DER hash against the pinned set. Mismatch
///   cancels the challenge, dropping the connection.
struct CertificatePinner: Sendable {
    let mode: CertificatePinning
    let logger: PolyLogger

    func handle(
        challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Server-trust is the only auth method we pin. Client-cert / basic
        // / digest challenges flow through unmodified.
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        if case .none = mode {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Always require OS chain validation to pass first. Pinning augments
        // the OS trust store; it doesn't replace it. A self-signed cert with
        // a matching pin still fails here, which is intended.
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            logger.warn("Certificate pinning: OS chain validation failed", metadata: nil)
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        guard let leaf = leafCertificate(from: trust) else {
            logger.warn("Certificate pinning: leaf cert not retrievable", metadata: nil)
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        switch mode {
        case .none:
            completionHandler(.performDefaultHandling, nil)

        case .spki(let pinned):
            guard let hash = SPKIHasher.sha256OfSPKI(of: leaf) else {
                logger.warn("Certificate pinning: failed to compute SPKI hash (unsupported key type)", metadata: nil)
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            if pinned.contains(hash) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                logger.warn("Certificate pinning: SPKI hash mismatch", metadata: nil)
                completionHandler(.cancelAuthenticationChallenge, nil)
            }

        case .certificate(let pinned):
            let der = SecCertificateCopyData(leaf) as Data
            let hash = Data(SHA256.hash(data: der))
            if pinned.contains(hash) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                logger.warn("Certificate pinning: leaf certificate hash mismatch", metadata: nil)
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }

    private func leafCertificate(from trust: SecTrust) -> SecCertificate? {
        // SecTrustCopyCertificateChain returns the chain leaf-first. iOS 15+.
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else {
            return nil
        }
        return chain.first
    }
}

/// Computes SHA-256 of a certificate's SubjectPublicKeyInfo (SPKI).
///
/// `SecKeyCopyExternalRepresentation` returns the raw key bytes — not the
/// full SPKI structure. To match the hash an operator computes server-side
/// with `openssl x509 -pubkey ...`, we prepend the appropriate ASN.1 header
/// for the key type before hashing.
///
/// Supports the four common key types in production today:
/// - RSA 2048-bit
/// - RSA 4096-bit
/// - EC secp256r1 (P-256)
/// - EC secp384r1 (P-384)
///
/// Other key types (RSA 3072, EC P-521, Ed25519) return nil — the caller
/// treats this as a pin failure rather than silently skipping the check.
enum SPKIHasher {

    static func sha256OfSPKI(of certificate: SecCertificate) -> Data? {
        guard let publicKey = SecCertificateCopyKey(certificate),
              let keyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            return nil
        }

        guard let attributes = SecKeyCopyAttributes(publicKey) as? [String: Any],
              let keyType = attributes[kSecAttrKeyType as String] as? String,
              let keySize = attributes[kSecAttrKeySizeInBits as String] as? Int,
              let header = asn1Header(keyType: keyType, keySize: keySize) else {
            return nil
        }

        var spki = Data(capacity: header.count + keyData.count)
        spki.append(contentsOf: header)
        spki.append(keyData)

        return Data(SHA256.hash(data: spki))
    }

    private static func asn1Header(keyType: String, keySize: Int) -> [UInt8]? {
        let rsa = kSecAttrKeyTypeRSA as String
        let ec = kSecAttrKeyTypeECSECPrimeRandom as String

        switch (keyType, keySize) {
        case (rsa, 2048): return rsa2048Header
        case (rsa, 4096): return rsa4096Header
        case (ec, 256):   return ecP256Header
        case (ec, 384):   return ecP384Header
        default:          return nil
        }
    }

    private static let rsa2048Header: [UInt8] = [
        0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
        0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00,
    ]

    private static let rsa4096Header: [UInt8] = [
        0x30, 0x82, 0x02, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
        0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x02, 0x0f, 0x00,
    ]

    private static let ecP256Header: [UInt8] = [
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02,
        0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
        0x42, 0x00,
    ]

    private static let ecP384Header: [UInt8] = [
        0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02,
        0x01, 0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00,
    ]
}

/// URLSessionDelegate that funnels server-trust challenges through a pinner.
/// Used by RestApi's URLSession. (WebSocket transport has its own delegate
/// because URLSessionWebSocketDelegate also handles open/close callbacks.)
final class PinningURLSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let pinner: CertificatePinner

    init(pinner: CertificatePinner) {
        self.pinner = pinner
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        pinner.handle(challenge: challenge, completionHandler: completionHandler)
    }
}

extension URLSession {
    /// Returns `.shared` for `.none`, otherwise a fresh session with a
    /// pinning delegate. URLSession retains its delegate, so the caller
    /// doesn't need to hold a reference.
    static func poly_pinned(pinning: CertificatePinning, logger: PolyLogger) -> URLSession {
        if case .none = pinning {
            return .shared
        }
        let pinner = CertificatePinner(mode: pinning, logger: logger)
        let delegate = PinningURLSessionDelegate(pinner: pinner)
        return URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    }
}
#endif

