import Foundation

/// U03 — authority에 `@`(userinfo) 포함: `https://naver.com@evil.example` (+25, 근거 `{hidden_host}`).
public struct UserInfoAtRule: RiskRule {
    public let id: RuleID = .U03
    public let stage: RuleStage = .offline
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool { input.hasWebURL }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard let url = input.url, let userInfo = url.userInfo, !userInfo.isEmpty else { return nil }
        return RiskFinding(id: id, points: 25,
                           evidence: ["hidden_host": url.unicodeHost, "userinfo": userInfo],
                           sources: [.S3])
    }
}
