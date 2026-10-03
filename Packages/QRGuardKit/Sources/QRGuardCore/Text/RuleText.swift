import Foundation

/// 규칙 문구 현지화 도우미. `Resources/Localizable.xcstrings`의 `rule.<ID>.title/detail/advice` 키를 읽고
/// `{key}` 자리표시자를 `RiskFinding.evidence` 값으로 치환한다.
public enum RuleText {
    public static func title(for finding: RiskFinding, locale: Locale = .current) -> String {
        localized(finding.titleKey, evidence: finding.evidence, locale: locale)
    }

    public static func detail(for finding: RiskFinding, locale: Locale = .current) -> String {
        localized(finding.detailKey, evidence: finding.evidence, locale: locale)
    }

    public static func advice(for finding: RiskFinding, locale: Locale = .current) -> String {
        localized(finding.adviceKey, evidence: finding.evidence, locale: locale)
    }

    /// "통과한 검사" 항목 문구. 예: `rule.U01.pass` = "암호화된 연결(HTTPS)이에요"
    public static func passed(_ id: RuleID, locale: Locale = .current) -> String {
        localized("rule.\(id.rawValue).pass", evidence: [:], locale: locale)
    }

    /// 근거 기관명. 예: `source.S1.org` = "한국인터넷진흥원(KISA)"
    public static func organization(_ source: SourceID, locale: Locale = .current) -> String {
        localized(source.organizationKey, evidence: [:], locale: locale)
    }

    public static func localized(_ key: String, evidence: [String: String], locale: Locale = .current) -> String {
        var text = lookup(key, locale: locale)
        for (k, v) in evidence {
            text = text.replacingOccurrences(of: "{\(k)}", with: v)
        }
        if locale.language.languageCode?.identifier == "ko" || (locale.language.languageCode == nil && Locale.current.language.languageCode?.identifier == "ko") {
            text = KoreanParticle.resolve(in: text)
        }
        return text
    }

    /// 로케일의 언어 `.lproj`를 먼저 찾고(`String(localized:locale:)`는 프로세스 언어를 따르는 경우가 있어 명시적으로 고른다),
    /// 없으면 모듈 번들 기본 조회로 폴백한다. 키가 없으면 키 문자열을 그대로 돌려준다.
    static func lookup(_ key: String, locale: Locale) -> String {
        var candidates: [String] = []
        if let code = locale.language.languageCode?.identifier { candidates.append(code) }
        candidates.append(locale.identifier)
        for code in candidates {
            guard let path = Bundle.module.path(forResource: code, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { continue }
            let value = bundle.localizedString(forKey: key, value: nil, table: nil)
            if value != key { return value }
        }
        return String(localized: String.LocalizationValue(key), bundle: .module, locale: locale)
    }
}
