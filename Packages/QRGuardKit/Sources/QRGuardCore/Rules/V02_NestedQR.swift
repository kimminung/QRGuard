import Foundation

/// V02 — 중첩 QR: 원본·0.5배·2배 배율, 사분면·중앙 크롭 디코딩 결과 서로 다른 eTLD+1이 2개 이상 (+20, 근거 `{sites}`·`{count}`).
/// C01(한 프레임에 여러 코드)보다 강한 신호. 근거 S11. floor 없음.
public struct NestedQRRule: RiskRule {
    public let id: RuleID = .V02
    public let stage: RuleStage = .offline
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool { input.snapshot.vision != nil }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard let vision = input.snapshot.vision else { return nil }
        // 대소문자·공백만 정리해 중복을 제거한다(호출자가 이미 eTLD+1로 줄여서 넘긴다).
        var seen = Set<String>()
        var sites: [String] = []
        for raw in vision.nestedDistinctSites {
            let site = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !site.isEmpty, !seen.contains(site) else { continue }
            seen.insert(site)
            sites.append(site)
        }
        guard sites.count >= 2 else { return nil }
        return RiskFinding(id: id, points: 20,
                           evidence: ["sites": sites.joined(separator: ", "), "count": String(sites.count)],
                           sources: [.S11])
    }
}
