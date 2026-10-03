import Foundation

/// C01 — 한 프레임/사진에서 서로 다른 내용의 QR 2개 이상 감지 (+20, 근거 `{count}`).
public struct MultipleCodesRule: RiskRule {
    public let id: RuleID = .C01
    public let stage: RuleStage = .offline
    public init() {}

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        let count = input.context.distinctCodesInFrame
        guard count >= 2 else { return nil }
        return RiskFinding(id: id, points: 20, evidence: ["count": String(count)], sources: [.S2, .S5, .S6])
    }
}
