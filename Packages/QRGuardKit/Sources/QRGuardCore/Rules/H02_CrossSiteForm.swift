import Foundation

/// H02 — `<form action>`이 다른 eTLD+1로 전송 (+20, 근거 `{host}`).
public struct CrossSiteFormRule: RiskRule {
    public let id: RuleID = .H02
    public let stage: RuleStage = .online
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool { input.page != nil }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard let page = input.page, !page.formActionHosts.isEmpty, let site = input.finalSite else { return nil }
        for host in page.formActionHosts {
            let cleaned = host.lowercased().trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty else { continue }
            if input.site(ofHost: cleaned) != site {
                return RiskFinding(id: id, points: 20, evidence: ["host": Punycode.decodeHost(cleaned), "site": site], sources: [.S6])
            }
        }
        return nil
    }
}
