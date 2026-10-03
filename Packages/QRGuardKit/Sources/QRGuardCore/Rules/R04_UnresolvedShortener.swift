import Foundation

/// R04 — 단축 URL인데 최종 목적지를 확인하지 못함(시간 초과·오류) (+15).
public struct UnresolvedShortenerRule: RiskRule {
    public let id: RuleID = .R04
    public let stage: RuleStage = .online
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool { input.chain != nil }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard let chain = input.chain, let firstURL = chain.originalURL, let first = input.normalize(firstURL) else { return nil }
        let site = first.registrableDomain ?? first.host
        guard input.data.shorteners.contains(site) || input.data.shorteners.contains(first.host) else { return nil }
        guard chain.outcome != .completed else { return nil }
        return RiskFinding(id: id, points: 15,
                           evidence: ["service": site, "outcome": Self.describe(chain.outcome)],
                           sources: [.S10])
    }

    static func describe(_ outcome: RedirectChain.Outcome) -> String {
        switch outcome {
        case .completed: return "completed"
        case .timedOut: return "timedOut"
        case .tooManyHops: return "tooManyHops"
        case .loopDetected: return "loopDetected"
        case .stoppedAtInsecureHop: return "stoppedAtInsecureHop"
        case .blockedPrivateAddress: return "blockedPrivateAddress"
        case .tlsFailure: return "tlsFailure"
        case .failed(let reason): return "failed:\(reason)"
        }
    }
}
