import Foundation
import os
@testable import QRGuardNetwork

/// 스텁 응답.
struct MockResponse: Sendable {
    var status: Int = 200
    var headers: [String: String] = [:]
    var body: Data = Data()
    /// 응답하지 않고 영원히 대기(타임아웃 테스트). 작업이 취소되면 `stopLoading`으로 정리된다.
    var hang = false
    /// 응답 전 지연(초). 프로토콜 스레드에서 동기 대기하므로 전용 세션에서만 쓴다.
    var delay: TimeInterval = 0
    var errorCode: URLError.Code?

    static func html(_ text: String, status: Int = 200, contentType: String = "text/html; charset=utf-8") -> MockResponse {
        MockResponse(status: status, headers: ["Content-Type": contentType], body: Data(text.utf8))
    }

    static func json(_ text: String, status: Int = 200) -> MockResponse {
        MockResponse(status: status, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
    }

    static func redirect(_ status: Int, to location: String) -> MockResponse {
        MockResponse(status: status, headers: ["Location": location, "Content-Type": "text/html"])
    }

    static func status(_ code: Int, contentType: String? = nil) -> MockResponse {
        var headers: [String: String] = [:]
        if let contentType { headers["Content-Type"] = contentType }
        return MockResponse(status: code, headers: headers)
    }

    static let hanging = MockResponse(hang: true)
    static func failing(_ code: URLError.Code) -> MockResponse { MockResponse(errorCode: code) }
}

struct RecordedRequest: Sendable {
    let url: URL
    let method: String
    let headers: [String: String]
    let body: Data?

    var host: String { url.host?.lowercased() ?? "" }
}

/// 스레드 안전 스텁 레지스트리. 키는 `host + path`(쿼리 무시). 호스트 전체 핸들러도 등록할 수 있다.
final class MockRegistry: Sendable {
    typealias Handler = @Sendable (URLRequest) -> MockResponse

    private struct State: Sendable {
        var pathHandlers: [String: Handler] = [:]
        var hostHandlers: [String: Handler] = [:]
        var requests: [RecordedRequest] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    static func key(for url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.isEmpty ? "/" : url.path
        return host + path
    }

    func stub(_ url: URL, handler: @escaping Handler) {
        state.withLock { $0.pathHandlers[Self.key(for: url)] = handler }
    }

    func stubHost(_ host: String, handler: @escaping Handler) {
        state.withLock { $0.hostHandlers[host.lowercased()] = handler }
    }

    func record(_ request: URLRequest) {
        guard let url = request.url else { return }
        let recorded = RecordedRequest(
            url: url,
            method: request.httpMethod ?? "GET",
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.body(of: request)
        )
        state.withLock { $0.requests.append(recorded) }
    }

    func response(for request: URLRequest) -> MockResponse {
        guard let url = request.url else { return .status(599) }
        let handler: Handler? = state.withLock { s in
            s.pathHandlers[Self.key(for: url)] ?? s.hostHandlers[url.host?.lowercased() ?? ""]
        }
        guard let handler else {
            return MockResponse(status: 599, headers: ["Content-Type": "text/plain"], body: Data("unstubbed: \(url.absoluteString)".utf8))
        }
        return handler(request)
    }

    func requests(host: String) -> [RecordedRequest] {
        let h = host.lowercased()
        return state.withLock { $0.requests.filter { $0.host == h } }
    }

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
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

/// 네트워크 대신 레지스트리의 스텁을 돌려주는 URLProtocol. 3xx는 `wasRedirectedTo`를 먼저 알려
/// 세션 델리게이트(리다이렉트 거부)가 실제로 호출되게 한다.
final class MockURLProtocol: URLProtocol {
    static let registry = MockRegistry()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let registry = Self.registry
        registry.record(request)
        let response = registry.response(for: request)
        if response.hang { return }
        if response.delay > 0 { Thread.sleep(forTimeInterval: response.delay) }
        guard let url = request.url, let client else { return }
        if let code = response.errorCode {
            client.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        guard let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers) else {
            client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if (300..<400).contains(response.status), response.status != 304,
           let location = response.headers["Location"],
           let next = URL(string: location, relativeTo: url)?.absoluteURL {
            client.urlProtocol(self, wasRedirectedTo: URLRequest(url: next), redirectResponse: http)
        }
        client.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if request.httpMethod?.uppercased() != "HEAD", !response.body.isEmpty {
            client.urlProtocol(self, didLoad: response.body)
        }
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - 테스트 편의

/// 테스트마다 고유한 호스트(`<name>.example.test`)를 써서 병렬 테스트 간 충돌을 피한다.
struct MockHost: Sendable {
    let host: String

    init(_ name: String) {
        host = "\(name).example.test"
    }

    func url(_ path: String = "/") -> URL {
        URL(string: "https://\(host)\(path)")!
    }

    func stub(_ path: String, _ response: MockResponse) {
        MockURLProtocol.registry.stub(url(path)) { _ in response }
    }

    func stub(_ path: String, handler: @escaping MockRegistry.Handler) {
        MockURLProtocol.registry.stub(url(path), handler: handler)
    }

    func stubAll(_ response: MockResponse) {
        MockURLProtocol.registry.stubHost(host) { _ in response }
    }

    var requests: [RecordedRequest] {
        MockURLProtocol.registry.requests(host: host)
    }
}

func mockConfiguration(requestTimeout: TimeInterval = 3) -> URLSessionConfiguration {
    HardenedSession.configuration(requestTimeout: requestTimeout, protocolClasses: [MockURLProtocol.self])
}

func mockSession(requestTimeout: TimeInterval = 3) -> URLSession {
    URLSession(configuration: mockConfiguration(requestTimeout: requestTimeout))
}

func fixtureData(_ name: String, extension ext: String = "html") throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else {
        throw FixtureError.missing("\(name).\(ext)")
    }
    return try Data(contentsOf: url)
}

enum FixtureError: Error {
    case missing(String)
}
