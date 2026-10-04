import CryptoKit
import Foundation
import os

private let logger = Logger(subsystem: "QRGuardCore", category: "SecurityDataVerifier")

/// 원격 보안 데이터의 Ed25519 분리 서명을 검증한다 (TASKS T-6.3 수용 기준: 서명 불일치 데이터는 적용하지 않는다).
///
/// 검증 순서: 서명(바이트 그대로) → JSON 디코딩 → 스키마 버전 → 순번(롤백 방지).
/// 어느 단계든 실패하면 `SecurityDataError`를 던지고, 호출자는 데이터를 버려야 한다.
public struct SecurityDataVerifier: Sendable {
    /// 검증을 통과한 묶음과 그 원본 바이트·다이제스트.
    public struct Verified: Sendable, Hashable {
        public let bundle: SecurityDataBundle
        /// 서명이 확인된 바이트. 캐시에 저장할 때 반드시 이 바이트를 그대로 쓴다(재인코딩 금지).
        public let data: Data
        /// 로그·설정 화면용 SHA-256(소문자 16진).
        public let sha256Hex: String
    }

    public let publicKey: Curve25519.Signing.PublicKey

    public init(publicKey: Curve25519.Signing.PublicKey) {
        self.publicKey = publicKey
    }

    /// base64 raw 공개키(32바이트)로 만든다.
    public init(base64PublicKey: String) throws(SecurityDataError) {
        self.publicKey = try Self.publicKey(base64: base64PublicKey)
    }

    /// 번들 리소스 `security_data_pubkey.txt`의 공개키. 리소스가 없거나 깨져 있으면 nil(원격 갱신 비활성).
    public static let bundledPublicKey: Curve25519.Signing.PublicKey? = {
        guard let url = Bundle.module.url(forResource: SecurityDataFiles.publicKeyResourceName, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            logger.error("security_data_pubkey.txt 없음 — 원격 보안 데이터 갱신이 비활성화됩니다")
            return nil
        }
        do {
            return try publicKey(base64: text)
        } catch {
            logger.error("security_data_pubkey.txt 손상 — \(String(describing: error))")
            return nil
        }
    }()

    /// 번들 공개키를 쓰는 검증기. 공개키 리소스가 없으면 nil.
    public static var bundled: SecurityDataVerifier? {
        bundledPublicKey.map(SecurityDataVerifier.init(publicKey:))
    }

    /// `#`으로 시작하는 주석 줄과 공백을 무시하고 base64 raw 키를 읽는다.
    public static func publicKey(base64 text: String) throws(SecurityDataError) -> Curve25519.Signing.PublicKey {
        let body = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .joined()
        guard let raw = Data(base64Encoded: body), raw.count == 32 else {
            throw .malformedPublicKey
        }
        do {
            return try Curve25519.Signing.PublicKey(rawRepresentation: raw)
        } catch {
            throw .malformedPublicKey
        }
    }

    // MARK: 검증

    /// base64 텍스트 서명(`.sig` 파일 내용)으로 검증한다.
    public func verify(data: Data, base64Signature: String, appliedSequence: Int?) throws(SecurityDataError) -> Verified {
        let body = base64Signature.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let signature = Data(base64Encoded: body) else { throw .malformedSignature }
        return try verify(data: data, signature: signature, appliedSequence: appliedSequence)
    }

    /// - Parameters:
    ///   - data: 서명 대상 바이트(JSON 원문). 공백 하나라도 다르면 실패한다.
    ///   - signature: 64바이트 Ed25519 서명
    ///   - appliedSequence: 현재 적용된 순번. 받은 순번이 이 값 이하이면 `notNewer`로 거부(롤백 방지). nil이면 비교하지 않는다.
    public func verify(data: Data, signature: Data, appliedSequence: Int?) throws(SecurityDataError) -> Verified {
        guard signature.count == 64 else { throw .malformedSignature }
        guard publicKey.isValidSignature(signature, for: data) else { throw .invalidSignature }

        let bundle: SecurityDataBundle
        do {
            bundle = try SecurityDataBundle.decode(data)
        } catch {
            throw .malformedJSON(String(describing: error))
        }
        guard bundle.isSchemaSupported else { throw .unsupportedSchemaVersion(bundle.schemaVersion) }
        if let applied = appliedSequence, bundle.sequence <= applied {
            throw .notNewer(received: bundle.sequence, applied: applied)
        }
        return Verified(bundle: bundle, data: data, sha256Hex: Self.sha256Hex(data))
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// 보안 데이터 검증·적용 실패 사유. `rejected(reason)`로 UI·로그에 전달된다.
public enum SecurityDataError: Error, Sendable, Hashable {
    case malformedPublicKey
    case malformedSignature
    case invalidSignature
    case malformedJSON(String)
    case unsupportedSchemaVersion(Int)
    /// 받은 순번이 적용된 순번 이하(동일 포함)
    case notNewer(received: Int, applied: Int)

    /// 로그용 짧은 식별자(사용자 노출 문구는 앱의 String Catalog에서 매핑한다).
    public var code: String {
        switch self {
        case .malformedPublicKey: "malformed_public_key"
        case .malformedSignature: "malformed_signature"
        case .invalidSignature: "invalid_signature"
        case .malformedJSON: "malformed_json"
        case .unsupportedSchemaVersion: "unsupported_schema_version"
        case .notNewer: "not_newer"
        }
    }
}
