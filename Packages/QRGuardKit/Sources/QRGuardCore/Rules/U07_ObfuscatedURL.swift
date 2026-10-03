import Foundation

/// U07 — URL 길이 > 200 또는 퍼센트 인코딩 비율 > 15% 또는 이중 인코딩 (+5).
public struct ObfuscatedURLRule: RiskRule {
    public let id: RuleID = .U07
    public let stage: RuleStage = .offline
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool { input.hasWebURL }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard let url = input.url else { return nil }
        var reasons: [String] = []
        if url.length > 200 { reasons.append("length") }
        if url.percentEncodedRatio > 0.15 { reasons.append("encoding") }
        if url.hasDoubleEncoding { reasons.append("double_encoding") }
        guard !reasons.isEmpty else { return nil }
        return RiskFinding(id: id, points: 5,
                           evidence: ["reason": reasons.joined(separator: ","), "length": String(url.length),
                                      "ratio": String(format: "%.0f%%", url.percentEncodedRatio * 100)],
                           sources: [.S7])
    }
}
