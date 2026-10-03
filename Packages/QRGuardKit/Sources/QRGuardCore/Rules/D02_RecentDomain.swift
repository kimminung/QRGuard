import Foundation

/// D02 — 등록일로부터 30–180일 (+10, 근거 `{days}`).
public struct RecentDomainRule: RiskRule {
    public let id: RuleID = .D02
    public let stage: RuleStage = .online
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool { input.domainInfo?.registrationDate != nil }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard let info = input.domainInfo, let days = info.ageInDays(asOf: input.now), (30...180).contains(days) else { return nil }
        return RiskFinding(id: id, points: 10,
                           evidence: ["days": String(days), "domain": info.registrableDomain],
                           sources: [.S8])
    }
}
