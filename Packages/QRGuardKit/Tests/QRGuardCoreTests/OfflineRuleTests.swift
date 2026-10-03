import Foundation
import Testing
@testable import QRGuardCore

/// 오프라인 규칙(P·U·B·C) 단위 테스트 — 규칙별 양성 2 · 음성 1 이상.
@Suite("Offline rules (T-1.5)")
struct OfflineRuleTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let raw: String
        let fires: Bool
        var place: PlaceContext? = nil
        var codes: Int = 1
        var evidence: [String: String] = [:]
        var testDescription: String { "\(fires ? "+" : "-") \(raw)" }
    }

    private func check(_ rule: some RiskRule, _ c: Case, prior: [RuleFinding] = []) {
        let context = AnalysisContext(source: .camera, place: c.place, distinctCodesInFrame: c.codes, options: .offline)
        let input = TestSupport.input(c.raw, context: context, prior: prior.map { $0.finding })
        let finding = rule.evaluate(input)
        #expect((finding != nil) == c.fires, "\(rule.id) on \(c.raw): \(String(describing: finding))")
        if let finding {
            #expect(finding.id == rule.id)
            for (k, v) in c.evidence { #expect(finding.evidence[k] == v, "evidence \(k)") }
            #expect(rule.isApplicable(input), "fired but not applicable")
        }
    }

    struct RuleFinding: Sendable { let finding: RiskFinding }
    private func prior(_ id: RuleID, _ points: Int = 10) -> RuleFinding { RuleFinding(finding: RiskFinding(id: id, points: points)) }

    // MARK: P

    @Test(arguments: [
        Case(raw: "javascript:alert(1)", fires: true, evidence: ["scheme": "javascript"]),
        Case(raw: "data:text/html;base64,PGh0bWw+", fires: true),
        Case(raw: "file:///etc/passwd", fires: true),
        Case(raw: "blob:https://example.test/uuid", fires: true),
        Case(raw: "https://example.test/javascript:alert(1)", fires: false),
    ]) func p01(_ c: Case) { check(DangerousSchemeRule(), c) }

    @Test(arguments: [
        Case(raw: "itms-services://?action=download-manifest&url=https://example.test/app.plist", fires: true),
        Case(raw: "ITMS-SERVICES://?action=download-manifest", fires: true),
        Case(raw: "itms-apps://apps.apple.com/app/id1", fires: false),
        Case(raw: "https://example.test/itms-services", fires: false),
    ]) func p02(_ c: Case) { check(EnterpriseInstallRule(), c) }

    @Test(arguments: [
        Case(raw: "https://example.test/profile.mobileconfig", fires: true, evidence: ["ext": "mobileconfig"]),
        Case(raw: "https://example.test/dl/Config.MOBILECONFIG?x=1", fires: true),
        Case(raw: "https://example.test/profile.html", fires: false),
    ]) func p03(_ c: Case) { check(ConfigProfileRule(), c) }

    @Test func p03ByContentType() {
        let s = TestSupport.snapshot("https://example.test/get", chain: TestSupport.chain(["https://example.test/get"], contentType: "application/x-apple-aspen-config"))
        #expect(ConfigProfileRule().evaluate(TestSupport.input(snapshot: s)) != nil)
    }

    @Test(arguments: [
        Case(raw: "https://example.test/app.apk", fires: true, evidence: ["ext": "apk"]),
        Case(raw: "https://example.test/setup.EXE", fires: true, evidence: ["ext": "exe"]),
        Case(raw: "https://example.test/x.ipa", fires: true),
        Case(raw: "https://example.test/x.dmg", fires: true),
        Case(raw: "https://example.test/x.pkg", fires: true),
        Case(raw: "https://example.test/x.msi", fires: true),
        Case(raw: "https://example.test/apk/index.html", fires: false),
        Case(raw: "https://example.test/x.pdf", fires: false),
    ]) func p04(_ c: Case) { check(InstallerDownloadRule(), c) }

    @Test func p04ByContentTypeAndFinalURL() {
        let byType = TestSupport.snapshot("https://example.test/get", chain: TestSupport.chain(["https://example.test/get"], contentType: "application/vnd.android.package-archive"))
        #expect(InstallerDownloadRule().evaluate(TestSupport.input(snapshot: byType))?.evidence["ext"] == "apk")
        let byFinal = TestSupport.snapshot("https://example.test/dl", chain: TestSupport.chain(["https://example.test/dl", "https://cdn.example.test/app.apk"]))
        #expect(InstallerDownloadRule().evaluate(TestSupport.input(snapshot: byFinal))?.evidence["ext"] == "apk")
        let octet = TestSupport.snapshot("https://example.test/dl", chain: TestSupport.chain(["https://example.test/dl"], contentType: "application/octet-stream"))
        #expect(InstallerDownloadRule().evaluate(TestSupport.input(snapshot: octet)) == nil)
    }

    @Test(arguments: [
        Case(raw: "foo://bar/baz", fires: true, evidence: ["scheme": "foo"]),
        Case(raw: "myapp://open?x=1", fires: true),
        Case(raw: "kakaotalk://open", fires: false),
        Case(raw: "https://example.test/", fires: false),
    ]) func p05(_ c: Case) { check(UnknownAppSchemeRule(), c) }

    @Test(arguments: [
        Case(raw: "kakaotalk://open", fires: true, evidence: ["app": "카카오톡"]),
        Case(raw: "supertoss://send", fires: true, evidence: ["app": "토스"]),
        Case(raw: "itms-apps://apps.apple.com/app/id1", fires: true, evidence: ["app": "App Store"]),
        Case(raw: "foo://bar", fires: false),
        Case(raw: "itms-services://?x", fires: false),
    ]) func p05a(_ c: Case) { check(KnownAppSchemeRule(), c) }

    @Test func p05NotApplicableToWebURL() {
        #expect(!UnknownAppSchemeRule().isApplicable(TestSupport.input("https://example.test/")))
        #expect(!KnownAppSchemeRule().isApplicable(TestSupport.input("https://example.test/")))
        #expect(!UnknownAppSchemeRule().isApplicable(TestSupport.input("itms-services://?x")))
    }

    @Test(arguments: [
        Case(raw: "WIFI:T:nopass;S:Free;;", fires: true, evidence: ["security": "nopass"]),
        Case(raw: "WIFI:T:WEP;S:Old;P:1234;;", fires: true, evidence: ["security": "WEP"]),
        Case(raw: "WIFI:S:Open;;", fires: true),
        Case(raw: "WIFI:T:WPA;S:Home;P:pw;;", fires: false),
    ]) func p06(_ c: Case) { check(OpenWiFiRule(), c) }

    @Test func p06NotApplicableToURL() { #expect(!OpenWiFiRule().isApplicable(TestSupport.input("https://example.test/"))) }

    @Test(arguments: [
        Case(raw: "SMSTO:01012345678:확인 https://example.test/login", fires: true),
        Case(raw: "sms:01012345678?body=example.com/x", fires: true),
        Case(raw: "SMSTO:01012345678:안녕하세요", fires: false),
        Case(raw: "sms:01012345678", fires: false),
    ]) func p07(_ c: Case) { check(SMSWithLinkRule(), c) }

    @Test(arguments: [
        Case(raw: "tel:060-700-1234", fires: true),
        Case(raw: "sms:0601234567?body=hi", fires: true),
        Case(raw: "tel:+82-60-700-1234", fires: true),
        Case(raw: "tel:02-1234-5678", fires: false),
        Case(raw: "tel:+82-10-6000-0000", fires: false),
    ]) func p08(_ c: Case) { check(PremiumRateNumberRule(), c) }

    @Test(arguments: [
        Case(raw: "bitcoin:1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa?amount=0.01", fires: true, evidence: ["scheme": "bitcoin", "amount": "0.01"]),
        Case(raw: "ethereum:0xAbC0000000000000000000000000000000000001", fires: true),
        Case(raw: "국민 123456-78-901234 홍길동", fires: true, evidence: ["scheme": "bankAccount"]),
        Case(raw: "https://example.test/pay", fires: false),
    ]) func p09(_ c: Case) { check(PaymentPayloadRule(), c) }

    @Test func p09FloorIs40() {
        #expect(PaymentPayloadRule().evaluate(TestSupport.input("bitcoin:abc"))?.floor == 40)
    }

    @Test(arguments: [
        Case(raw: "행사 안내 example.com/event 확인", fires: true, evidence: ["count": "1"]),
        Case(raw: "링크 두 개 https://a.example.test 와 https://b.example.test", fires: true, evidence: ["count": "2"]),
        Case(raw: "그냥 텍스트입니다", fires: false),
    ]) func p10(_ c: Case) { check(TextWithLinkRule(), c) }

    // MARK: U

    @Test(arguments: [
        Case(raw: "http://example.test/", fires: true),
        Case(raw: "HTTP://EXAMPLE.TEST/login", fires: true),
        Case(raw: "https://example.test/", fires: false),
    ]) func u01(_ c: Case) { check(InsecureHTTPRule(), c) }

    @Test func u01NotApplicableToNonWeb() { #expect(!InsecureHTTPRule().isApplicable(TestSupport.input("kakaotalk://open"))) }

    @Test(arguments: [
        Case(raw: "http://192.168.0.1/login", fires: true, evidence: ["ip": "192.168.0.1"]),
        Case(raw: "https://0x7f.1/", fires: true, evidence: ["ip": "127.0.0.1"]),
        Case(raw: "https://2130706433/", fires: true, evidence: ["ip": "127.0.0.1"]),
        Case(raw: "https://[2001:db8::1]/", fires: true),
        Case(raw: "https://example.test/", fires: false),
        Case(raw: "https://123.example.test/", fires: false),
    ]) func u02(_ c: Case) { check(IPAddressHostRule(), c) }

    @Test(arguments: [
        Case(raw: "https://naver.com@evil.example.test/verify", fires: true, evidence: ["hidden_host": "evil.example.test"]),
        Case(raw: "https://user:pass@example.test/", fires: true, evidence: ["hidden_host": "example.test"]),
        Case(raw: "https://example.test/?email=a@b.test", fires: false),
    ]) func u03(_ c: Case) { check(UserInfoAtRule(), c) }

    @Test(arguments: [
        Case(raw: "https://example.test:8443/", fires: true, evidence: ["port": "8443"]),
        Case(raw: "http://example.test:8080/", fires: true, evidence: ["port": "8080"]),
        Case(raw: "https://example.test:443/", fires: false),
        Case(raw: "http://example.test:80/", fires: false),
    ]) func u04(_ c: Case) { check(NonStandardPortRule(), c) }

    @Test(arguments: [
        Case(raw: "https://xn--nver-53d.test/", fires: true),          // nаver (키릴 а)
        Case(raw: "https://xn--navr-x4d.com/", fires: true),           // navеr (키릴 е)
        Case(raw: "https://xn--pypal-4ve.test/", fires: true),         // pаypal
        Case(raw: "https://xn--80ak6aa92e.com/", fires: false),        // 전부 키릴 — 혼합 아님
        Case(raw: "https://xn--3e0b707e.test/", fires: false),         // 한국 — 혼합 아님
        Case(raw: "https://example.test/", fires: false),
    ]) func u05(_ c: Case) { check(MixedScriptIDNRule(), c) }

    @Test(arguments: [
        Case(raw: "https://a.b.c.d.example.test/", fires: true, evidence: ["depth": "4"]),
        Case(raw: "https://this-is-a-very-long-hostname-for-testing-purposes-only.example.test/", fires: true),
        Case(raw: "https://a.b.c.example.test/", fires: false),
        Case(raw: "https://www.example.test/", fires: false),
    ]) func u06(_ c: Case) { check(DeepSubdomainRule(), c) }

    @Test(arguments: [
        Case(raw: "https://example.test/" + String(repeating: "a", count: 200), fires: true, evidence: ["reason": "length"]),
        Case(raw: "https://example.test/%252e%252e/x", fires: true, evidence: ["reason": "encoding,double_encoding"]),
        Case(raw: "https://example.test/%2e%2e%2f%61%64%6d%69%6e", fires: true, evidence: ["reason": "encoding"]),
        Case(raw: "https://example.test/short/path?q=1", fires: false),
        Case(raw: "https://example.test/%ED%83%9D%EB%B0%B0/%EC%A1%B0%ED%9A%8C", fires: false),   // 한글 경로는 난독화가 아님
    ]) func u07(_ c: Case) { check(ObfuscatedURLRule(), c) }

    @Test(arguments: [
        Case(raw: "https://event-gift.xyz/coupon", fires: true, evidence: ["tld": ".xyz"]),
        Case(raw: "https://promo.example.top/", fires: true, evidence: ["tld": ".top"]),
        Case(raw: "https://a.b.example.icu/", fires: true),
        Case(raw: "https://example.com/", fires: false),
        Case(raw: "https://example.test/", fires: false),
        Case(raw: "https://xyz.example.com/", fires: false),
    ]) func u08(_ c: Case) { check(SuspiciousTLDRule(), c) }

    @Test(arguments: [
        Case(raw: "https://example.test/?next=https%3A%2F%2Fevil.example.invalid%2Flogin", fires: true, evidence: ["target": "evil.example.invalid"]),
        Case(raw: "https://example.test/go?url=https://other.example.com/", fires: true, evidence: ["param": "url"]),
        Case(raw: "https://example.test/go?redirect_uri=//evil.example.invalid/cb", fires: true),
        Case(raw: "https://example.test/?next=https://sub.example.test/home", fires: false),
        Case(raw: "https://example.test/?next=/account", fires: false),
        Case(raw: "https://example.test/?q=https://evil.example.invalid/", fires: false),
    ]) func u09(_ c: Case) { check(OpenRedirectParamRule(), c) }

    @Test(arguments: [
        Case(raw: "https://secure-login.example.test/", fires: true, evidence: ["keyword": "login"]),
        Case(raw: "https://example.test/택배/조회", fires: true, evidence: ["keyword": "택배"]),
        Case(raw: "https://example.test/%ED%83%9D%EB%B0%B0", fires: true, evidence: ["keyword": "택배"]),
        Case(raw: "https://example.test/account/verify", fires: true),
        Case(raw: "https://example.test/products/123", fires: false),
        Case(raw: "https://tossbank.com/", fires: false),      // 공식 도메인 호스트의 'bank'는 미끼가 아님
    ]) func u10(_ c: Case) { check(BaitKeywordRule(), c) }

    @Test(arguments: [
        Case(raw: "https://bit.ly/3gH2kQ", fires: true, evidence: ["service": "bit.ly"]),
        Case(raw: "https://tinyurl.com/abc", fires: true),
        Case(raw: "https://me2.do/xyz", fires: true),
        Case(raw: "https://example.test/", fires: false),
        Case(raw: "https://youtu.be/abc", fires: false),
    ]) func u11(_ c: Case) { check(URLShortenerRule(), c) }

    // MARK: B

    @Test(arguments: [
        Case(raw: "https://naver-login.account-check.test/verify", fires: true, evidence: ["brand": "네이버", "where": "host"]),
        Case(raw: "https://www.kakao-event.example.test/", fires: true, evidence: ["brand": "카카오"]),
        Case(raw: "https://example.test/toss/promo", fires: true, evidence: ["where": "path"]),
        Case(raw: "https://coupanglogin.example.test/", fires: true),      // 5자 이상 키워드는 부분 문자열
        Case(raw: "https://www.naver.com/login", fires: false),
        Case(raw: "https://m.kakaopay.com/", fires: false),
        Case(raw: "https://example.test/", fires: false),
        Case(raw: "https://metadata.example.test/", fires: false),        // 4자 키워드는 토큰 일치만
    ]) func b01(_ c: Case) { check(BrandKeywordMismatchRule(), c) }

    @Test func b01PrefersFinalURL() {
        let s = TestSupport.snapshot("https://bit.ly/x", chain: TestSupport.chain(["https://bit.ly/x", "https://naver-login.example.test/"]))
        #expect(BrandKeywordMismatchRule().evaluate(TestSupport.input(snapshot: s))?.evidence["brand"] == "네이버")
    }

    @Test(arguments: [
        Case(raw: "https://naverr.com/", fires: true, evidence: ["official": "naver.com"]),
        Case(raw: "https://xn--navr-x4d.com/", fires: true, evidence: ["method": "skeleton"]),  // navеr (키릴 е)
        Case(raw: "https://g00gle.com/", fires: true, evidence: ["official": "google.com", "method": "skeleton"]),
        Case(raw: "https://kakoa.com/", fires: true),                  // 전치
        Case(raw: "https://naver.co/", fires: true),                   // eTLD+1 전체 거리 1
        Case(raw: "https://xn--80ak6aa92e.com/", fires: true, evidence: ["official": "apple.com"]),
        Case(raw: "https://www.naver.com/", fires: false),
        Case(raw: "https://example.test/", fires: false),
        Case(raw: "https://boss.test/", fires: true),                  // 라벨 'boss' vs 'toss' 거리 1 (4자 브랜드는 거리 1까지)
        Case(raw: "https://tosses.test/", fires: false),               // 'tosses' vs 'toss' 거리 2 → 4자 브랜드엔 허용치 초과
    ]) func b02(_ c: Case) { check(LookalikeDomainRule(), c) }

    @Test(arguments: [
        Case(raw: "https://www.naver.com/", fires: true, evidence: ["brand": "네이버"]),
        Case(raw: "https://m.kakao.com/talk", fires: true),
        Case(raw: "https://www.hometax.go.kr/", fires: true),
        Case(raw: "http://www.naver.com/", fires: false),
        Case(raw: "https://example.test/", fires: false),
        Case(raw: "https://naverr.com/", fires: false),
    ]) func b03(_ c: Case) { check(OfficialDomainRule(), c) }

    @Test func b03WithChain() {
        let ok = TestSupport.snapshot("https://naver.me/x", chain: TestSupport.chain(["https://naver.me/x", "https://m.naver.com/"]))
        #expect(OfficialDomainRule().evaluate(TestSupport.input(snapshot: ok)) != nil)
        let leaves = TestSupport.snapshot("https://www.naver.com/r", chain: TestSupport.chain(["https://www.naver.com/r", "https://evil.example.test/", "https://www.naver.com/"]))
        #expect(OfficialDomainRule().evaluate(TestSupport.input(snapshot: leaves)) == nil)
        let endsElsewhere = TestSupport.snapshot("https://www.naver.com/r", chain: TestSupport.chain(["https://www.naver.com/r", "https://evil.example.test/"]))
        #expect(OfficialDomainRule().evaluate(TestSupport.input(snapshot: endsElsewhere)) == nil)
        let downgrade = TestSupport.snapshot("https://www.naver.com/r", chain: TestSupport.chain(["https://www.naver.com/r", "http://m.naver.com/"]))
        #expect(OfficialDomainRule().evaluate(TestSupport.input(snapshot: downgrade)) == nil)
    }

    @Test func b03PointsAreNegative20() {
        #expect(OfficialDomainRule().evaluate(TestSupport.input("https://www.naver.com/"))?.points == -20)
    }

    // MARK: C

    @Test(arguments: [
        Case(raw: "https://example.test/", fires: true, codes: 2, evidence: ["count": "2"]),
        Case(raw: "https://example.test/", fires: true, codes: 3),
        Case(raw: "https://example.test/", fires: false, codes: 1),
    ]) func c01(_ c: Case) { check(MultipleCodesRule(), c) }

    @Test func c02() {
        let msg = AnalysisContext(source: .camera, place: .emailOrMessage, options: .offline)
        let other = AnalysisContext(source: .camera, place: .storeOrMenu, options: .offline)
        let none = AnalysisContext(source: .camera, options: .offline)
        let rule = MessageDemandsActionRule()
        #expect(rule.evaluate(TestSupport.input("https://example.test/", context: msg, prior: [RiskFinding(id: .U10, points: 10)])) != nil)
        #expect(rule.evaluate(TestSupport.input("https://example.test/", context: msg, prior: [RiskFinding(id: .P04, points: 0, floor: 75)])) != nil)
        #expect(rule.evaluate(TestSupport.input("https://example.test/", context: msg, prior: [RiskFinding(id: .H01, points: 15)])) != nil)
        #expect(rule.evaluate(TestSupport.input("https://example.test/", context: msg, prior: [])) == nil)
        #expect(rule.evaluate(TestSupport.input("https://example.test/", context: other, prior: [RiskFinding(id: .U10, points: 10)])) == nil)
        #expect(!rule.isApplicable(TestSupport.input("https://example.test/", context: none)))
        #expect(!rule.isApplicable(TestSupport.input("https://example.test/", context: other)))
    }

    @Test(arguments: [
        Case(raw: "https://pay.example.test/park", fires: true, place: .parkingOrPayment, evidence: ["domain": "example.test"]),
        Case(raw: "https://scooter.example.test/ride", fires: true, place: .mobility),
        Case(raw: "https://kakaomobility.com/pay", fires: false, place: .mobility),
        Case(raw: "https://www.bikeseoul.com/", fires: false, place: .mobility),
        Case(raw: "https://pay.example.test/park", fires: false, place: .other),
        Case(raw: "https://pay.example.test/park", fires: false),
    ]) func c03(_ c: Case) { check(UnknownPaymentDomainRule(), c) }

    @Test func c03NotApplicableWithoutPlaceOrURL() {
        #expect(!UnknownPaymentDomainRule().isApplicable(TestSupport.input("https://example.test/")))
        let ctx = AnalysisContext(source: .camera, place: .parkingOrPayment, options: .offline)
        #expect(!UnknownPaymentDomainRule().isApplicable(TestSupport.input("WIFI:T:WPA;S:x;P:y;;", context: ctx)))
    }

    // MARK: 카탈로그

    @Test func catalogContainsEveryRuleOnce() {
        let ids = RuleCatalog.allRules.map(\.id)
        #expect(ids.count == 41)
        #expect(Set(ids).count == ids.count)
        let expected: [RuleID] = [.P01, .P02, .P03, .P04, .P05, .P05a, .P06, .P07, .P08, .P09, .P10,
                                  .U01, .U02, .U03, .U04, .U05, .U06, .U07, .U08, .U09, .U10, .U11,
                                  .B01, .B02, .B03, .R01, .R02, .R03, .R04, .R05, .T01, .D01, .D02, .D03,
                                  .H01, .H02, .H03, .H05, .C01, .C02, .C03]
        #expect(ids == expected)
        #expect(RuleCatalog.offlineRules.count == 28)   // P 11 + U 11 + B 3 + C 3
        #expect(RuleCatalog.onlineRules.count == 13)    // R 5 + T 1 + D 3 + H 4
    }
}
