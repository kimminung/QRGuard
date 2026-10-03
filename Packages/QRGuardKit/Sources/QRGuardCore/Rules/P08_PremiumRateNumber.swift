import Foundation

/// P08 — 수신 번호가 국내 유료 정보서비스 번호(`060` 시작) (+30).
public struct PremiumRateNumberRule: RiskRule {
    public let id: RuleID = .P08
    public let stage: RuleStage = .offline
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool {
        switch input.payload {
        case .sms, .phone: return true
        default: return false
        }
    }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        let number: String
        switch input.payload {
        case .sms(let n, _): number = n
        case .phone(let n): number = n
        default: return nil
        }
        guard PhoneNumberHeuristics.isPremiumRate060(number) else { return nil }
        return RiskFinding(id: id, points: 30, evidence: ["number": number], sources: [.general])
    }
}
