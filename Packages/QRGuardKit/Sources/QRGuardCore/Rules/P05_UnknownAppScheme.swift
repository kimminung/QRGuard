import Foundation

/// P05 — 알 수 없는 앱 스킴(`foo://`) (+20). P01·P02가 다루는 스킴은 제외한다.
public struct UnknownAppSchemeRule: RiskRule {
    public let id: RuleID = .P05
    public let stage: RuleStage = .offline
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool {
        guard case .appScheme = input.payload, let url = input.url else { return false }
        return !DangerousSchemeRule.schemes.contains(url.scheme) && url.scheme != "itms-services"
    }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard isApplicable(input), let url = input.url, input.data.appScheme(for: url.scheme) == nil else { return nil }
        return RiskFinding(id: id, points: 20, evidence: ["scheme": url.scheme], sources: [.S2])
    }
}
