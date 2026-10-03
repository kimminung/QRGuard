import Foundation

/// U02 — 호스트가 IP 주소(IPv4/IPv6) (+20, 근거 `{ip}`).
public struct IPAddressHostRule: RiskRule {
    public let id: RuleID = .U02
    public let stage: RuleStage = .offline
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool { input.hasWebURL }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard let url = input.url, url.isIPAddress else { return nil }
        let ip = IPAddressParser.canonicalIPv4(url.host) ?? url.host
        return RiskFinding(id: id, points: 20, evidence: ["ip": ip], sources: [.general])
    }
}
