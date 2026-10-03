import Foundation

/// C02 — 출처=이메일·문자·메신저 **그리고** (U10 또는 P04 또는 H01) (+15).
/// 장소를 고르지 않았거나 메일·문자가 아니면 평가하지 않는다.
public struct MessageDemandsActionRule: RiskRule {
    public let id: RuleID = .C02
    public let stage: RuleStage = .offline
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool { input.context.place == .emailOrMessage }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard input.context.place == .emailOrMessage else { return nil }
        let triggers: [RuleID] = [.U10, .P04, .H01]
        let hit = triggers.filter { input.hasPrior($0) }
        guard !hit.isEmpty else { return nil }
        return RiskFinding(id: id, points: 15,
                           evidence: ["because": hit.map(\.rawValue).joined(separator: ",")],
                           sources: [.S1, .S4, .S5])
    }
}
