import Foundation

/// U11 — 단축 URL·동적 QR 서비스 도메인(`shorteners.json`) (+10, 근거 `{service}`).
public struct URLShortenerRule: RiskRule {
    public let id: RuleID = .U11
    public let stage: RuleStage = .offline
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool { input.hasWebURL }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard let url = input.url, let rd = url.registrableDomain else { return nil }
        let shorteners = input.data.shorteners
        guard shorteners.contains(rd) || shorteners.contains(url.host) else { return nil }
        return RiskFinding(id: id, points: 10, evidence: ["service": rd], sources: [.S10])
    }
}
