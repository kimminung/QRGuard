import Foundation

/// U01 — `http://` (HTTPS 아님) (+15). 스캔한 URL만 본다(체인 중 다운그레이드는 R03).
public struct InsecureHTTPRule: RiskRule {
    public let id: RuleID = .U01
    public let stage: RuleStage = .offline
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool { input.hasWebURL }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard let url = input.url, url.isHTTP else { return nil }
        return RiskFinding(id: id, points: 15, evidence: ["host": url.unicodeHost], sources: [.S4, .S5])
    }
}
