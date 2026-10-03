import Foundation
import Testing
import QRGuardCore
@testable import QRGuardNetwork

@Suite("PagePrecheck (T-4.6)")
struct PagePrecheckTests {
    private func serve(_ fixture: String, as name: String, contentType: String = "text/html; charset=utf-8", path: String = "/index.html", fixtureExtension: String = "html") throws -> (MockHost, URL) {
        let host = MockHost("page-\(name)")
        let data = try fixtureData(fixture, extension: fixtureExtension)
        host.stub(path, MockResponse(status: 200, headers: ["Content-Type": contentType], body: data))
        return (host, host.url(path))
    }

    private func precheck(_ url: URL, timeout: Duration = .seconds(3)) async throws -> PagePrecheckResult {
        try await PagePrecheck(configuration: mockConfiguration()).precheck(url, timeout: timeout)
    }

    @Test("비밀번호 입력란 + 같은 호스트 form")
    func loginPassword() async throws {
        let (host, url) = try serve("login_password", as: "login")
        let result = try await precheck(url)
        #expect(result.hasPasswordInput)
        #expect(result.formActionHosts == [host.host])
        #expect(result.title == "로그인")
        #expect(result.contentType == "text/html; charset=utf-8")
        #expect(result.bytesRead > 0)
        #expect(!result.tlsFailed)
        #expect(host.requests.first?.method == "GET")
        #expect(host.requests.first?.headers["User-Agent"] == HardenedSession.mobileSafariUserAgent)
    }

    @Test("외부 호스트로 전송하는 form action")
    func externalForm() async throws {
        let (_, url) = try serve("external_form", as: "extform")
        let result = try await precheck(url)
        #expect(result.hasPasswordInput)
        #expect(result.formActionHosts.contains("collector.example.test"))
        #expect(result.formActionHosts.contains("plain-collector.example.test"))
        #expect(!result.formActionHosts.contains("page-extform.example.test"))
    }

    @Test("meta refresh 대상 추출")
    func metaRefresh() async throws {
        let (_, url) = try serve("meta_refresh", as: "meta")
        let result = try await precheck(url)
        #expect(result.metaRefreshTarget == URL(string: "https://landing.example.test/promo?id=7"))
        #expect(!result.hasPasswordInput)
    }

    @Test("meta refresh 변형: 속성 순서·대문자 URL=·따옴표·상대 경로, 첫 번째만 채택")
    func metaRefreshVariants() async throws {
        let (host, url) = try serve("meta_refresh_variants", as: "metavar")
        let result = try await precheck(url)
        #expect(result.metaRefreshTarget == host.url("/next/step"))
    }

    @Test("브랜드 제목·로고 alt·본문 상단 텍스트")
    func brandTitle() async throws {
        let (_, url) = try serve("brand_title", as: "brand")
        let result = try await precheck(url)
        #expect(result.title == "카카오톡 로그인 | 계정 확인")
        #expect(result.leadingText.contains("KakaoTalk 로고"))
        #expect(result.leadingText.contains("계정을 확인"))
        #expect(result.leadingText.count <= 2048)
    }

    @Test("평범한 글: 발견 없음, 본문 텍스트만")
    func plainArticle() async throws {
        let (_, url) = try serve("plain_article", as: "plain")
        let result = try await precheck(url)
        #expect(!result.hasPasswordInput)
        #expect(result.formActionHosts.isEmpty)
        #expect(result.metaRefreshTarget == nil)
        #expect(result.title == "오늘의 날씨")
        #expect(result.leadingText.contains("맑음"))
        #expect(!result.leadingText.contains("console.log"))
        #expect(!result.leadingText.contains("color:"))
    }

    @Test("대문자·따옴표 없는 속성")
    func uppercaseAttributes() async throws {
        let (_, url) = try serve("uppercase_attrs", as: "upper")
        let result = try await precheck(url)
        #expect(result.hasPasswordInput)
        #expect(result.formActionHosts == ["x.example.test"])
        #expect(result.title == "SIGN IN")
    }

    @Test("script/style/head 내용은 본문 텍스트에서 제외")
    func scriptsAndStyles() async throws {
        let (_, url) = try serve("scripts_and_styles", as: "scripts")
        let result = try await precheck(url)
        #expect(result.leadingText.hasPrefix("환영합니다"))
        #expect(!result.leadingText.contains("function"))
        #expect(!result.leadingText.contains("background"))
        #expect(!result.leadingText.contains("description"))
    }

