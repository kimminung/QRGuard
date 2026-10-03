import Foundation

/// B02 — eTLD+1이 공식 도메인과 **비슷하지만 다름**: Damerau–Levenshtein ≤ 2 또는 UTS #39 confusable skeleton 일치
/// (`naverr.com`, `navеr.com`(키릴 е)) (+35, 근거 `{domain}` `{official}`).
///
/// 보수적 조정: 편집 거리 허용치는 공식 라벨 길이에 따라 4자 이하 → 1, 5자 이상 → 2 (짧은 브랜드명의 오탐 방지).
public struct LookalikeDomainRule: RiskRule {
    public let id: RuleID = .B02
    public let stage: RuleStage = .offline
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool { input.hasWebURL }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        let matcher = BrandMatcher(input.data)
        var candidates: [NormalizedURL] = []
        if let final = input.finalURL { candidates.append(final) }
        if let scanned = input.url, scanned != input.finalURL { candidates.append(scanned) }

        for url in candidates where !url.isIPAddress {
            guard let rd = url.registrableDomain, !matcher.isOfficial(rd) else { continue }
            let label = BrandMatcher.secondLevelLabel(of: rd, psl: input.psl)
            let unicodeRD = Punycode.decodeHost(rd)
            let unicodeLabel = BrandMatcher.secondLevelLabel(of: unicodeRD, psl: input.psl)
            let skeleton = ConfusableSkeleton.skeleton(of: unicodeLabel, confusables: input.data.confusables)

            for brand in input.data.brands {
                for official in brand.domains {
                    let officialRD = official.lowercased()
                    let officialLabel = BrandMatcher.secondLevelLabel(of: officialRD, psl: input.psl)
                    guard officialLabel.count >= 4 else { continue }
                    let allowed = officialLabel.count >= 5 ? 2 : 1

                    // 1) 스켈레톤 일치(혼동 문자·숫자 치환)
                    let officialSkeleton = ConfusableSkeleton.skeleton(of: officialLabel, confusables: input.data.confusables)
                    if skeleton == officialSkeleton, label != officialLabel || rd != officialRD {
                        return finding(domain: unicodeRD, official: officialRD, brand: brand.brand, method: "skeleton")
                    }
                    // 2) 등록 라벨 편집 거리
                    if label.count >= 4, label != officialLabel,
                       DamerauLevenshtein.distance(label, officialLabel) <= allowed {
                        return finding(domain: unicodeRD, official: officialRD, brand: brand.brand, method: "edit_distance")
                    }
                    // 3) eTLD+1 전체 편집 거리(예: naver.co ↔ naver.com)
                    if rd != officialRD, label == officialLabel || DamerauLevenshtein.distance(rd, officialRD) <= 1,
                       DamerauLevenshtein.distance(rd, officialRD) <= allowed {
                        return finding(domain: unicodeRD, official: officialRD, brand: brand.brand, method: "edit_distance")
                    }
                }
            }
        }
        return nil
    }

    private func finding(domain: String, official: String, brand: String, method: String) -> RiskFinding {
        RiskFinding(id: id, points: 35,
                    evidence: ["domain": domain, "official": official, "brand": brand, "method": method],
                    sources: [.S3, .S5])
    }
}
