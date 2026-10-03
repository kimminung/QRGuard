import Foundation

/// H05 — TLS 인증서 검증 실패 (+30).
public struct TLSFailureRule: RiskRule {
    public let id: RuleID = .H05
    public let stage: RuleStage = .online
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool {
        input.page != nil || input.chain?.outcome == .tlsFailure
    }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        let failed = (input.page?.tlsFailed ?? false) || input.chain?.outcome == .tlsFailure
        guard failed else { return nil }
        return RiskFinding(id: id, points: 30,
                           evidence: ["host": input.finalURL?.unicodeHost ?? input.url?.unicodeHost ?? ""],
                           sources: [.general])
    }
}
