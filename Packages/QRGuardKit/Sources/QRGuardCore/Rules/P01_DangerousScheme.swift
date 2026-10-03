import Foundation

/// P01 — 스킴이 `javascript:` `data:` `file:` `blob:` (floor 95, 열기 차단).
public struct DangerousSchemeRule: RiskRule {
    public static let schemes: Set<String> = ["javascript", "data", "file", "blob", "vbscript"]

    public let id: RuleID = .P01
    public let stage: RuleStage = .offline
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool { input.url != nil }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard let url = input.url, Self.schemes.contains(url.scheme) else { return nil }
        return RiskFinding(id: id, points: 0, floor: 95, blocksOpening: true,
                           evidence: ["scheme": url.scheme], sources: [.general])
    }
}
