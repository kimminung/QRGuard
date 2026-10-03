import Foundation

/// U09 — 쿼리 파라미터(`url, redirect, next, goto, target, …`)에 **다른 eTLD+1** 주소가 들어 있음 (+15, 근거 `{target}`).
public struct OpenRedirectParamRule: RiskRule {
    public static let parameterNames: Set<String> = [
        "url", "redirect", "redirect_uri", "redirect_url", "redirecturl", "next", "goto", "target", "dest", "destination",
        "r", "u", "link", "return", "return_url", "returnurl", "return_to", "continue", "forward", "to", "rurl", "callback",
    ]

    public let id: RuleID = .U09
    public let stage: RuleStage = .offline
    public init() {}

    public func isApplicable(_ input: RuleInput) -> Bool { input.hasWebURL }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        guard let url = input.url, let site = input.scannedSite else { return nil }
        for item in url.queryItems where Self.parameterNames.contains(item.name.lowercased()) {
            guard var value = item.value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { continue }
            // 한 번 더 인코딩된 값도 풀어 본다.
            if value.hasPrefix("%"), let decoded = value.removingPercentEncoding { value = decoded }
            if value.hasPrefix("//") { value = "https:" + value }
            guard let targetURL = URL(string: value) ?? PayloadParser.percentEncodedURL(value),
                  let target = input.normalize(targetURL), target.isWeb, !target.host.isEmpty else { continue }
            let targetSite = target.registrableDomain ?? target.host
            if targetSite != site {
                return RiskFinding(id: id, points: 15,
                                   evidence: ["target": target.unicodeHost, "param": item.name, "site": site],
                                   sources: [.S7])
            }
        }
        return nil
    }
}
