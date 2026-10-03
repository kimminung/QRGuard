import Foundation
import Testing
@testable import QRGuardCore

/// 온라인 규칙(R·T·D·H)은 스냅샷의 체인·평판·도메인·페이지 데이터에 대한 순수 함수다. 손으로 만든 스냅샷으로 검사한다.
@Suite("Online rules over snapshots")
struct OnlineRuleTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func hops(_ n: Int, base: String = "https://example.test/") -> [String] {
        (0..<n).map { "\(base)hop\($0)" }
    }

    // MARK: R

    @Test func r01Counts() {
        let rule = ManyRedirectsRule()
        #expect(rule.evaluate(TestSupport.input(snapshot: TestSupport.snapshot("https://example.test/hop0", chain: TestSupport.chain(hops(3)))) ) == nil) // 2회
        let three = rule.evaluate(TestSupport.input(snapshot: TestSupport.snapshot("https://example.test/hop0", chain: TestSupport.chain(hops(4)))))
        #expect(three?.points == 10 && three?.evidence["count"] == "3")
        let five = rule.evaluate(TestSupport.input(snapshot: TestSupport.snapshot("https://example.test/hop0", chain: TestSupport.chain(hops(6)))))
        #expect(five?.points == 10)
        let six = rule.evaluate(TestSupport.input(snapshot: TestSupport.snapshot("https://example.test/hop0", chain: TestSupport.chain(hops(7)))))
        #expect(six?.points == 20)
        #expect(!rule.isApplicable(TestSupport.input("https://example.test/")))
    }

    @Test func r02DestinationMismatch() {
        let rule = DestinationMismatchRule()
        let mismatch = TestSupport.snapshot("https://example.test/r", chain: TestSupport.chain(["https://example.test/r", "https://other.example.invalid/"]))
        let f = rule.evaluate(TestSupport.input(snapshot: mismatch))
        #expect(f?.points == 10)
        #expect(f?.evidence["first"] == "example.test" && f?.evidence["final"] == "other.example.invalid")
        let same = TestSupport.snapshot("https://example.test/r", chain: TestSupport.chain(["https://example.test/r", "https://www.example.test/"]))
        #expect(rule.evaluate(TestSupport.input(snapshot: same)) == nil)
        let shortener = TestSupport.snapshot("https://bit.ly/x", chain: TestSupport.chain(["https://bit.ly/x", "https://other.example.invalid/"]))
        #expect(rule.evaluate(TestSupport.input(snapshot: shortener)) == nil)
        #expect(!rule.isApplicable(TestSupport.input(snapshot: TestSupport.snapshot("https://example.test/", chain: TestSupport.chain(["https://example.test/"])))))
    }

    @Test func r03Downgrade() {
        let rule = HTTPSDowngradeRule()
        let down = TestSupport.snapshot("https://example.test/a", chain: TestSupport.chain(["https://example.test/a", "http://example.test/b"], outcome: .stoppedAtInsecureHop))
        #expect(rule.evaluate(TestSupport.input(snapshot: down))?.points == 15)
        let later = TestSupport.snapshot("https://example.test/a", chain: TestSupport.chain(["https://example.test/a", "https://b.example.test/", "http://c.example.test/"]))
        #expect(rule.evaluate(TestSupport.input(snapshot: later))?.evidence["hop"] == "2")
        let up = TestSupport.snapshot("http://example.test/a", chain: TestSupport.chain(["http://example.test/a", "https://example.test/b"]))
        #expect(rule.evaluate(TestSupport.input(snapshot: up)) == nil)
    }

    @Test func r04UnresolvedShortener() {
        let rule = UnresolvedShortenerRule()
        let timeout = TestSupport.snapshot("https://bit.ly/x", chain: TestSupport.chain(["https://bit.ly/x"], outcome: .timedOut))
        #expect(rule.evaluate(TestSupport.input(snapshot: timeout))?.points == 15)
        let failed = TestSupport.snapshot("https://t.ly/x", chain: TestSupport.chain(["https://t.ly/x"], outcome: .failed("dns")))
        #expect(rule.evaluate(TestSupport.input(snapshot: failed))?.evidence["service"] == "t.ly")
        let completed = TestSupport.snapshot("https://bit.ly/x", chain: TestSupport.chain(["https://bit.ly/x", "https://example.test/"], outcome: .completed))
        #expect(rule.evaluate(TestSupport.input(snapshot: completed)) == nil)
        let notShortener = TestSupport.snapshot("https://example.test/x", chain: TestSupport.chain(["https://example.test/x"], outcome: .timedOut))
        #expect(rule.evaluate(TestSupport.input(snapshot: notShortener)) == nil)
    }

    @Test func r05MetaRefresh() {
        let rule = MetaRefreshRule()
        let viaHop = TestSupport.snapshot("https://example.test/a", chain: TestSupport.chain(["https://example.test/a", "https://b.example.test/"], metaRefreshAt: 1))
        #expect(rule.evaluate(TestSupport.input(snapshot: viaHop))?.points == 10)
        let viaPage = TestSupport.snapshot("https://example.test/a", chain: nil, page: PagePrecheckResult(metaRefreshTarget: URL(string: "https://c.example.test/")))
        #expect(rule.evaluate(TestSupport.input(snapshot: viaPage))?.evidence["target"] == "c.example.test")
        let plain = TestSupport.snapshot("https://example.test/a", chain: TestSupport.chain(["https://example.test/a", "https://b.example.test/"]))
        #expect(rule.evaluate(TestSupport.input(snapshot: plain)) == nil)
        #expect(!rule.isApplicable(TestSupport.input("https://example.test/")))
    }

    // MARK: T

    @Test func t01ReputationHit() {
        let rule = ThreatListHitRule()
        let url = URL(string: "https://example.test/x")!
        let s = TestSupport.snapshot("https://example.test/x", chain: nil, reputation: [ReputationLookup(url: url, provider: "Google Safe Browsing", verdict: .malicious(threatTypes: ["SOCIAL_ENGINEERING"]))])
        let f = rule.evaluate(TestSupport.input(snapshot: s))
        #expect(f?.floor == 90)
        #expect(f?.evidence["provider"] == "Google Safe Browsing")
        #expect(f?.evidence["threats"] == "SOCIAL_ENGINEERING")
        let clean = TestSupport.snapshot("https://example.test/x", chain: nil, reputation: [ReputationLookup(url: url, provider: "Google Safe Browsing", verdict: .clean)])
        #expect(rule.evaluate(TestSupport.input(snapshot: clean)) == nil)
    }

    @Test func t01LocalBlocklistAnywhereInChain() {
        let rule = ThreatListHitRule()
        let middle = TestSupport.snapshot("https://example.test/a", chain: TestSupport.chain(["https://example.test/a", "https://malware.example.test/x", "https://example.test/b"]))
        let f = rule.evaluate(TestSupport.input(snapshot: middle))
        #expect(f?.floor == 90)
        #expect(f?.evidence["provider"] == ThreatListHitRule.localProviderName)
        let last = TestSupport.snapshot("https://example.test/a", chain: TestSupport.chain(["https://example.test/a", "https://phish.example.test/"]))
        #expect(rule.evaluate(TestSupport.input(snapshot: last)) != nil)
        let prefix = TestSupport.input("https://example.test/blocked/page")
        #expect(rule.evaluate(prefix) != nil)
        #expect(rule.evaluate(TestSupport.input("https://example.test/unblocked/page")) == nil)
        #expect(rule.evaluate(TestSupport.input("https://sub.testsafebrowsing.appspot.com/s/phishing.html")) != nil)
    }

    // MARK: D

    @Test func d01d02d03() {
        func info(days: Int?, failed: Bool = false) -> DomainInfo {
            DomainInfo(registrableDomain: "example.test", unicodeHost: "example.test",
                       registrationDate: days.map { TestSupport.daysAgo($0, from: now) }, lookupFailed: failed)
        }
        func eval(_ rule: some RiskRule, _ d: DomainInfo) -> RiskFinding? {
            rule.evaluate(TestSupport.input(snapshot: TestSupport.snapshot("https://example.test/", chain: nil, domainInfo: d), now: now))
        }
        #expect(eval(VeryNewDomainRule(), info(days: 3))?.points == 25)
        #expect(eval(VeryNewDomainRule(), info(days: 29))?.evidence["days"] == "29")
        #expect(eval(VeryNewDomainRule(), info(days: 30)) == nil)
        #expect(eval(RecentDomainRule(), info(days: 30))?.points == 10)
        #expect(eval(RecentDomainRule(), info(days: 180)) != nil)
        #expect(eval(RecentDomainRule(), info(days: 181)) == nil)
        #expect(eval(RecentDomainRule(), info(days: 10)) == nil)
        #expect(eval(VeryNewDomainRule(), info(days: 400)) == nil)
        #expect(eval(DomainAgeUnavailableRule(), info(days: nil, failed: true))?.points == 0)
        #expect(eval(DomainAgeUnavailableRule(), info(days: 50)) == nil)
        // 조회를 시도하지 않은 DomainInfo(등록일 nil, 실패 아님)에는 D 규칙이 적용되지 않는다.
        let untried = TestSupport.input(snapshot: TestSupport.snapshot("https://example.test/", chain: nil, domainInfo: info(days: nil)), now: now)
        #expect(!VeryNewDomainRule().isApplicable(untried) && !RecentDomainRule().isApplicable(untried) && !DomainAgeUnavailableRule().isApplicable(untried))
        #expect(!VeryNewDomainRule().isApplicable(TestSupport.input("https://example.test/")))
    }

    // MARK: H

    @Test func h01PasswordInput() {
        let rule = PasswordInputRule()
        let s = TestSupport.snapshot("https://example.test/login", chain: nil, page: PagePrecheckResult(hasPasswordInput: true))
        #expect(rule.evaluate(TestSupport.input(snapshot: s))?.points == 15)
        #expect(rule.evaluate(TestSupport.input(snapshot: s, prior: [RiskFinding(id: .B03, points: -20)])) == nil)
        let noPw = TestSupport.snapshot("https://example.test/login", chain: nil, page: PagePrecheckResult(hasPasswordInput: false))
        #expect(rule.evaluate(TestSupport.input(snapshot: noPw)) == nil)
        #expect(!rule.isApplicable(TestSupport.input("https://example.test/")))
    }

    @Test func h02CrossSiteForm() {
        let rule = CrossSiteFormRule()
        let cross = TestSupport.snapshot("https://example.test/login", chain: nil, page: PagePrecheckResult(formActionHosts: ["collect.evil.example.invalid"]))
        #expect(rule.evaluate(TestSupport.input(snapshot: cross))?.evidence["host"] == "collect.evil.example.invalid")
        let mixed = TestSupport.snapshot("https://example.test/login", chain: nil, page: PagePrecheckResult(formActionHosts: ["api.example.test", "evil.example.invalid"]))
        #expect(rule.evaluate(TestSupport.input(snapshot: mixed)) != nil)
        let same = TestSupport.snapshot("https://example.test/login", chain: nil, page: PagePrecheckResult(formActionHosts: ["api.example.test"]))
        #expect(rule.evaluate(TestSupport.input(snapshot: same)) == nil)
        let none = TestSupport.snapshot("https://example.test/login", chain: nil, page: PagePrecheckResult())
        #expect(rule.evaluate(TestSupport.input(snapshot: none)) == nil)
    }

    @Test func h03BrandLookalikePage() {
        let rule = BrandLookalikePageRule()
        let fake = TestSupport.snapshot("https://example.test/", chain: nil, page: PagePrecheckResult(title: "네이버 로그인"))
        #expect(rule.evaluate(TestSupport.input(snapshot: fake))?.evidence["brand"] == "네이버")
        let fakeEn = TestSupport.snapshot("https://example.test/", chain: nil, page: PagePrecheckResult(title: "Sign in", leadingText: "Welcome to KakaoTalk"))
        #expect(rule.evaluate(TestSupport.input(snapshot: fakeEn)) != nil)
        let real = TestSupport.snapshot("https://www.naver.com/", chain: nil, page: PagePrecheckResult(title: "네이버"))
        #expect(rule.evaluate(TestSupport.input(snapshot: real)) == nil)
        let unrelated = TestSupport.snapshot("https://example.test/", chain: nil, page: PagePrecheckResult(title: "Example Domain", leadingText: "This domain is for use in examples."))
        #expect(rule.evaluate(TestSupport.input(snapshot: unrelated)) == nil)
    }

    @Test func h05TLSFailure() {
        let rule = TLSFailureRule()
        let viaPage = TestSupport.snapshot("https://example.test/", chain: nil, page: PagePrecheckResult(tlsFailed: true))
        #expect(rule.evaluate(TestSupport.input(snapshot: viaPage))?.points == 30)
        let viaChain = TestSupport.snapshot("https://example.test/", chain: TestSupport.chain(["https://example.test/"], outcome: .tlsFailure))
        #expect(rule.isApplicable(TestSupport.input(snapshot: viaChain)))
        #expect(rule.evaluate(TestSupport.input(snapshot: viaChain)) != nil)
        let fine = TestSupport.snapshot("https://example.test/", chain: TestSupport.chain(["https://example.test/"]), page: PagePrecheckResult())
        #expect(rule.evaluate(TestSupport.input(snapshot: fine)) == nil)
        #expect(!rule.isApplicable(TestSupport.input("https://example.test/")))
    }

    // MARK: 엔진 통합(스냅샷 재채점)

    @Test func engineRescoresWithOnlineData() {
        // 스펙 2.1 예시 2: bit.ly → event-gift.site, D01
        let chain = TestSupport.chain(["https://bit.ly/3gH2kQ", "https://event-gift.site/coupon"])
        var s = TestSupport.snapshot("https://bit.ly/3gH2kQ", chain: chain)
        s.domainInfo = DomainInfo(registrableDomain: "event-gift.site", unicodeHost: "event-gift.site", registrationDate: TestSupport.daysAgo(5, from: now))
        s.coverage = .full
        let report = TestSupport.engine.report(snapshot: s, context: TestSupport.camera, now: now)
        let ids = TestSupport.ruleIDs(report)
        #expect(ids.contains(.U11) && ids.contains(.D01))
        #expect(!ids.contains(.R02))        // 처음이 단축 URL이라 제외
        #expect(!ids.contains(.U08))        // U08은 스캔한 URL(bit.ly) 기준
        #expect(report.score == 35)         // U11 10 + D01 25
        #expect(report.tier == .caution)
        #expect(report.finalURL?.host() == "event-gift.site")
        #expect(report.redirectChain.count == 2)
        #expect(report.domain?.registrableDomain == "event-gift.site")

        // 스펙 2.1 예시 3: t.ly → naver-login.account-check.xyz (메일) + 블록리스트 적중 대신 평판 적중
        let chain3 = TestSupport.chain(["https://t.ly/Ab3dE", "https://naver-login.account-check.xyz/verify"])
        var s3 = TestSupport.snapshot("https://t.ly/Ab3dE", chain: chain3)
        s3.reputation = [ReputationLookup(url: chain3.finalURL!, provider: "Google Safe Browsing", verdict: .malicious(threatTypes: ["SOCIAL_ENGINEERING"]))]
        s3.page = PagePrecheckResult(hasPasswordInput: true)
        let ctx = AnalysisContext(source: .camera, place: .emailOrMessage)
        let r3 = TestSupport.engine.report(snapshot: s3, context: ctx, now: now)
        let ids3 = TestSupport.ruleIDs(r3)
        #expect(ids3.isSuperset(of: [.T01, .B01, .H01, .C02, .U11]))
        #expect(r3.score >= 90 && r3.tier == .danger)
        #expect(r3.findings.first?.id == .T01)
    }
}
