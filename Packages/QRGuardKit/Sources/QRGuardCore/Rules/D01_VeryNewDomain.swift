import Foundation

/// D01 — 등록일로부터 30일 미만 (+25, 근거 `{days}`).
public struct VeryNewDomainRule: RiskRule {
    public let id: RuleID = .D01
    public let stage: RuleStage = .online
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool { input.domainInfo?.registrationDate != nil }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard let info = input.domainInfo, let days = info.ageInDays(asOf: input.now), days < 30 else { return nil }
        return RiskFinding(id: id, points: 25,
                           evidence: ["days": String(max(0, days)), "domain": info.registrableDomain],
                           sources: [.S8])
    }
}
