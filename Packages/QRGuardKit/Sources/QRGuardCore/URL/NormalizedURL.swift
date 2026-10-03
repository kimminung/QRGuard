import Foundation

/// 유니코드 문자 체계(Script) 판별 결과. U05 혼합 문자 체계 탐지에 쓴다.
public enum HostScript: String, Codable, Sendable, Hashable, CaseIterable {
    case latin, cyrillic, greek, hangul, han, kana, arabic, hebrew, thai, devanagari, armenian, georgian, other
}

/// `URLNormalizer.normalize(_:)`의 결과. 원본·정규화·표시용 호스트·eTLD+1·플래그를 모두 갖는다 (TASKS T-1.3).
public struct NormalizedURL: Codable, Sendable, Hashable {
    public var original: URL
    /// 소문자 호스트, 끝 점 제거, 기본 포트 제거, 프래그먼트 분리 후의 URL
    public var normalized: URL
    public var scheme: String
    /// ASCII(퓨니코드) 소문자 호스트. IP 리터럴이면 그 문자열.
    public var host: String
    /// 표시용 유니코드 호스트(퓨니코드 디코딩)
    public var unicodeHost: String
    /// 등록 가능 도메인(eTLD+1). IP·PSL 미해당이면 nil
    public var registrableDomain: String?
    /// 호스트 라벨(점으로 분리, ASCII)
    public var hostLabels: [String]
    public var isIPAddress: Bool
    /// `@` 앞의 userinfo. 있으면 U03
    public var userInfo: String?
    /// 명시된 포트(기본 포트 80/443은 nil로 정규화)
    public var port: Int?
    public var path: String
    public var query: String?
    public var fragment: String?
    public var queryItems: [URLQueryItem]
    /// 퍼센트 인코딩된 문자 비율(0...1)
    public var percentEncodedRatio: Double
    /// `%25xx` 같은 이중 인코딩 감지
    public var hasDoubleEncoding: Bool
    /// `xn--` 라벨 포함
    public var isIDN: Bool
    /// 호스트에 등장한 문자 체계 집합
    public var scripts: Set<HostScript>
    /// 라틴 + 다른 체계처럼 섞인 경우
    public var hasMixedScript: Bool
    /// 전체 URL 길이(문자 수)
    public var length: Int

    public init(
        original: URL,
        normalized: URL,
        scheme: String,
        host: String,
        unicodeHost: String,
        registrableDomain: String?,
        hostLabels: [String],
        isIPAddress: Bool,
        userInfo: String?,
        port: Int?,
        path: String,
        query: String?,
        fragment: String?,
        queryItems: [URLQueryItem],
        percentEncodedRatio: Double,
        hasDoubleEncoding: Bool,
        isIDN: Bool,
        scripts: Set<HostScript>,
        hasMixedScript: Bool,
        length: Int
    ) {
        self.original = original
        self.normalized = normalized
        self.scheme = scheme
        self.host = host
        self.unicodeHost = unicodeHost
        self.registrableDomain = registrableDomain
        self.hostLabels = hostLabels
        self.isIPAddress = isIPAddress
        self.userInfo = userInfo
        self.port = port
        self.path = path
        self.query = query
        self.fragment = fragment
        self.queryItems = queryItems
        self.percentEncodedRatio = percentEncodedRatio
        self.hasDoubleEncoding = hasDoubleEncoding
        self.isIDN = isIDN
        self.scripts = scripts
        self.hasMixedScript = hasMixedScript
        self.length = length
    }

    public var isHTTPS: Bool { scheme == "https" }
    public var isHTTP: Bool { scheme == "http" }
    public var isWeb: Bool { isHTTP || isHTTPS }
    /// 경로의 마지막 구성요소 확장자(소문자, 점 제외). 없으면 nil
    public var pathExtension: String? {
        let last = path.split(separator: "/").last.map(String.init) ?? ""
        guard let dot = last.lastIndex(of: "."), dot != last.startIndex else { return nil }
        let ext = last[last.index(after: dot)...].lowercased()
        return ext.isEmpty ? nil : ext
    }
    /// eTLD+1 앞 서브도메인 라벨 수
    public var subdomainDepth: Int {
        guard let registrableDomain else { return 0 }
        let rdCount = registrableDomain.split(separator: ".").count
        return max(0, hostLabels.count - rdCount)
    }
}

// URLQueryItem은 Codable이 아니므로 직접 구현한다.
extension NormalizedURL {
    private enum CodingKeys: String, CodingKey {
        case original, normalized, scheme, host, unicodeHost, registrableDomain, hostLabels, isIPAddress
        case userInfo, port, path, query, fragment, queryItems, percentEncodedRatio, hasDoubleEncoding
        case isIDN, scripts, hasMixedScript, length
    }

    private struct QueryItemBox: Codable {
        var name: String
        var value: String?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        original = try c.decode(URL.self, forKey: .original)
        normalized = try c.decode(URL.self, forKey: .normalized)
        scheme = try c.decode(String.self, forKey: .scheme)
        host = try c.decode(String.self, forKey: .host)
        unicodeHost = try c.decode(String.self, forKey: .unicodeHost)
        registrableDomain = try c.decodeIfPresent(String.self, forKey: .registrableDomain)
        hostLabels = try c.decode([String].self, forKey: .hostLabels)
        isIPAddress = try c.decode(Bool.self, forKey: .isIPAddress)
        userInfo = try c.decodeIfPresent(String.self, forKey: .userInfo)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        path = try c.decode(String.self, forKey: .path)
        query = try c.decodeIfPresent(String.self, forKey: .query)
        fragment = try c.decodeIfPresent(String.self, forKey: .fragment)
        queryItems = try c.decode([QueryItemBox].self, forKey: .queryItems).map { URLQueryItem(name: $0.name, value: $0.value) }
        percentEncodedRatio = try c.decode(Double.self, forKey: .percentEncodedRatio)
        hasDoubleEncoding = try c.decode(Bool.self, forKey: .hasDoubleEncoding)
        isIDN = try c.decode(Bool.self, forKey: .isIDN)
        scripts = try c.decode(Set<HostScript>.self, forKey: .scripts)
        hasMixedScript = try c.decode(Bool.self, forKey: .hasMixedScript)
        length = try c.decode(Int.self, forKey: .length)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(original, forKey: .original)
        try c.encode(normalized, forKey: .normalized)
        try c.encode(scheme, forKey: .scheme)
        try c.encode(host, forKey: .host)
        try c.encode(unicodeHost, forKey: .unicodeHost)
        try c.encodeIfPresent(registrableDomain, forKey: .registrableDomain)
        try c.encode(hostLabels, forKey: .hostLabels)
        try c.encode(isIPAddress, forKey: .isIPAddress)
        try c.encodeIfPresent(userInfo, forKey: .userInfo)
        try c.encodeIfPresent(port, forKey: .port)
        try c.encode(path, forKey: .path)
        try c.encodeIfPresent(query, forKey: .query)
        try c.encodeIfPresent(fragment, forKey: .fragment)
        try c.encode(queryItems.map { QueryItemBox(name: $0.name, value: $0.value) }, forKey: .queryItems)
        try c.encode(percentEncodedRatio, forKey: .percentEncodedRatio)
        try c.encode(hasDoubleEncoding, forKey: .hasDoubleEncoding)
        try c.encode(isIDN, forKey: .isIDN)
        try c.encode(scripts, forKey: .scripts)
        try c.encode(hasMixedScript, forKey: .hasMixedScript)
        try c.encode(length, forKey: .length)
    }
}