    @Test("엔티티·줄바꿈이 섞인 제목과 alt")
    func entitiesAndWhitespace() async throws {
        let (_, url) = try serve("entities_whitespace", as: "entities")
        let result = try await precheck(url)
        #expect(result.title == "Tom & Jerry's — 공식 스토어")
        #expect(result.leadingText.contains("<Brand> 로고"))
    }

    @Test("XHTML(application/xhtml+xml) 자기 닫힘 태그")
    func xhtmlSelfClosing() async throws {
        let (_, url) = try serve("xhtml_self_closing", as: "xhtml", contentType: "application/xhtml+xml")
        let result = try await precheck(url)
        #expect(result.hasPasswordInput)
        #expect(result.formActionHosts == ["auth.example.test"])
        #expect(result.contentType == "application/xhtml+xml")
    }

    @Test("주석 안의 password input도 보수적으로 발견으로 본다")
    func passwordInComment() async throws {
        let (_, url) = try serve("password_in_comment", as: "comment")
        let result = try await precheck(url)
        #expect(result.hasPasswordInput)
        #expect(!result.leadingText.contains("숨김"))
    }

    @Test("HTML이 아닌 Content-Type은 본문을 받지 않고 타입만 기록")
    func nonHTMLContent() async throws {
        let (host, url) = try serve("not_html", as: "apk", contentType: "application/vnd.android.package-archive", fixtureExtension: "txt")
        let result = try await precheck(url)
        #expect(result.contentType == "application/vnd.android.package-archive")
        #expect(result.bytesRead == 0)
        #expect(!result.hasPasswordInput)
        #expect(result.leadingText.isEmpty)
        #expect(result.title == nil)
        #expect(host.requests.count == 1)
    }

    @Test("256KB에서 끊는다")
    func truncatesAt256KB() async throws {
        let host = MockHost("page-huge")
        var html = "<!doctype html><html><head><title>Huge</title></head><body>"
        let filler = String(repeating: "<p>채움 텍스트 filler text</p>\n", count: 1)
        while html.utf8.count < 300_000 { html += filler }
        html += "<form action=\"https://late.example.test/x\"><input type=\"password\"></form></body></html>"
        host.stub("/big", .html(html))

        let result = try await precheck(host.url("/big"))

        #expect(result.bytesRead == PagePrecheck.defaultMaxBytes)
        #expect(result.title == "Huge")
        #expect(!result.hasPasswordInput)
        #expect(result.formActionHosts.isEmpty)
        #expect(result.leadingText.count <= 2048)
    }

    @Test("TLS 실패는 tlsFailed")
    func tlsFailure() async throws {
        let host = MockHost("page-tls")
        host.stubAll(.failing(.serverCertificateHasUnknownRoot))
        let result = try await precheck(host.url("/"))
        #expect(result.tlsFailed)
        #expect(result.bytesRead == 0)
    }

    @Test("http:// 와 사설 주소는 요청하지 않는다")
    func refusesInsecureTargets() async {
        let checker = PagePrecheck(configuration: mockConfiguration())
        await #expect(throws: (any Error).self) {
            _ = try await checker.precheck(URL(string: "http://page-insecure.example.test/")!, timeout: .seconds(1))
        }
        await #expect(throws: (any Error).self) {
            _ = try await checker.precheck(URL(string: "https://10.0.0.5/")!, timeout: .seconds(1))
        }
        #expect(MockURLProtocol.registry.requests(host: "page-insecure.example.test").isEmpty)
        #expect(MockURLProtocol.registry.requests(host: "10.0.0.5").isEmpty)
    }

    @Test("응답이 없으면 TimeoutError")
    func timesOut() async {
        let host = MockHost("page-hang")
        host.stubAll(.hanging)
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: TimeoutError.self) {
            _ = try await PagePrecheck(configuration: mockConfiguration(requestTimeout: 1)).precheck(host.url("/"), timeout: .milliseconds(400))
        }
        #expect(clock.now - start < .seconds(2))
    }

    @Test("HTMLScanner 단위: meta refresh content 파싱", arguments: [
        ("0; url=https://a.example.test/", "https://a.example.test/"),
        ("5;URL='https://b.example.test/x'", "https://b.example.test/x"),
        ("0; url = \"/rel\"", "https://page.example.test/rel"),
        ("3, https://c.example.test/", "https://c.example.test/"),
        ("10", nil),
        ("0; url=", nil),
    ])
    func metaRefreshParsing(content: String, expected: String?) {
        let page = URL(string: "https://page.example.test/dir/index.html")!
        #expect(HTMLScanner.parseMetaRefresh(content, relativeTo: page)?.absoluteString == expected)
    }
}
