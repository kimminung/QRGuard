import Foundation

/// C03 — 출처=주차·결제 또는 킥보드·자전거 **그리고** eTLD+1이 `payment_mobility.json`에 없음 (+15).
public struct UnknownPaymentDomainRule: RiskRule {
    public let id: RuleID = .C03
    public let stage: RuleStage = .offline
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool {
        guard let place = input.context.place, place == .parkingOrPayment || place == .mobility else { return false }
        return input.hasWebURL
    }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard isApplicable(input), let site = input.finalSite ?? input.scannedSite else { return nil }
        let allowed = input.data.paymentMobilityDomains
        guard !allowed.contains(site) else { return nil }
        if let host = input.finalURL?.host, allowed.contains(host) { return nil }
        return RiskFinding(id: id, points: 15,
                           evidence: ["domain": Punycode.decodeHost(site), "place": input.context.place?.rawValue ?? ""],
                           sources: [.S2, .S5, .S9])
    }
}
