import Foundation

/// B03 — 최종 eTLD+1이 공식 도메인 목록에 있고, HTTPS이며, 리다이렉트가 공식 도메인 밖으로 나가지 않음 (−20, 통과 항목).
/// T01·U09와 함께 발생하면 `RiskScorer`가 제외한다.
public struct OfficialDomainRule: RiskRule {
    public let id: RuleID = .B03
    public let stage: RuleStage = .offline
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool { input.hasWebURL }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard let final = input.finalURL, final.isHTTPS, !final.isIPAddress, let rd = final.registrableDomain else { return nil }
        let matcher = BrandMatcher(input.data)
        let brands = matcher.officialBrands(for: rd)
        guard let brand = brands.first else { return nil }

        // 체인의 모든 홉이 같은 브랜드의 공식 도메인이어야 한다.
        if let chain = input.chain {
            for hop in chain.hops {
                guard let n = input.normalize(hop.url), n.isHTTPS, let hopRD = n.registrableDomain,
                      matcher.sameBrand(hopRD, rd) else { return nil }
            }
        } else if let scanned = input.url, scanned.registrableDomain != rd {
            // 체인 없이 스캔 URL과 최종 URL이 다르면 같은 브랜드여야 한다.
            guard matcher.sameBrand(scanned.registrableDomain, rd), scanned.isHTTPS else { return nil }
        }
        return RiskFinding(id: id, points: -20, evidence: ["brand": brand.brand, "domain": rd], sources: [])
    }
}
