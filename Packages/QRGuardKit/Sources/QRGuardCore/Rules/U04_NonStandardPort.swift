import Foundation

/// U04 — 비표준 포트(80/443 외) (+10, 근거 `{port}`).
public struct NonStandardPortRule: RiskRule {
    public let id: RuleID = .U04
    public let stage: RuleStage = .offline
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool { input.hasWebURL }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard let url = input.url, let port = url.port, port != 80, port != 443 else { return nil }
        return RiskFinding(id: id, points: 10, evidence: ["port": String(port)], sources: [.general])
    }
}
