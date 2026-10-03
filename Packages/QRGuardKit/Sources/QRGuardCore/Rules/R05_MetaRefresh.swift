import Foundation

/// R05 — HTML `<meta http-equiv="refresh">` 또는 단순 `location` 할당으로 발견된 이동 (+10).
public struct MetaRefreshRule: RiskRule {
    public let id: RuleID = .R05
    public let stage: RuleStage = .online
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool { input.chain != nil || input.page != nil }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        if let hop = input.chain?.hops.first(where: \.viaMetaRefresh) {
            return RiskFinding(id: id, points: 10, evidence: ["target": hop.url.host() ?? hop.url.absoluteString], sources: [.S7])
        }
        if let target = input.page?.metaRefreshTarget {
            return RiskFinding(id: id, points: 10, evidence: ["target": target.host() ?? target.absoluteString], sources: [.S7])
        }
        return nil
    }
}
