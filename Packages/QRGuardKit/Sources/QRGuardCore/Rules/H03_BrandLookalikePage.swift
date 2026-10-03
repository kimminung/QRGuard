import Foundation

/// H03 — `<title>`·로고 alt·본문 상단에 브랜드명이 있는데 공식 도메인이 아님 (+20, 근거 `{brand}`).
public struct BrandLookalikePageRule: RiskRule {
    public let id: RuleID = .H03
    public let stage: RuleStage = .online
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool { input.page != nil }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard let page = input.page, let final = input.finalURL else { return nil }
        let matcher = BrandMatcher(input.data)
        let text = [page.title ?? "", page.leadingText].joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let (brand, keyword) = matcher.brandMentioned(inText: text) else { return nil }
        let site = final.registrableDomain ?? final.host
        guard !brand.isOfficial(registrableDomain: site) else { return nil }
        return RiskFinding(id: id, points: 20,
                           evidence: ["brand": brand.brand, "keyword": keyword, "host": final.unicodeHost],
                           sources: [.S1, .S3])
    }
}
