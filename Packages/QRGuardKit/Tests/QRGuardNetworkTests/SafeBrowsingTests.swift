import CryptoKit
import Foundation
import Testing
import QRGuardCore
@testable import QRGuardNetwork

@Suite("Safe Browsing 정규화 (T-4.3)")
struct SafeBrowsingCanonicalizerTests {
    @Test("명세 예제", arguments: [
        ("http://host/%25%32%35", "http://host/%25"),
        ("http://host/%25%32%35%25%32%35", "http://host/%25%25"),
        ("http://host/%2525252525252525", "http://host/%25"),
        ("http://host/asdf%25%32%35asd", "http://host/asdf%25asd"),
        ("http://host/%%%25%32%35asd%%", "http://host/%25%25%25asd%25%25"),
        ("http://www.google.com/", "http://www.google.com/"),
        ("http://%31%36%38%2e%31%38%38%2e%39%39%2e%32%36/%2E%73%65%63%75%72%65/%77%77%77%2E%65%62%61%79%2E%63%6F%6D/", "http://168.188.99.26/.secure/www.ebay.com/"),
        ("http://195.127.0.11/uploads/%20%20%20%20/.verify/.eBaysecure=updateuserdataxplimnbqmn-xplmvalidateinfoswqpcmlx=hgplmcx/", "http://195.127.0.11/uploads/%20%20%20%20/.verify/.eBaysecure=updateuserdataxplimnbqmn-xplmvalidateinfoswqpcmlx=hgplmcx/"),
        ("http://3279880203/blah", "http://195.127.0.11/blah"),
        ("http://www.google.com/blah/..", "http://www.google.com/"),
        ("www.google.com/", "http://www.google.com/"),
        ("www.google.com", "http://www.google.com/"),
        ("http://www.evil.com/blah#frag", "http://www.evil.com/blah"),
        ("http://www.GOOgle.com/", "http://www.google.com/"),
        ("http://www.google.com.../", "http://www.google.com/"),
        ("http://www.google.com/foo\tbar\rbaz\n2", "http://www.google.com/foobarbaz2"),
        ("http://www.google.com/q?", "http://www.google.com/q?"),
        ("http://www.google.com/q?r?", "http://www.google.com/q?r?"),
        ("http://www.google.com/q?r?s", "http://www.google.com/q?r?s"),
        ("http://evil.com/foo#bar#baz", "http://evil.com/foo"),
        ("http://evil.com/foo;", "http://evil.com/foo;"),
        ("http://evil.com/foo?bar;", "http://evil.com/foo?bar;"),
        ("http://%01%80.com/", "http://%01%80.com/"),
        ("http://\u{01}.com/", "http://%01.com/"),
        ("http://notrailingslash.com", "http://notrailingslash.com/"),
        ("http://www.gotaport.com:1234/", "http://www.gotaport.com/"),
        ("  http://www.google.com/  ", "http://www.google.com/"),
        ("http:// leadingspace.com/", "http://%20leadingspace.com/"),
        ("http://%20leadingspace.com/", "http://%20leadingspace.com/"),
        ("%20leadingspace.com/", "http://%20leadingspace.com/"),
        ("https://www.securesite.com/", "https://www.securesite.com/"),
        ("http://host.com/ab%23cd", "http://host.com/ab%23cd"),
        ("http://host.com//twoslashes?more//slashes", "http://host.com/twoslashes?more//slashes"),
        ("http://www.google.com/a/../b/./c", "http://www.google.com/b/c"),
        ("http://user:pass@www.example.com:443/x", "http://www.example.com/x"),
        ("http://0x7f.0.0.1/", "http://127.0.0.1/"),
        ("http://0177.0.0.1/", "http://127.0.0.1/"),
        ("http://1.2.3/", "http://1.2.0.3/"),
    ])
    func canonicalizes(input: String, expected: String) {
        #expect(SafeBrowsingCanonicalizer.canonicalize(input) == expected, "\(input)")
    }

