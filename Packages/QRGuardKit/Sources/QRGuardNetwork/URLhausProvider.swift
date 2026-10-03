import Foundation
import QRGuardCore

/// abuse.ch URLhaus 조회 (TASKS T-4.8, P2). URL **원문**을 전송하므로 기본 꺼짐이며,
/// 파이프라인은 `options.urlhausLookup`이 켜진 경우에만 이 제공자를 포함한다.
public struct URLhausProvider: ReputationProvider {
    public static let providerName = "URLhaus"
    public static let defaultEndpoint = URL(string: "https://urlhaus-api.abuse.ch/v1/url/")!

    public let name = URLhausProvider.providerName
    private let authKey: String?
    private let enabled: Bool
    private let session: URLSession
    private let endpoint: URL

    public init(
        authKey: String?,
        enabled: Bool,
        session: URLSession = URLSession(configuration: HardenedSession.configuration(requestTimeout: 4)),
        endpoint: URL = URLhausProvider.defaultEndpoint
    ) {
        let trimmed = authKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.authKey = (trimmed ?? "").isEmpty ? nil : trimmed
        self.enabled = enabled
        self.session = session
        self.endpoint = endpoint
    }

    public var isAvailable: Bool { enabled }

    public func lookup(_ urls: [URL]) async throws -> [URL: ReputationVerdict] {
        guard isAvailable else { throw ReputationProviderError.unavailable }
        var verdicts: [URL: ReputationVerdict] = [:]
        for url in urls {
            try Task.checkCancellation()
            verdicts[url] = try await query(url)
        }
        return verdicts
    }

    struct Response: Decodable {
        var query_status: String?
        var threat: String?
        var url_status: String?
    }

    private func query(_ url: URL) async throws -> ReputationVerdict {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authKey { request.setValue(authKey, forHTTPHeaderField: "Auth-Key") }
        request.httpBody = Data(("url=" + Self.formEscape(url.absoluteString)).utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ReputationProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ReputationProviderError.httpStatus(http.statusCode) }
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ReputationProviderError.invalidResponse
        }
        switch decoded.query_status {
        case "ok":
            return .malicious(threatTypes: [decoded.threat ?? "malware_download"])
        case "no_results":
            return .clean
        default:
            return .unknown
        }
    }

    static func formEscape(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._*")
        let escaped = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return escaped.replacingOccurrences(of: "%20", with: "+")
    }
}
