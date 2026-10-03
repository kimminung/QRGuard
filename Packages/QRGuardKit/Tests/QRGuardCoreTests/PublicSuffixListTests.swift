import Foundation
import Testing
@testable import QRGuardCore

@Suite("PublicSuffixList (T-1.2)")
struct PublicSuffixListTests {
    /// publicsuffix.org 공식 테스트 케이스 발췌(ICANN·PRIVATE·와일드카드·예외·IDN·퓨니코드).
    static let officialCases: [(String, String?)] = [
        ("COM", nil), ("example.COM", "example.com"), ("WwW.example.COM", "example.com"), (".com", nil),
        ("example", nil), ("example.example", "example.example"), ("b.example.example", "example.example"),
        ("biz", nil), ("domain.biz", "domain.biz"), ("b.domain.biz", "domain.biz"),
        ("example.com", "example.com"), ("b.example.com", "example.com"), ("a.b.example.com", "example.com"),
        ("uk.com", nil), ("example.uk.com", "example.uk.com"), ("b.example.uk.com", "example.uk.com"),
        ("test.ac", "test.ac"),
        ("mm", nil), ("c.mm", nil), ("b.c.mm", "b.c.mm"), ("a.b.c.mm", "b.c.mm"),
        ("jp", nil), ("test.jp", "test.jp"), ("www.test.jp", "test.jp"), ("ac.jp", nil), ("test.ac.jp", "test.ac.jp"),
        ("www.test.ac.jp", "test.ac.jp"), ("kyoto.jp", nil), ("test.kyoto.jp", "test.kyoto.jp"),
        ("ide.kyoto.jp", nil), ("b.ide.kyoto.jp", "b.ide.kyoto.jp"), ("a.b.ide.kyoto.jp", "b.ide.kyoto.jp"),
        ("c.kobe.jp", nil), ("b.c.kobe.jp", "b.c.kobe.jp"), ("a.b.c.kobe.jp", "b.c.kobe.jp"),
        ("city.kobe.jp", "city.kobe.jp"), ("www.city.kobe.jp", "city.kobe.jp"),
        ("ck", nil), ("test.ck", nil), ("b.test.ck", "b.test.ck"), ("a.b.test.ck", "b.test.ck"),
        ("www.ck", "www.ck"), ("www.www.ck", "www.ck"),
        ("us", nil), ("test.us", "test.us"), ("www.test.us", "test.us"), ("ak.us", nil), ("test.ak.us", "test.ak.us"),
        ("www.test.ak.us", "test.ak.us"), ("k12.ak.us", nil), ("test.k12.ak.us", "test.k12.ak.us"),
        ("食狮.com.cn", "食狮.com.cn"), ("食狮.公司.cn", "食狮.公司.cn"), ("www.食狮.公司.cn", "食狮.公司.cn"),
        ("shishi.公司.cn", "shishi.公司.cn"), ("公司.cn", nil), ("食狮.中国", "食狮.中国"), ("www.食狮.中国", "食狮.中国"),
        ("shishi.中国", "shishi.中国"), ("中国", nil),
        ("xn--85x722f.com.cn", "xn--85x722f.com.cn"), ("xn--85x722f.xn--55qx5d.cn", "xn--85x722f.xn--55qx5d.cn"),
        ("www.xn--85x722f.xn--55qx5d.cn", "xn--85x722f.xn--55qx5d.cn"), ("shishi.xn--55qx5d.cn", "shishi.xn--55qx5d.cn"),
        ("xn--55qx5d.cn", nil), ("xn--85x722f.xn--fiqs8s", "xn--85x722f.xn--fiqs8s"), ("xn--fiqs8s", nil),
        // 한국·PRIVATE 섹션
        ("a.b.example.co.kr", "example.co.kr"), ("www.naver.com", "naver.com"), ("co.kr", nil),
        ("example.github.io", "example.github.io"), ("foo.blogspot.com", "foo.blogspot.com"), ("github.io", nil),
    ]

    @Test(arguments: officialCases)
    func registrableDomain(_ host: String, _ expected: String?) {
        #expect(PublicSuffixList.shared.registrableDomain(forHost: host) == expected, "host: \(host)")
    }

    @Test func publicSuffix() {
        let psl = PublicSuffixList.shared
        #expect(psl.publicSuffix(forHost: "a.b.example.co.kr") == "co.kr")
        #expect(psl.publicSuffix(forHost: "www.ck") == "ck")
        #expect(psl.publicSuffix(forHost: "a.b.c.kobe.jp") == "c.kobe.jp")
        #expect(psl.publicSuffix(forHost: "city.kobe.jp") == "kobe.jp")
        #expect(psl.publicSuffix(forHost: "example.github.io") == "github.io")
        #expect(psl.publicSuffix(forHost: "example.unknowntld") == "unknowntld")
        #expect(psl.publicSuffix(forHost: "") == nil)
    }

    @Test func trailingDotAndCase() {
        let psl = PublicSuffixList.shared
        #expect(psl.registrableDomain(forHost: "WWW.Example.CO.KR.") == "example.co.kr")
    }

    @Test func customRulesWithWildcardAndException() {
        let psl = PublicSuffixList(rules: ["// comment", "", "foo", "*.bar", "!baz.bar", "  ", "qux.foo  // trailing"])
        #expect(psl.registrableDomain(forHost: "a.foo") == "a.foo")
        #expect(psl.registrableDomain(forHost: "a.qux.foo") == "a.qux.foo")
        #expect(psl.registrableDomain(forHost: "x.bar") == nil)
        #expect(psl.registrableDomain(forHost: "y.x.bar") == "y.x.bar")
        #expect(psl.registrableDomain(forHost: "baz.bar") == "baz.bar")
        #expect(psl.registrableDomain(forHost: "w.baz.bar") == "baz.bar")
    }

    @Test func emptyRulesFallBackToTwoLabels() {
        let psl = PublicSuffixList(rules: [])
        #expect(psl.isEmpty)
        #expect(psl.registrableDomain(forHost: "a.b.example.co.kr") == "co.kr")
        #expect(psl.registrableDomain(forHost: "localhost") == nil)
    }

    @Test func registrableDomainHelperSkipsIPs() {
        #expect(RegistrableDomain.from(host: "a.b.example.co.kr") == "example.co.kr")
        #expect(RegistrableDomain.from(host: "192.168.0.1") == nil)
        #expect(RegistrableDomain.from(host: "[::1]") == nil)
        #expect(RegistrableDomain.sameSite("www.example.com", "m.example.com"))
        #expect(!RegistrableDomain.sameSite("example.com", "example.org"))
    }

    @Test func lookupIsFast() {
        let psl = PublicSuffixList.shared
        _ = psl.registrableDomain(forHost: "warm.up.example.co.kr")
        let hosts = ["a.b.example.co.kr", "www.city.kobe.jp", "foo.blogspot.com", "deep.sub.domain.example.com", "x.y.z.test.ck"]
        let start = ContinuousClock.now
        for _ in 0..<2_000 { for h in hosts { _ = psl.registrableDomain(forHost: h) } }
        let elapsed = ContinuousClock.now - start
        // 10,000회 조회 — 넉넉히 0.5초 이내(회당 수십 μs 이하)
        #expect(elapsed < .milliseconds(500), "10k lookups took \(elapsed)")
    }
}
