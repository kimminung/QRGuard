import Foundation

/// B01 — 호스트 라벨 또는 경로(앞 두 구성요소)에 브랜드 키워드가 있지만 eTLD+1이 그 브랜드의 공식 도메인이 아님 (+30, 근거 `{brand}`).
/// 스캔한 URL과 최종 URL을 모두 보고 한 번만 발동한다(최종 URL 우선).
public struct BrandKeywordMismatchRule: RiskRule {
    public let id: RuleID = .B01
    public let stage: RuleStage = .offline
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool { input.hasWebURL }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        let matcher = BrandMatcher(input.data)
        var candidates: [NormalizedURL] = []
        if let final = input.finalURL { candidates.append(final) }
        if let scanned = input.url, scanned != input.finalURL { candidates.append(scanned) }

        for url in candidates where !url.isIPAddress || !url.path.isEmpty {
            let site = url.registrableDomain ?? url.host
            // 어떤 브랜드든 공식 도메인이면 사칭이 아니다(예: kakaomobility.com 의 'kakao').
            if matcher.isOfficial(site) { continue }
            // 호스트 라벨(IP는 제외)
            if !url.isIPAddress, let (brand, keyword) = matcher.brandMentioned(in: url.hostLabels),
               !brand.isOfficial(registrableDomain: site) {
                return finding(brand: brand, keyword: keyword, host: url.unicodeHost, location: "host")
            }
            // 경로 앞 두 구성요소(토큰 일치만)
            let decodedPath = url.path.removingPercentEncoding ?? url.path
            let components = decodedPath.split(separator: "/").prefix(2).map(String.init)
            if let (brand, keyword) = matcher.brandMentioned(in: components, allowSubstring: false),
               !brand.isOfficial(registrableDomain: site) {
                return finding(brand: brand, keyword: keyword, host: url.unicodeHost, location: "path")
            }
        }
        return nil
    }

    private func finding(brand: BrandEntry, keyword: String, host: String, location: String) -> RiskFinding {
        RiskFinding(id: id, points: 30,
                    evidence: ["brand": brand.brand, "keyword": keyword, "host": host, "where": location],
                    sources: [.S1, .S3])
    }
}
