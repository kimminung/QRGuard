import Foundation

/// P05a — 알려진 앱 스킴(`kakaotalk:`, `supertoss:` 등, `app_schemes.json`) (+5, 근거 `{app}`).
public struct KnownAppSchemeRule: RiskRule {
    public let id: RuleID = .P05a
    public let stage: RuleStage = .offline
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool {
        guard case .appScheme = input.payload, let url = input.url else { return false }
        return !DangerousSchemeRule.schemes.contains(url.scheme) && url.scheme != "itms-services"
    }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard isApplicable(input), let url = input.url, let entry = input.data.appScheme(for: url.scheme) else { return nil }
        return RiskFinding(id: id, points: 5, evidence: ["app": entry.app, "scheme": url.scheme], sources: [])
    }
}
