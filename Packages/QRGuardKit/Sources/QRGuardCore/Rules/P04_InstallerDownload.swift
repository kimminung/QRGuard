import Foundation

/// P04 — 경로 확장자 `.apk .ipa .exe .msi .dmg .pkg` 또는 응답이 해당 설치 파일 (floor 75).
public struct InstallerDownloadRule: RiskRule {
    public let id: RuleID = .P04
    public let stage: RuleStage = .offline
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool { input.hasWebURL }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard let ext = InstallerFileHeuristics.detectedExtension(in: input) else { return nil }
        return RiskFinding(id: id, points: 0, floor: 75, evidence: ["ext": ext], sources: [.S1, .S2, .S3])
    }
}
