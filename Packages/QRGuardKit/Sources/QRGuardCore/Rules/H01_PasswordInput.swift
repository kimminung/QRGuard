import Foundation

/// H01 — `<input type="password">` 존재 (B03 통과 도메인 제외) (+15).
public struct PasswordInputRule: RiskRule {
    public let id: RuleID = .H01
    public let stage: RuleStage = .online
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool { input.page != nil }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard let page = input.page, page.hasPasswordInput, !input.hasPrior(.B03) else { return nil }
        return RiskFinding(id: id, points: 15,
                           evidence: ["host": input.finalURL?.unicodeHost ?? ""],
                           sources: [.S6, .S1])
    }
}
