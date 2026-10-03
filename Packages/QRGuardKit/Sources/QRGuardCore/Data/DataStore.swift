import Foundation

/// 브랜드 공식 도메인 항목 (`brands.json`).
public struct BrandEntry: Codable, Sendable, Hashable {
    public var brand: String
    /// 호스트 라벨·경로에서 찾을 키워드(소문자)
    public var keywords: [String]
    /// 공식 등록 도메인(eTLD+1)
    public var domains: [String]
    /// 공식 접미사(예: 정부기관 `go.kr`) — eTLD+1이 이 접미사로 끝나면 공식으로 본다
    public var suffixes: [String]

    public init(brand: String, keywords: [String], domains: [String] = [], suffixes: [String] = []) {
        self.brand = brand
        self.keywords = keywords
        self.domains = domains
        self.suffixes = suffixes
    }

    private enum CodingKeys: String, CodingKey { case brand, keywords, domains, suffixes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        brand = try c.decode(String.self, forKey: .brand)
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
        domains = try c.decodeIfPresent([String].self, forKey: .domains) ?? []
        suffixes = try c.decodeIfPresent([String].self, forKey: .suffixes) ?? []
    }

    /// eTLD+1이 이 브랜드의 공식 도메인인지.
    public func isOfficial(registrableDomain rd: String) -> Bool {
        let rd = rd.lowercased()
        if domains.contains(rd) { return true }
        return suffixes.contains { rd == $0 || rd.hasSuffix("." + $0) }
    }
}

/// 알려진 앱 스킴 (`app_schemes.json`).
public struct AppSchemeEntry: Codable, Sendable, Hashable {
    public var scheme: String
    public var app: String
    public init(scheme: String, app: String) {
        self.scheme = scheme
        self.app = app
    }
}

/// 로컬 블록리스트 (`blocklist.json`). eTLD+1·호스트·URL 접두사 세 가지 형태.
public struct Blocklist: Codable, Sendable, Hashable {
    public var domains: [String]
    public var hosts: [String]
    public var urlPrefixes: [String]
    /// 데이터 출처·갱신일 메타
    public var source: String?
    public var updatedAt: String?

    public init(domains: [String] = [], hosts: [String] = [], urlPrefixes: [String] = [], source: String? = nil, updatedAt: String? = nil) {
        self.domains = domains
        self.hosts = hosts
        self.urlPrefixes = urlPrefixes
        self.source = source
        self.updatedAt = updatedAt
    }

    public static let empty = Blocklist()

    /// 적중 시 어떤 항목에 걸렸는지 설명 문자열을 돌려준다.
    public func match(url: NormalizedURL) -> String? {
        // domains 항목은 그 도메인과 모든 하위 호스트에 적용된다(eTLD+1이 아니어도 됨).
        let host = url.host
        if let d = domains.first(where: { $0 == url.registrableDomain || $0 == host || host.hasSuffix("." + $0) }) { return d }
        if hosts.contains(host) { return host }
        let abs = url.normalized.absoluteString.lowercased()
        if let p = urlPrefixes.first(where: { abs.hasPrefix($0.lowercased()) }) { return p }
        return nil
    }
}

/// 번들 데이터 묶음. 로드 실패 시 앱이 죽지 않고 빈 목록 + 로그 (TASKS T-1.4).
public struct DataStore: Sendable {
    public var brands: [BrandEntry]
    /// 단축 URL·동적 QR 서비스 eTLD+1 (소문자)
    public var shorteners: Set<String>
    /// 피싱 집중 TLD (점 없이, 소문자) 예: "xyz", "top"
    public var suspiciousTLDs: Set<String>
    public var appSchemes: [AppSchemeEntry]
    /// 결제·대여 서비스의 공식 eTLD+1 (C03 허용 목록)
    public var paymentMobilityDomains: Set<String>
    public var blocklist: Blocklist
    /// UTS #39 confusables 부분집합: 혼동 문자 → 스켈레톤(기본 라틴) 매핑
    public var confusables: [Character: String]
    /// Public Suffix List 원문(규칙 줄). `PublicSuffixList`가 인덱싱한다.
    public var publicSuffixRules: [String]
    /// 미끼 키워드(U10). 데이터 파일이 없으면 RISK_RULES의 기본 목록.
    public var baitKeywords: [String]

    public init(
        brands: [BrandEntry] = [],
        shorteners: Set<String> = [],
        suspiciousTLDs: Set<String> = [],
        appSchemes: [AppSchemeEntry] = [],
        paymentMobilityDomains: Set<String> = [],
        blocklist: Blocklist = .empty,
        confusables: [Character: String] = [:],
        publicSuffixRules: [String] = [],
        baitKeywords: [String] = DataStore.defaultBaitKeywords
    ) {
        self.brands = brands
        self.shorteners = shorteners
        self.suspiciousTLDs = suspiciousTLDs
        self.appSchemes = appSchemes
        self.paymentMobilityDomains = paymentMobilityDomains
        self.blocklist = blocklist
        self.confusables = confusables
        self.publicSuffixRules = publicSuffixRules
        self.baitKeywords = baitKeywords
    }

    public static let defaultBaitKeywords: [String] = [
        "login", "signin", "verify", "account", "update", "secure", "wallet",
        "인증", "본인확인", "환급", "과태료", "택배", "배송", "대출",
    ]

    /// 번들 리소스에서 로드한 기본 데이터. 첫 접근 시 한 번만 읽는다.
    public static let bundled: DataStore = DataStore.load(from: Bundle.module)

    /// 테스트·미리보기용 빈 데이터(PSL 없음).
    public static let empty = DataStore()

    public func appScheme(for scheme: String) -> AppSchemeEntry? {
        let s = scheme.lowercased()
        return appSchemes.first { $0.scheme.lowercased() == s }
    }

    public func brand(forOfficialDomain rd: String) -> BrandEntry? {
        brands.first { $0.isOfficial(registrableDomain: rd) }
    }
}
