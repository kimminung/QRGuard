import Foundation

/// 원격으로 배포되는 보안 데이터 묶음 (TASKS T-6.3).
///
/// `security-data.json` 한 파일에 번들 데이터 파일(brands · shorteners · suspicious_tlds · app_schemes ·
/// payment_mobility · blocklist · bait_keywords)을 모두 담는다. 각 항목은 선택이며, 없는 항목은
/// 번들 데이터를 그대로 쓴다. 서명은 같은 바이트에 대한 분리 서명 `security-data.json.sig`(base64 Ed25519).
///
/// `confusables`·`publicSuffixRules`는 원격 갱신 대상이 아니다(알고리즘과 함께 바뀌어야 하므로 앱 업데이트로만).
public struct SecurityDataBundle: Codable, Sendable, Hashable {
    /// 이 빌드가 이해하는 스키마 버전. 범위 밖이면 `SecurityDataVerifier`가 거부한다.
    public static let supportedSchemaVersions: ClosedRange<Int> = 1...1
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// 발행 시각(ISO 8601 문자열). 파싱된 값은 `publishedDate`.
    public var publishedAt: String
    /// 단조 증가하는 발행 순번. 적용된 순번 이하는 롤백으로 보고 거부한다.
    public var sequence: Int

    public var brands: [BrandEntry]?
    public var shorteners: [String]?
    public var suspiciousTLDs: [String]?
    public var appSchemes: [AppSchemeEntry]?
    public var paymentMobility: [String]?
    public var blocklist: Blocklist?
    public var baitKeywords: [String]?

    public init(
        schemaVersion: Int = SecurityDataBundle.currentSchemaVersion,
        publishedAt: String,
        sequence: Int,
        brands: [BrandEntry]? = nil,
        shorteners: [String]? = nil,
        suspiciousTLDs: [String]? = nil,
        appSchemes: [AppSchemeEntry]? = nil,
        paymentMobility: [String]? = nil,
        blocklist: Blocklist? = nil,
        baitKeywords: [String]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.publishedAt = publishedAt
        self.sequence = sequence
        self.brands = brands
        self.shorteners = shorteners
        self.suspiciousTLDs = suspiciousTLDs
        self.appSchemes = appSchemes
        self.paymentMobility = paymentMobility
        self.blocklist = blocklist
        self.baitKeywords = baitKeywords
    }

    /// `publishedAt`을 Date로 (소수점 초 유무 모두 허용). 형식이 틀리면 nil.
    public var publishedDate: Date? {
        let text = publishedAt.trimmingCharacters(in: .whitespacesAndNewlines)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    public var isSchemaSupported: Bool {
        Self.supportedSchemaVersions.contains(schemaVersion)
    }

    /// 묶음에 들어 있는 항목 이름(로그·설정 화면용). 예: `["brands", "blocklist"]`
    public var includedFields: [String] {
        var names: [String] = []
        if brands != nil { names.append("brands") }
        if shorteners != nil { names.append("shorteners") }
        if suspiciousTLDs != nil { names.append("suspiciousTLDs") }
        if appSchemes != nil { names.append("appSchemes") }
        if paymentMobility != nil { names.append("paymentMobility") }
        if blocklist != nil { names.append("blocklist") }
        if baitKeywords != nil { names.append("baitKeywords") }
        return names
    }

    /// 서명 검증 전후로 똑같은 바이트를 디코딩해야 하므로 디코더 설정을 한 곳에 둔다.
    public static func decode(_ data: Data) throws -> SecurityDataBundle {
        try JSONDecoder().decode(SecurityDataBundle.self, from: data)
    }
}

// MARK: - 캐시 파일 이름

/// 검증된 원격 데이터를 디스크에 보관할 때 쓰는 파일 이름. Core(로드)와 Network(갱신)가 같은 이름을 써야 한다.
public enum SecurityDataFiles {
    /// 검증을 통과한 JSON 원본 바이트
    public static let dataFileName = "security-data.json"
    /// 그 바이트의 분리 서명(base64 텍스트)
    public static let signatureFileName = "security-data.json.sig"
    /// 마지막 확인 시각·적용 순번 등 갱신기 상태
    public static let stateFileName = "security-data-state.json"
    /// 번들에 포함된 Ed25519 공개키 리소스(`Resources/security_data_pubkey.txt`)
    public static let publicKeyResourceName = "security_data_pubkey"

    /// 기본 캐시 위치: `Application Support/SecurityData/`. 백업 대상이지만 재검증하므로 무해하다.
    public static var defaultCacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SecurityData", isDirectory: true)
    }

    public static func dataURL(in directory: URL) -> URL { directory.appendingPathComponent(dataFileName, isDirectory: false) }
    public static func signatureURL(in directory: URL) -> URL { directory.appendingPathComponent(signatureFileName, isDirectory: false) }
    public static func stateURL(in directory: URL) -> URL { directory.appendingPathComponent(stateFileName, isDirectory: false) }
}
