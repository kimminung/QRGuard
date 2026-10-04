import Foundation

/// V03 — ASCII QR: 문자·CSS로 그린 QR(블록 문자 `█▀▄` 격자 등)을 렌더링한 뒤 디코딩함 (+10). 근거 S11. floor 없음.
public struct TextArtQRRule: RiskRule {
    public let id: RuleID = .V03
    public let stage: RuleStage = .offline
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool { input.snapshot.vision != nil }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard let vision = input.snapshot.vision, vision.decodedFromTextArt else { return nil }
        return RiskFinding(id: id, points: 10, sources: [.S11])
    }
}
