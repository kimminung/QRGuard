import Foundation
import Testing
import QRGuardCore
@testable import QRGuardNetwork

@Suite("RedirectResolver (T-4.1)")
struct RedirectResolverTests {
    private func makeResolver(timeout: TimeInterval = 3) -> RedirectResolver {
        RedirectResolver(configuration: mockConfiguration(requestTimeout: timeout))
    }

    @Test("301/302/303/307/308 체인을 홉마다 기록하고 최종 Content-Type을 잡는다")
    func followsAllRedirectCodes() async {
        let host = MockHost("redir-codes")
        host.stub("/a", .redirect(301, to: "/b"))
        host.stub("/b", .redirect(302, to: "https://redir-codes.example.test/c"))
        host.stub("/c", .redirect(307, to: "/d"))
        host.stub("/d", .redirect(308, to: "/e"))
        host.stub("/e", .redirect(303, to: "/final"))
        host.stub("/final", .status(200, contentType: "Text/HTML; charset=UTF-8"))

        let chain = await makeResolver().resolve(host.url("/a"))

        #expect(chain.outcome == .completed)
        #expect(chain.hops.map(\.statusCode) == [301, 302, 307, 308, 303, 200])
        #expect(chain.hops.map(\.url.path) == ["/a", "/b", "/c", "/d", "/e", "/final"])
        #expect(chain.hops.map(\.order) == Array(0..<6))
        #expect(chain.redirectCount == 5)
        #expect(chain.finalURL == host.url("/final"))
        #expect(chain.finalContentType == "text/html; charset=utf-8")
        #expect(chain.finalStatusCode == 200)
        #expect(host.requests.allSatisfy { $0.method == "HEAD" })
        #expect(host.requests.allSatisfy { $0.headers["User-Agent"] == HardenedSession.mobileSafariUserAgent })
    }

    @Test("A→B→A 루프 감지")
    func detectsLoop() async {
        let host = MockHost("redir-loop")
        host.stub("/a", .redirect(302, to: "/b"))
        host.stub("/b", .redirect(302, to: "/a"))

        let chain = await makeResolver().resolve(host.url("/a"))

        #expect(chain.outcome == .loopDetected)
        #expect(chain.hops.count == 3)
        #expect(chain.hops.last?.statusCode == nil)
        #expect(host.requests.count == 2)
    }

    @Test("11홉 체인은 10번째 리다이렉트까지만 기록하고 tooManyHops")
    func stopsAtMaxHops() async {
        let host = MockHost("redir-many")
        for i in 0..<11 {
            host.stub("/\(i)", .redirect(302, to: "/\(i + 1)"))
        }
        host.stub("/11", .status(200, contentType: "text/html"))

        let chain = await makeResolver().resolve(host.url("/0"), maxHops: 10)

        #expect(chain.outcome == .tooManyHops)
        #expect(chain.redirectCount == 10)
        #expect(chain.hops.count == 11)
        #expect(chain.hops.last?.statusCode == 302)
        #expect(host.requests.count == 11)
        #expect(chain.finalContentType == nil)
    }

    @Test("HTTPS→HTTP 홉은 접속하지 않고 기록만 한다")
    func stopsAtInsecureHop() async {
        let host = MockHost("redir-down")
        let insecure = "http://insecure-down.example.test/x"
        host.stub("/start", .redirect(302, to: insecure))

        let chain = await makeResolver().resolve(host.url("/start"))

        #expect(chain.outcome == .stoppedAtInsecureHop)
        #expect(chain.hops.count == 2)
        #expect(chain.hops[1].url.absoluteString == insecure)
        #expect(chain.hops[1].statusCode == nil)
        #expect(MockURLProtocol.registry.requests(host: "insecure-down.example.test").isEmpty)
    }

    @Test("처음부터 http:// 주소면 요청 없이 종료")
    func insecureOriginalURL() async {
        let url = URL(string: "http://plain-http.example.test/")!
        let chain = await makeResolver().resolve(url)
        #expect(chain.outcome == .stoppedAtInsecureHop)
        #expect(chain.hops.count == 1)
        #expect(MockURLProtocol.registry.requests(host: "plain-http.example.test").isEmpty)
    }

    @Test("사설 IP 대상은 요청하지 않는다")
    func blocksPrivateAddress() async {
        let host = MockHost("redir-private")
        host.stub("/p", .redirect(302, to: "https://192.168.0.1/admin"))

        let chain = await makeResolver().resolve(host.url("/p"))

        #expect(chain.outcome == .blockedPrivateAddress)
        #expect(chain.hops.count == 2)
        #expect(chain.hops[1].statusCode == nil)
        #expect(MockURLProtocol.registry.requests(host: "192.168.0.1").isEmpty)

        let direct = await makeResolver().resolve(URL(string: "https://127.0.0.1/")!)
        #expect(direct.outcome == .blockedPrivateAddress)
        #expect(direct.hops.count == 1)
        #expect(MockURLProtocol.registry.requests(host: "127.0.0.1").isEmpty)
    }

