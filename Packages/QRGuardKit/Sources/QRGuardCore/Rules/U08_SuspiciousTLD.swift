import Foundation

/// U08 — 피싱 집중 TLD(`suspicious_tlds.json`) (+10, 근거 `{tld}`).
public struct SuspiciousTLDRule: RiskRule {
    public let id: RuleID = .U08
    public let stage: RuleStage = .offline
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool { input.hasWebURL }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard let url = input.url, !url.isIPAddress, !url.hostLabels.isEmpty else { return nil }
        let suffix = input.psl.publicSuffix(forHost: url.host) ?? url.hostLabels.last ?? ""
        let lastLabel = suffix.split(separator: ".").last.map(String.init) ?? suffix
        let tlds = input.data.suspiciousTLDs
        guard tlds.contains(suffix) || tlds.contains(lastLabel) else { return nil }
        return RiskFinding(id: id, points: 10, evidence: ["tld": "." + (tlds.contains(suffix) ? suffix : lastLabel)], sources: [.general])
    }
}
