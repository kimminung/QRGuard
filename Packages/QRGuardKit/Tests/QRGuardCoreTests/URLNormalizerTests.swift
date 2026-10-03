import Foundation
import Testing
@testable import QRGuardCore

@Suite("URLNormalizer (T-1.3)")
struct URLNormalizerTests {
    private func n(_ s: String) -> NormalizedURL {
        guard let r = TestSupport.normalized(s) else { Issue.record("normalize failed: \(s)"); fatalError() }
        return r
    }

    @Test func lowercasesHostAndStripsTrailingDot() {
        let r = n("HTTPS://WWW.Example.COM./Path?Q=1")
        #expect(r.scheme == "https")
        #expect(r.host == "www.example.com")
        #expect(r.path == "/Path")
        #expect(r.registrableDomain == "example.com")
        #expect(r.hostLabels == ["www", "example", "com"])
        #expect(r.normalized.absoluteString == "https://www.example.com/Path?Q=1")
    }

    @Test func dropsDefaultPortsKeepsOthers() {
        #expect(n("https://example.com:443/").port == nil)
        #expect(n("http://example.com:80/").port == nil)
        #expect(n("https://example.com:8443/").port == 8443)
        #expect(n("http://example.com:443/").port == 443)
    }

    @Test func separatesFragment() {
        let r = n("https://example.com/a?b=1#frag")
        #expect(r.fragment == "frag")
        #expect(r.query == "b=1")
        #expect(r.normalized.fragment == nil)
    }

    @Test func userInfo() {
        let r = n("https://naver.com@evil.example/verify")
        #expect(r.userInfo == "naver.com")
        #expect(r.host == "evil.example")
        #expect(n("https://user:pw@example.com/").userInfo == "user:pw")
        #expect(n("https://example.com/").userInfo == nil)
    }

    @Test func percentEncodingRatio() {
        let r = n("https://example.com/%2e%2e%2f%61%64")
        #expect(r.percentEncodedRatio > 0.9)
        #expect(n("https://example.com/plain/path").percentEncodedRatio == 0)
        #expect(n("https://example.com/a%20b").percentEncodedRatio > 0.3)
        // UTF-8 다중 바이트(한글) 인코딩은 세지 않는다.
        #expect(n("https://example.com/%ED%83%9D%EB%B0%B0").percentEncodedRatio == 0)
    }

    @Test func doubleEncoding() {
        #expect(n("https://example.com/%252e%252e/x").hasDoubleEncoding)
        #expect(n("https://example.com/?u=%25252F").hasDoubleEncoding)
        #expect(!n("https://example.com/%2e%2e/x").hasDoubleEncoding)
        #expect(!n("https://example.com/100%25").hasDoubleEncoding)
    }

    @Test(arguments: [
        ("http://127.0.0.1/", "127.0.0.1"),
        ("http://0x7f.1/", "0x7f.1"),
        ("http://2130706433/", "2130706433"),
        ("http://127.1/", "127.1"),
        ("http://0177.0.0.1/", "0177.0.0.1"),
        ("http://[::1]:8080/", "[::1]"),
        ("http://[2001:db8::1]/", "[2001:db8::1]"),
    ])
    func ipLiterals(_ s: String, _ host: String) {
        let r = n(s)
        #expect(r.isIPAddress, Comment(rawValue: s))
        #expect(r.host == host)
        #expect(r.registrableDomain == nil)
    }

    @Test func ipv4Canonicalization() {
        #expect(IPAddressParser.canonicalIPv4("0x7f.1") == "127.0.0.1")
        #expect(IPAddressParser.canonicalIPv4("2130706433") == "127.0.0.1")
        #expect(IPAddressParser.canonicalIPv4("127.1") == "127.0.0.1")
        #expect(IPAddressParser.canonicalIPv4("0177.0.0.1") == "127.0.0.1")
        #expect(IPAddressParser.canonicalIPv4("192.168.1.300") == nil)
        #expect(IPAddressParser.canonicalIPv4("example.com") == nil)
        #expect(IPAddressParser.canonicalIPv4("1.2.3.4.5") == nil)
    }

