import Foundation

/// P06 — Wi-Fi 설정 QR이 `nopass` 또는 `WEP` (+30).
public struct OpenWiFiRule: RiskRule {
    public let id: RuleID = .P06
    public let stage: RuleStage = .offline
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool {
        if case .wifi = input.payload { return true }
        return false
    }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard case .wifi(let config) = input.payload else { return nil }
        switch config.security {
        case .nopass, .wep:
            return RiskFinding(id: id, points: 30,
                               evidence: ["ssid": config.ssid, "security": config.security.rawValue],
                               sources: [.general])
        case .wpa, .other:
            return nil
        }
    }
}