    @Test("표현식: a.b.c/1/2.html?param=1")
    func expressionsForPathWithQuery() {
        let expected = [
            "a.b.c/1/2.html?param=1", "a.b.c/1/2.html", "a.b.c/", "a.b.c/1/",
            "b.c/1/2.html?param=1", "b.c/1/2.html", "b.c/", "b.c/1/",
        ]
        #expect(SafeBrowsingCanonicalizer.expressions(for: "http://a.b.c/1/2.html?param=1") == expected)
    }

    @Test("표현식: 호스트 접미사는 마지막 5개까지")
    func expressionsForDeepHost() {
        let expected = [
            "a.b.c.d.e.f.g/1.html", "a.b.c.d.e.f.g/",
            "c.d.e.f.g/1.html", "c.d.e.f.g/",
            "d.e.f.g/1.html", "d.e.f.g/",
            "e.f.g/1.html", "e.f.g/",
            "f.g/1.html", "f.g/",
        ]
        #expect(SafeBrowsingCanonicalizer.expressions(for: "http://a.b.c.d.e.f.g/1.html") == expected)
    }

    @Test("표현식: 경로 접두사는 최대 4개, IP는 접미사 없음")
    func expressionsLimits() {
        let deep = SafeBrowsingCanonicalizer.expressions(for: "http://x.y/1/2/3/4/5/6.html")
        #expect(deep == ["x.y/1/2/3/4/5/6.html", "x.y/", "x.y/1/", "x.y/1/2/", "x.y/1/2/3/"])
        let ip = SafeBrowsingCanonicalizer.expressions(for: "http://1.2.3.4/a/b")
        #expect(ip == ["1.2.3.4/a/b", "1.2.3.4/", "1.2.3.4/a/"])
        #expect(SafeBrowsingCanonicalizer.expressions(for: "http://host.test/") == ["host.test/"])
    }
}

@Suite("SafeBrowsingV5Provider (T-4.3)")
struct SafeBrowsingProviderTests {
    private func fullHashBase64(_ expression: String) -> String {
        Data(SHA256.hash(data: Data(expression.utf8))).base64EncodedString()
    }

    @Test("전체 해시가 일치하면 malicious, 아니면 clean · 원문은 전송하지 않는다")
    func hitAndMiss() async throws {
        let api = MockHost("sb-hit")
        let evilHash = fullHashBase64("evil-site.example.test/login/")
        api.stub("/v5/hashes:search", .json("""
        {"fullHashes":[{"fullHash":"\(evilHash)","fullHashDetails":[{"threatType":"SOCIAL_ENGINEERING","attributes":[]}]}],"cacheDuration":"300s"}
        """))
        let provider = SafeBrowsingV5Provider(apiKey: "test-key", session: mockSession(), endpoint: api.url("/v5/hashes:search"))
        #expect(provider.isAvailable)

        let evil = URL(string: "https://evil-site.example.test/login/index.php?x=1")!
        let clean = URL(string: "https://clean-site.example.test/")!
        let verdicts = try await provider.lookup([evil, clean])

        #expect(verdicts[evil] == .malicious(threatTypes: ["SOCIAL_ENGINEERING"]))
        #expect(verdicts[clean] == .clean)

        let request = try #require(api.requests.first)
        #expect(request.method == "GET")
        let query = request.url.query ?? ""
        #expect(query.hasPrefix("key=test-key&hashPrefixes="))
        #expect(!query.contains("evil-site"))
        #expect(!query.contains("clean-site"))
        let prefixes = query.split(separator: "&").filter { $0.hasPrefix("hashPrefixes=") }
        let expectedCount = Set((SafeBrowsingV5Provider.fullHashes(for: evil) + SafeBrowsingV5Provider.fullHashes(for: clean)).map { $0.prefix(4) }).count
        #expect(prefixes.count == expectedCount)
        // 각 프리픽스는 4바이트 base64(6글자, 패딩 2개) → 쿼리 안전 인코딩
        #expect(prefixes.allSatisfy { $0.hasSuffix("%3D%3D") })
    }

    @Test("빈 응답은 모두 clean")
    func miss() async throws {
        let api = MockHost("sb-miss")
        api.stub("/v5/hashes:search", .json("{}"))
        let provider = SafeBrowsingV5Provider(apiKey: "k", session: mockSession(), endpoint: api.url("/v5/hashes:search"))
        let url = URL(string: "https://nothing.example.test/path")!
        let verdicts = try await provider.lookup([url])
        #expect(verdicts[url] == .clean)
        #expect(api.requests.count == 1)
    }

