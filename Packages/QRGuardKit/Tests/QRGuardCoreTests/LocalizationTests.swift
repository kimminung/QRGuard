import Foundation
import Testing
@testable import QRGuardCore

@Suite("Localizable.xcstrings")
struct LocalizationTests {
    static let allRuleIDs: [RuleID] = RuleCatalog.allRules.map(\.id)

    /// xcstrings는 빌드 시 `.lproj/Localizable.strings`로 컴파일되므로 원본 카탈로그는 소스 경로에서 읽는다.
    static var catalogURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // QRGuardCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // QRGuardKit
            .appendingPathComponent("Sources/QRGuardCore/Resources/Localizable.xcstrings")
    }

    @Test func catalogContainsEveryKeyInKoAndEn() throws {
        let url = Self.catalogURL
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(json["sourceLanguage"] as? String == "ko")
        let strings = try #require(json["strings"] as? [String: Any])
        var keys: [String] = []
        for id in Self.allRuleIDs { for s in ["title", "detail", "advice", "pass"] { keys.append("rule.\(id.rawValue).\(s)") } }
        for src in SourceID.allCases { keys.append(src.organizationKey) }
        for key in keys {
            let entry = strings[key] as? [String: Any]
            let loc = entry?["localizations"] as? [String: Any]
            #expect(loc?["ko"] != nil, "missing ko for \(key)")
            #expect(loc?["en"] != nil, "missing en for \(key)")
        }
    }

    @Test func koreanTitlesResolve() {
        let ko = Locale(identifier: "ko")
        let u03 = RiskFinding(id: .U03, points: 25, evidence: ["hidden_host": "evil.example"])
        #expect(RuleText.title(for: u03, locale: ko) == "주소 앞부분이 진짜 목적지를 가리고 있어요")
        #expect(RuleText.detail(for: u03, locale: ko).contains("evil.example"))
        #expect(!RuleText.detail(for: u03, locale: ko).contains("{hidden_host}"))
        #expect(RuleText.passed(.U01, locale: ko) == "암호화된 연결(HTTPS)이에요")
        #expect(RuleText.organization(.S1, locale: ko) == "한국인터넷진흥원(KISA)")
        #expect(RuleText.title(for: RiskFinding(id: .B03, points: -20), locale: ko) == "공식 도메인으로 확인됐어요")
        #expect(RuleText.title(for: RiskFinding(id: .P05a, points: 5, evidence: ["app": "카카오톡"]), locale: ko) == "카카오톡 앱을 실행하는 링크예요")
    }

    @Test func englishTitlesResolve() {
        let en = Locale(identifier: "en")
        let title = RuleText.title(for: RiskFinding(id: .U03, points: 25, evidence: ["hidden_host": "evil.example"]), locale: en)
        #expect(title == "The start of the address hides the real destination")
        #expect(RuleText.passed(.U01, locale: en) == "Encrypted connection (HTTPS)")
        #expect(RuleText.organization(.S8, locale: en) == "Google Safe Browsing")
        #expect(RuleText.organization(.S1, locale: Locale(identifier: "en_US")) == "Korea Internet & Security Agency (KISA)")
        // 지원하지 않는 언어는 키가 아닌 문구(기본 언어 또는 프로세스 언어)로 폴백한다.
        #expect(RuleText.title(for: RiskFinding(id: .U03, points: 25), locale: Locale(identifier: "fr")) != "rule.U03.title")
    }

    @Test func everyRuleHasNonKeyTitle() {
        for id in Self.allRuleIDs {
            let t = RuleText.title(for: RiskFinding(id: id, points: 0), locale: Locale(identifier: "ko"))
            #expect(t != "rule.\(id.rawValue).title", "missing title for \(id)")
            #expect(!t.contains("안전합니다"), "no absolute safety claims")
            let p = RuleText.passed(id, locale: Locale(identifier: "ko"))
            #expect(p != "rule.\(id.rawValue).pass", "missing pass for \(id)")
        }
    }
}
