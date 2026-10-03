import Foundation

/// P09 — 송금·결제 페이로드(`bitcoin:`, `ethereum:`, 계좌번호 패턴 등) (floor 40).
public struct PaymentPayloadRule: RiskRule {
    public let id: RuleID = .P09
    public let stage: RuleStage = .offline
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool {
        if case .payment = input.payload { return true }
        return false
    }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard case .payment(let payment) = input.payload else { return nil }
        var evidence = ["scheme": payment.scheme.rawValue, "address": payment.address]
        if let amount = payment.amount { evidence["amount"] = amount }
        return RiskFinding(id: id, points: 0, floor: 40, evidence: evidence, sources: [.S9])
    }
}
