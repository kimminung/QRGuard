import Foundation

/// P02 — `itms-services:` 기업용 앱 직접 설치 링크 (floor 95, 열기 차단).
public struct EnterpriseInstallRule: RiskRule {
    public let id: RuleID = .P02
    public let stage: RuleStage = .offline
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool { input.url != nil }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard let url = input.url, url.scheme == "itms-services" else { return nil }
        return RiskFinding(id: id, points: 0, floor: 95, blocksOpening: true,
                           evidence: ["scheme": url.scheme], sources: [.S1, .S2, .S3])
    }
}
