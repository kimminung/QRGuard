import Foundation

/// V09 — 탐지 회피용 숨김 문자·문구 (floor 없음, 근거 `{count}`·`{snippet}`).
///
/// 셋 중 가장 높은 점수 하나만 적용한다.
/// - 페이지 숨김 텍스트(`display:none`·`font-size:0`·`aria-hidden` 등)에 분석 도구를 겨냥한 지시문 패턴 → +15
/// - 페이지 HTML의 불가시 문자(`Cf`·BOM·U+202E 등) ≥ 3 → +10
/// - QR 원문의 불가시 문자 ≥ 3 → +10
public struct HiddenTextEvasionRule: RiskRule {
    public let id: RuleID = .V09
    public let stage: RuleStage = .offline
    public init() {}

    static let invisibleThreshold = 3

    public func isApplicable(_ input: RuleInput) -> Bool { input.url != nil || input.page != nil }

    public func evaluate(_ input: RuleInput) -> RiskFinding? {
        // 1) 숨김 텍스트 속 지시문 (+15)
        if let page = input.page, !page.hiddenText.isEmpty,
           let match = InputSanitizer.detectsInjection(in: page.hiddenText) {
            return RiskFinding(id: id, points: 15,
                               evidence: ["reason": "hidden_instruction", "snippet": match.snippet,
                                          "count": String(page.invisibleCharacterCount)],
                               sources: [.general])
        }
        // 2) 페이지 불가시 문자 (+10)
        let pageInvisible = input.page?.invisibleCharacterCount ?? 0
        if pageInvisible >= Self.invisibleThreshold {
            return RiskFinding(id: id, points: 10,
                               evidence: ["reason": "page_invisible", "count": String(pageInvisible), "snippet": ""],
                               sources: [.general])
        }
        // 3) QR 원문 불가시 문자 (+10)
        let sanitized = InputSanitizer.sanitize(input.snapshot.raw)
        if sanitized.removedInvisibleCount >= Self.invisibleThreshold {
            return RiskFinding(id: id, points: 10,
                               evidence: ["reason": "payload_invisible", "count": String(sanitized.removedInvisibleCount),
                                          "snippet": String(sanitized.cleaned.prefix(80))],
                               sources: [.general])
        }
        return nil
    }
}
