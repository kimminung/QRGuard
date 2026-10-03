import Foundation
import QRGuardCore

/// 리다이렉트 추적기 (TECH_PRD 6.2). 쿠키·캐시 없이 한 홉씩 직접 따라간다.
public protocol RedirectResolving: Sendable {
    func resolve(_ url: URL, maxHops: Int, perHopTimeout: Duration, totalTimeout: Duration) async -> RedirectChain
}

/// 평판 제공자(Google Safe Browsing v5, URLhaus, 로컬 블록리스트 등).
public protocol ReputationProvider: Sendable {
    var name: String { get }
    /// 키 없음·설정 꺼짐 등으로 조회할 수 없으면 false. 이때는 어떤 요청도 보내지 않는다.
    var isAvailable: Bool { get }
    func lookup(_ urls: [URL]) async throws -> [URL: ReputationVerdict]
}

/// 도메인 등록일 조회(RDAP).
public protocol DomainInfoProviding: Sendable {
    func registrationDate(for registrableDomain: String) async throws -> Date?
}

/// 페이지 사전 검사(HTML 앞부분 256KB, 정적 파싱).
public protocol PagePrechecking: Sendable {
    func precheck(_ url: URL, timeout: Duration) async throws -> PagePrecheckResult
}
