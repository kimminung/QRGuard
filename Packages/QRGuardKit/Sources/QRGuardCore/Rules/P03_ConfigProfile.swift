import Foundation

/// P03 — `.mobileconfig` 프로파일 설치 파일 또는 응답 Content-Type `application/x-apple-aspen-config` (floor 85).
public struct ConfigProfileRule: RiskRule {
    public let id: RuleID = .P03
    public let stage: RuleStage = .offline
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool { input.hasWebURL }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        let urls = [input.finalURL, input.url].compactMap { $0 }
        if urls.contains(where: { $0.pathExtension == "mobileconfig" }) {
            return RiskFinding(id: id, points: 0, floor: 85, evidence: ["ext": "mobileconfig"], sources: [.S1, .S3])
        }
        let contentTypes = [input.chain?.finalContentType, input.page?.contentType].compactMap { $0?.lowercased() }
        if contentTypes.contains(where: { $0.contains("application/x-apple-aspen-config") }) {
            return RiskFinding(id: id, points: 0, floor: 85, evidence: ["ext": "mobileconfig"], sources: [.S1, .S3])
        }
        return nil
    }
}
