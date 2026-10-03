import Foundation

/// R03 — 체인 중 HTTPS → HTTP 다운그레이드 (+15).
public struct HTTPSDowngradeRule: RiskRule {
    public let id: RuleID = .R03
    public let stage: RuleStage = .online
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool { (input.chain?.hops.count ?? 0) >= 2 }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard let chain = input.chain else { return nil }
        let schemes = chain.hops.map { $0.url.scheme?.lowercased() ?? "" }
        for i in 0..<(schemes.count - 1) where schemes[i] == "https" && schemes[i + 1] == "http" {
            return RiskFinding(id: id, points: 15,
                               evidence: ["hop": String(i + 1), "host": chain.hops[i + 1].url.host() ?? ""],
                               sources: [.S4])
        }
        return nil
    }
}
