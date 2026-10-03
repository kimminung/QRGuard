import Foundation

/// P07 — `sms:`/`SMSTO:` 본문에 URL 포함 (+25).
public struct SMSWithLinkRule: RiskRule {
    public let id: RuleID = .P07
    public let stage: RuleStage = .offline
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool {
        if case .sms = input.payload { return true }
        return false
    }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard case .sms(let number, let body) = input.payload, let body, let link = PayloadParser.firstURL(in: body) else { return nil }
        return RiskFinding(id: id, points: 25, evidence: ["number": number, "link": link.absoluteString], sources: [.S5])
    }
}
