import Foundation

/// R01 — 리다이렉트 3–5회 (+10), 6회 이상 (+20) (근거 `{count}`).
public struct ManyRedirectsRule: RiskRule {
    public let id: RuleID = .R01
    public let stage: RuleStage = .online
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool { input.chain != nil }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard let chain = input.chain else { return nil }
        let count = chain.redirectCount
        let points: Int
        switch count {
        case 3...5: points = 10
        case 6...: points = 20
        default: return nil
        }
        return RiskFinding(id: id, points: points, evidence: ["count": String(count)], sources: [.S7])
    }
}
