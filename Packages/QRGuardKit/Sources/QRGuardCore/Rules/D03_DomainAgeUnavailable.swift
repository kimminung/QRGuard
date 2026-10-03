import Foundation

/// D03 — RDAP 조회 불가(예: 일부 ccTLD) (0점 · 정보성). coverage는 파이프라인이 `partial`로 표시한다.
public struct DomainAgeUnavailableRule: RiskRule {
    public let id: RuleID = .D03
    public let stage: RuleStage = .online
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool {
        guard let info = input.domainInfo else { return false }
        return info.lookupFailed || info.registrationDate != nil
    }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard let info = input.domainInfo, info.lookupFailed, info.registrationDate == nil else { return nil }
        return RiskFinding(id: id, points: 0, evidence: ["domain": info.registrableDomain], sources: [])
    }
}
