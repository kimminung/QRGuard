import Foundation

/// U10 — 호스트/경로에 미끼 키워드(`login, verify, 인증, 택배 …`, `bait_keywords.json`) — 1회만 (+10, 근거 `{keyword}`).
public struct BaitKeywordRule: RiskRule {
    public let id: RuleID = .U10
    public let stage: RuleStage = .offline
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool { input.hasWebURL }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard let url = input.url else { return nil }
        // 공식 도메인(예: `tossbank.com`)의 호스트에 든 키워드는 미끼가 아니므로 경로만 본다.
        let hostIsOfficial = BrandMatcher(input.data).isOfficial(url.registrableDomain)
        let hostText = hostIsOfficial ? "" : url.unicodeHost.lowercased()
        let pathText = (url.path.removingPercentEncoding ?? url.path).lowercased()
        let haystacks = [hostText, pathText]
        for keyword in input.data.baitKeywords {
            let kw = keyword.lowercased()
            guard !kw.isEmpty else { continue }
            for (index, text) in haystacks.enumerated() where text.contains(kw) {
                return RiskFinding(id: id, points: 10,
                                   evidence: ["keyword": kw, "where": index == 0 ? "host" : "path"],
                                   sources: [.S3, .S5])
            }
        }
        return nil
    }
}
