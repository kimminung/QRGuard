import Foundation

/// U05 — IDN(퓨니코드 `xn--`) + 혼합 문자 체계(예: 라틴+키릴) (+15).
public struct MixedScriptIDNRule: RiskRule {
    public let id: RuleID = .U05
    public let stage: RuleStage = .offline
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool { input.hasWebURL }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard let url = input.url, url.isIDN, url.hasMixedScript else { return nil }
        let scripts = url.scripts.map(\.rawValue).sorted().joined(separator: ",")
        return RiskFinding(id: id, points: 15,
                           evidence: ["host": url.unicodeHost, "punycode": url.host, "scripts": scripts],
                           sources: [.S3, .S7])
    }
}