    @Test func notIP() {
        #expect(!n("https://example.com/").isIPAddress)
        #expect(!n("https://1password.example/").isIPAddress)
        #expect(!n("https://123.example.com/").isIPAddress)
    }

    @Test func punycodeDecodesToUnicodeHost() {
        let r = n("https://xn--80ak6aa92e.com/")
        #expect(r.isIDN)
        #expect(r.host == "xn--80ak6aa92e.com")
        #expect(r.unicodeHost == "аррӏе.com")
        #expect(r.scripts == [.cyrillic, .latin])   // TLD 'com'은 라틴
        #expect(!r.hasMixedScript)                   // TLD를 뺀 라벨은 순수 키릴 → 혼합 아님(B02 담당)
        #expect(n("https://www.xn--80ak6aa92e.com/").hasMixedScript) // www(라틴) + 키릴 라벨
        #expect(r.registrableDomain == "xn--80ak6aa92e.com")
    }

    @Test func rawUnicodeHostIsEncoded() {
        let r = n("https://한국.test/경로?q=값")
        #expect(r.host == "xn--3e0b707e.test")
        #expect(r.unicodeHost == "한국.test")
        #expect(r.isIDN)
        #expect(r.scripts == [.hangul, .latin])
        #expect(!r.hasMixedScript) // 라틴+한글은 혼동 체계가 아니고 라벨도 분리돼 있음
        #expect(r.queryItems.first?.value == "값")
    }

    @Test func mixedScriptDetection() {
        let r = n("https://xn--nver-53d.test/")   // nаver (키릴 а)
        #expect(r.isIDN)
        #expect(r.unicodeHost == "nаver.test")
        #expect(r.hasMixedScript)
        #expect(r.scripts.contains(.cyrillic) && r.scripts.contains(.latin))

        let greek = n("https://xn--mxail5aa.test/") // 전부 그리스 문자 하나의 라벨
        #expect(!greek.hasMixedScript || greek.scripts.count > 1)
    }

    @Test func queryItemsAreDecoded() {
        let r = n("https://a.test/?next=https%3A%2F%2Fevil.test%2Flogin&u=%25252F&empty=")
        #expect(r.queryItems.first { $0.name == "next" }?.value == "https://evil.test/login")
        #expect(r.queryItems.first { $0.name == "u" }?.value == "%252F")
        #expect(r.queryItems.contains { $0.name == "empty" })
    }

    @Test func pathExtensionAndSubdomainDepth() {
        #expect(n("https://example.com/files/app.APK").pathExtension == "apk")
        #expect(n("https://example.com/files/").pathExtension == nil)
        #expect(n("https://example.com/.hidden").pathExtension == nil)
        #expect(n("https://a.b.c.d.example.co.kr/").subdomainDepth == 4)
        #expect(n("https://www.example.com/").subdomainDepth == 1)
        #expect(n("https://example.com/").subdomainDepth == 0)
    }

    @Test func nonWebSchemes() {
        let js = n("javascript:alert(1)")
        #expect(js.scheme == "javascript")
        #expect(js.host == "")
        #expect(!js.isWeb)
        let app = n("kakaotalk://open")
        #expect(app.scheme == "kakaotalk")
        #expect(app.host == "open")
        #expect(app.registrableDomain == nil)
    }

    @Test func lengthCountsOriginal() {
        let long = "https://example.com/" + String(repeating: "a", count: 250)
        #expect(n(long).length == long.count)
    }

    @Test func customDataStoreWithoutPSLFallsBack() {
        let r = URLNormalizer.normalize(URL(string: "https://a.b.example.co.kr/")!, data: .empty)
        #expect(r?.registrableDomain == "co.kr")
    }

    @Test func normalizeStringTrimsWhitespace() {
        #expect(URLNormalizer.normalize(string: "  https://example.com/x \n")?.host == "example.com")
        #expect(URLNormalizer.normalize(string: "not a url at all") == nil)
    }
}
