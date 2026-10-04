import Foundation

/// V01 — 분할 QR: 단독 디코딩에 실패한 이미지를 인접 이미지와 결합한 뒤에야 디코딩됐거나(+15),
/// 파인더 패턴 수가 디코딩된 코드 수보다 2개 넘게 많아 디코딩되지 않은 조각이 의심됨(+15). 근거 S11. floor 없음.
public struct SplitQRRule: RiskRule {
    public let id: RuleID = .V01
    public let stage: RuleStage = .offline
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool { input.snapshot.vision != nil }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard let vision = input.snapshot.vision else { return nil }
        if vision.decodedFromCombinedImages {
            return RiskFinding(id: id, points: 15,
                               evidence: ["reason": "combined", "decoded": String(vision.decodedCodeCount)],
                               sources: [.S11])
        }
        if vision.suspectsFragments, let finders = vision.finderPatternCount {
            return RiskFinding(id: id, points: 15,
                               evidence: ["reason": "fragments", "finders": String(finders), "decoded": String(vision.decodedCodeCount)],
                               sources: [.S11])
        }
        return nil
    }
}