    @Test("사설·로컬 호스트 판별", arguments: [
        ("127.0.0.1", true), ("10.1.2.3", true), ("172.16.0.1", true), ("172.31.255.255", true), ("172.32.0.1", false),
        ("192.168.1.1", true), ("169.254.169.254", true), ("100.64.0.1", true), ("0.0.0.0", true),
        ("2130706433", true), ("0x7f000001", true), ("0177.0.0.1", true), ("::1", true), ("[::1]", true),
        ("fe80::1", true), ("fd12::1", true), ("::ffff:10.0.0.1", true), ("2606:4700::1111", false),
        ("localhost", true), ("LOCALHOST.", true), ("printer.local", true), ("db.internal", true), ("router.home.arpa", true),
        ("intranet", true), ("example.com", false), ("www.example.test", false), ("93.184.216.34", false), ("8.8.8.8", false),
    ])
    func privateHostDetection(host: String, expected: Bool) {
        #expect(RedirectResolver.isPrivateOrLocal(host: host) == expected, "\(host)")
    }

    @Test("HEAD 405 → GET Range 재시도")
    func retriesWithGETAfter405() async {
        let host = MockHost("redir-head405")
        host.stub("/doc") { request in
            request.httpMethod == "HEAD" ? .status(405) : .status(200, contentType: "application/pdf")
        }

        let chain = await makeResolver().resolve(host.url("/doc"))

        #expect(chain.outcome == .completed)
        #expect(chain.finalStatusCode == 200)
        #expect(chain.finalContentType == "application/pdf")
        #expect(host.requests.map(\.method) == ["HEAD", "GET"])
        #expect(host.requests.last?.headers["Range"] == "bytes=0-0")
    }

    @Test("Location 없는 3xx HEAD는 GET으로 다시 묻는다")
    func retriesWhenHEADHasNoLocation() async {
        let host = MockHost("redir-noloc")
        host.stub("/x") { request in
            request.httpMethod == "HEAD" ? .status(302) : .redirect(302, to: "/y")
        }
        host.stub("/y", .status(200, contentType: "text/html"))

        let chain = await makeResolver().resolve(host.url("/x"))

        #expect(chain.outcome == .completed)
        #expect(chain.hops.map(\.url.path) == ["/x", "/y"])
        #expect(host.requests.map(\.method) == ["HEAD", "GET", "HEAD"])
    }

    @Test("응답이 없으면 예산 안에 timedOut")
    func timesOut() async {
        let host = MockHost("redir-hang")
        host.stubAll(.hanging)
        let clock = ContinuousClock()
        let start = clock.now

        let chain = await makeResolver(timeout: 1).resolve(host.url("/slow"), perHopTimeout: .milliseconds(500), totalTimeout: .seconds(1))

        #expect(chain.outcome == .timedOut)
        #expect(chain.hops.count == 1)
        #expect(chain.hops[0].statusCode == nil)
        #expect(clock.now - start < .seconds(2))
    }

    @Test("전체 예산은 여러 홉에 걸쳐 적용된다")
    func totalTimeoutAcrossHops() async {
        let host = MockHost("redir-total")
        host.stub("/1", MockResponse(status: 302, headers: ["Location": "/2"], delay: 0.4))
        host.stub("/2", MockResponse(status: 302, headers: ["Location": "/3"], delay: 0.4))
        host.stub("/3", MockResponse(status: 302, headers: ["Location": "/4"], delay: 0.4))
        host.stub("/4", .status(200, contentType: "text/html"))
        let clock = ContinuousClock()
        let start = clock.now

        let chain = await makeResolver(timeout: 1).resolve(host.url("/1"), perHopTimeout: .seconds(1), totalTimeout: .seconds(1))

        #expect(chain.outcome == .timedOut)
        #expect(chain.hops.count >= 2)
        #expect(clock.now - start < .seconds(2.5))
    }

    @Test("TLS 오류는 tlsFailure")
    func tlsFailure() async {
        let host = MockHost("redir-tls")
        host.stubAll(.failing(.serverCertificateUntrusted))
        let chain = await makeResolver().resolve(host.url("/"))
        #expect(chain.outcome == .tlsFailure)
        #expect(chain.hops.count == 1)
    }

    @Test("기타 네트워크 오류는 failed")
    func genericFailure() async {
        let host = MockHost("redir-fail")
        host.stubAll(.failing(.cannotFindHost))
        let chain = await makeResolver().resolve(host.url("/"))
        if case .failed = chain.outcome {} else {
            Issue.record("expected .failed, got \(chain.outcome)")
        }
    }

    @Test("상대 Location·대소문자·프래그먼트 차이는 같은 주소로 본다")
    func normalizesVisitKeys() async {
        let host = MockHost("redir-key")
        host.stub("/a", .redirect(302, to: "/b#section"))
        host.stub("/b", .redirect(302, to: "https://REDIR-KEY.example.test/a"))

        let chain = await makeResolver().resolve(host.url("/a"))

        #expect(chain.outcome == .loopDetected)
        #expect(chain.hops.count == 3)
    }

    @Test("4xx/5xx 최종 응답도 completed로 기록")
    func recordsErrorStatusAsCompleted() async {
        let host = MockHost("redir-404")
        host.stub("/gone", .status(404, contentType: "text/html"))
        let chain = await makeResolver().resolve(host.url("/gone"))
        #expect(chain.outcome == .completed)
        #expect(chain.finalStatusCode == 404)
    }
}
