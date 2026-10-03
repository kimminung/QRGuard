import Foundation

/// 모든 온라인 검사가 공유하는 세션 설정 (TECH_PRD 6.2).
/// ephemeral · 쿠키 없음 · 캐시 없음 · 모바일 Safari UA(클로킹 회피).
public enum HardenedSession {
    /// 현재 iPhone Safari와 동일한 User-Agent.
    public static let mobileSafariUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

    public static let acceptLanguage = "ko-KR,ko;q=0.9,en-US;q=0.8,en;q=0.7"

    /// 강화 설정을 적용한 ephemeral 구성.
    /// - Parameters:
    ///   - requestTimeout: 요청(홉)당 타임아웃(초)
    ///   - protocolClasses: 테스트용 `URLProtocol` 스텁. nil이면 시스템 기본.
    public static func configuration(
        requestTimeout: TimeInterval = 3,
        protocolClasses: [AnyClass]? = nil
    ) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = max(requestTimeout * 2, 6)
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 2
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.httpAdditionalHeaders = [
            "User-Agent": mobileSafariUserAgent,
            "Accept-Language": acceptLanguage,
        ]
        if let protocolClasses {
            config.protocolClasses = protocolClasses
        }
        return config
    }
}

// MARK: - 타임아웃

/// `withTimeout`이 시간 초과 시 던지는 오류.
public struct TimeoutError: Error, Sendable, Hashable {
    public init() {}
}

/// 작업과 `Task.sleep`을 경쟁시켜 먼저 끝나는 쪽을 택하고 나머지는 취소한다(구조적 동시성).
public func withTimeout<T: Sendable>(
    _ duration: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw TimeoutError() }
        return first
    }
}

// MARK: - 오류 분류

extension URLError {
    /// TLS 인증서 검증 실패 계열 (H05 / `RedirectChain.Outcome.tlsFailure`).
    var isTLSFailure: Bool {
        switch code {
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .secureConnectionFailed, .clientCertificateRejected,
             .clientCertificateRequired:
            return true
        default:
            return false
        }
    }
}

// MARK: - 사설·로컬 주소 판별

/// 사설 IP · 루프백 · 링크 로컬 · localhost · `.local`/`.internal` 호스트 판별 (TECH_PRD 6.2).
/// 로컬 네트워크 기기 노출을 막기 위해 이런 대상에는 요청을 보내지 않는다.
public enum PrivateAddressChecker {
    public static func isPrivateOrLocal(host rawHost: String) -> Bool {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return true }

        // IPv6 (존 식별자 제거)
        if host.contains(":") {
            let bare = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
            return isPrivateIPv6(bare)
        }

        // IPv4 (10진·16진·8진·축약형 포함)
        if let octets = SafeBrowsingCanonicalizer.ipv4Octets(host) {
            return isPrivateIPv4(octets)
        }

        // 호스트 이름
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        for suffix in [".local", ".internal", ".home.arpa", ".lan", ".intranet", ".localdomain"] where host.hasSuffix(suffix) {
            return true
        }
        // 점 없는 단일 라벨(intranet 호스트)은 공개 도메인이 될 수 없다.
        if !host.contains(".") { return true }
        return false
    }

    static func isPrivateIPv4(_ o: [UInt8]) -> Bool {
        guard o.count == 4 else { return true }
        switch o[0] {
        case 0, 10, 127: return true                                  // 현재망·사설 A·루프백
        case 100 where (64...127).contains(o[1]): return true          // CGNAT 100.64/10
        case 169 where o[1] == 254: return true                        // 링크 로컬
        case 172 where (16...31).contains(o[1]): return true           // 사설 B
        case 192 where o[1] == 168: return true                        // 사설 C
        case 192 where o[1] == 0 && (o[2] == 0 || o[2] == 2): return true // IETF·TEST-NET-1
        case 198 where o[1] == 18 || o[1] == 19: return true           // 벤치마크
        case 198 where o[1] == 51 && o[2] == 100: return true          // TEST-NET-2
        case 203 where o[1] == 0 && o[2] == 113: return true           // TEST-NET-3
        case 224...255: return true                                    // 멀티캐스트·예약·브로드캐스트
        default: return false
        }
    }

    static func isPrivateIPv6(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "::" || h == "::1" || h == "0:0:0:0:0:0:0:1" || h == "0:0:0:0:0:0:0:0" { return true }
        // IPv4 매핑 ::ffff:a.b.c.d
        if h.hasPrefix("::ffff:") {
            let tail = String(h.dropFirst(7))
            if let octets = SafeBrowsingCanonicalizer.ipv4Octets(tail) { return isPrivateIPv4(octets) }
            return true
        }
        if h.hasPrefix("fe8") || h.hasPrefix("fe9") || h.hasPrefix("fea") || h.hasPrefix("feb") { return true } // fe80::/10
        if h.hasPrefix("fc") || h.hasPrefix("fd") { return true }                                            // fc00::/7
        if h.hasPrefix("ff") { return true }                                                                 // 멀티캐스트
        return false
    }
}
