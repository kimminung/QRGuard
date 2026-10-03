import Foundation

/// R02 — 최종 eTLD+1 ≠ 처음 eTLD+1 (처음이 단축 URL이면 제외) (+10, 근거 `{first}` `{final}`).
public struct DestinationMismatchRule: RiskRule {
    public let id: RuleID = .R02
    public let stage: RuleStage = .online
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool { (input.chain?.hops.count ?? 0) >= 2 }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard let chain = input.chain, let firstURL = chain.originalURL, let lastURL = chain.finalURL,
              let first = input.normalize(firstURL), let last = input.normalize(lastURL) else { return nil }
        let firstSite = first.registrableDomain ?? first.host
        let lastSite = last.registrableDomain ?? last.host
        guard firstSite != lastSite else { return nil }
        if input.data.shorteners.contains(firstSite) || input.data.shorteners.contains(first.host) { return nil }
        return RiskFinding(id: id, points: 10,
                           evidence: ["first": first.unicodeHost, "final": last.unicodeHost],
                           sources: [.S7])
    }
}