    @Test("키가 없으면 비활성이고 요청을 보내지 않는다")
    func unavailableWithoutKey() async {
        let api = MockHost("sb-nokey")
        api.stub("/v5/hashes:search", .json("{}"))
        for key in [nil, "", "   "] {
            let provider = SafeBrowsingV5Provider(apiKey: key, session: mockSession(), endpoint: api.url("/v5/hashes:search"))
            #expect(!provider.isAvailable)
            await #expect(throws: ReputationProviderError.unavailable) {
                _ = try await provider.lookup([URL(string: "https://x.example.test/")!])
            }
        }
        #expect(api.requests.isEmpty)
    }

    @Test("4xx/5xx 또는 깨진 JSON은 throw")
    func serverErrors() async {
        let api = MockHost("sb-err")
        api.stub("/v5/hashes:search", .json("{\"error\":{}}", status: 403))
        let provider = SafeBrowsingV5Provider(apiKey: "k", session: mockSession(), endpoint: api.url("/v5/hashes:search"))
        await #expect(throws: ReputationProviderError.httpStatus(403)) {
            _ = try await provider.lookup([URL(string: "https://x.example.test/")!])
        }

        let broken = MockHost("sb-broken")
        broken.stub("/v5/hashes:search", .json("not json"))
        let provider2 = SafeBrowsingV5Provider(apiKey: "k", session: mockSession(), endpoint: broken.url("/v5/hashes:search"))
        await #expect(throws: ReputationProviderError.invalidResponse) {
            _ = try await provider2.lookup([URL(string: "https://x.example.test/")!])
        }
    }
}

@Suite("URLhausProvider (T-4.8)")
struct URLhausProviderTests {
    @Test("ok → malicious, no_results → clean, Auth-Key 헤더와 원문 전송")
    func verdicts() async throws {
        let api = MockHost("urlhaus-ok")
        api.stub("/v1/url/") { request in
            let body = String(decoding: MockRegistryBodyReader.body(of: request), as: UTF8.self)
            if body.contains("bad-host") {
                return .json(#"{"query_status":"ok","threat":"malware_download","url_status":"online"}"#)
            }
            return .json(#"{"query_status":"no_results"}"#)
        }
        let provider = URLhausProvider(authKey: "abc123", enabled: true, session: mockSession(), endpoint: api.url("/v1/url/"))
        #expect(provider.isAvailable)

        let bad = URL(string: "https://bad-host.example.test/payload.exe")!
        let good = URL(string: "https://good-host.example.test/")!
        let verdicts = try await provider.lookup([bad, good])

        #expect(verdicts[bad] == .malicious(threatTypes: ["malware_download"]))
        #expect(verdicts[good] == .clean)
        #expect(api.requests.count == 2)
        #expect(api.requests.allSatisfy { $0.method == "POST" && $0.headers["Auth-Key"] == "abc123" })
        let firstBody = String(decoding: try #require(api.requests.first?.body), as: UTF8.self)
        #expect(firstBody == "url=https%3A%2F%2Fbad-host.example.test%2Fpayload.exe")
    }

    @Test("꺼져 있으면 어떤 요청도 보내지 않는다")
    func disabledSendsNothing() async {
        let api = MockHost("urlhaus-off")
        api.stub("/v1/url/", .json(#"{"query_status":"ok"}"#))
        let provider = URLhausProvider(authKey: nil, enabled: false, session: mockSession(), endpoint: api.url("/v1/url/"))
        #expect(!provider.isAvailable)
        await #expect(throws: ReputationProviderError.unavailable) {
            _ = try await provider.lookup([URL(string: "https://x.example.test/")!])
        }
        #expect(api.requests.isEmpty)
    }
}

/// URLProtocol 핸들러 안에서 본문을 읽기 위한 작은 헬퍼(핸들러는 레코딩과 별개로 본문을 봐야 함).
enum MockRegistryBodyReader {
    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4096)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
