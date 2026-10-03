import Foundation

/// T01 — 처음/중간/최종 URL 중 하나라도 위협 DB 적중(Safe Browsing·URLhaus·로컬 블록리스트) (floor 90, 근거 `{provider}`).
/// 로컬 블록리스트는 오프라인에서도 동작하므로 URL이 있으면 항상 평가한다.
public struct ThreatListHitRule: RiskRule {
    public static let localProviderName = "로컬 블록리스트"

    public let id: RuleID = .T01
    public let stage: RuleStage = .online
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool { input.url != nil }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        // 1) 온라인 평판 조회 결과
        if let hit = input.reputation.first(where: { $0.verdict.isMalicious }) {
            var threats: [String] = []
            if case .malicious(let types) = hit.verdict { threats = types }
            return RiskFinding(id: id, points: 0, floor: 90,
                               evidence: ["provider": hit.provider, "url": hit.url.host() ?? hit.url.absoluteString,
                                          "threats": threats.joined(separator: ", ")],
                               sources: [.S8])
        }
        // 2) 로컬 블록리스트(체인 전체)
        var urls = input.snapshot.allURLs
        if let final = input.finalURL?.original, !urls.contains(final) { urls.append(final) }
        for url in urls {
            guard let n = input.normalize(url), let entry = input.data.blocklist.match(url: n) else { continue }
            return RiskFinding(id: id, points: 0, floor: 90,
                               evidence: ["provider": Self.localProviderName, "url": n.unicodeHost, "entry": entry, "threats": "blocklist"],
                               sources: [.S8])
        }
        return nil
    }
}
