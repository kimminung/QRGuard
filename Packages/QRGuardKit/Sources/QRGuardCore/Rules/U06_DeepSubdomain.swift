import Foundation

/// U06 — eTLD+1 앞 서브도메인 4단계 이상 또는 호스트 길이 > 50 (+5).
public struct DeepSubdomainRule: RiskRule {
    public let id: RuleID = .U06
    public let stage: RuleStage = .offline
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool { input.hasWebURL }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard let url = input.url, !url.isIPAddress else { return nil }
        let depth = url.subdomainDepth
        let length = url.host.count
        guard depth >= 4 || length > 50 else { return nil }
        return RiskFinding(id: id, points: 5,
                           evidence: ["depth": String(depth), "length": String(length), "host": url.unicodeHost],
                           sources: [.general])
    }
}
