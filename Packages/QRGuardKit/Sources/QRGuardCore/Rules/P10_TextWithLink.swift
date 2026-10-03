import Foundation

/// P10 — 일반 텍스트 안에 URL 포함 (정보성, 0점). 추출된 첫 URL은 `primaryURL`로 전체 URL 규칙이 다시 평가한다.
public struct TextWithLinkRule: RiskRule {
    public let id: RuleID = .P10
    public let stage: RuleStage = .offline
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool {
        if case .text = input.payload { return true }
        return false
    }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard case .text(_, let urls) = input.payload, let first = urls.first else { return nil }
        return RiskFinding(id: id, points: 0, evidence: ["count": String(urls.count), "link": first.absoluteString], sources: [])
    }
}
