import CryptoKit
import Foundation
import QRGuardCore

/// 평판 제공자 공통 오류.
public enum ReputationProviderError: Error, Sendable, Hashable {
    /// 키 없음·설정 꺼짐
    case unavailable
    case httpStatus(Int)
    case invalidResponse
}

/// Google Safe Browsing v5 `hashes:search` (TASKS T-4.3, TECH_PRD 6.2).
/// URL 원문이 아니라 표현식 SHA-256의 앞 4바이트만 전송하고, 돌아온 전체 해시와 로컬에서 비교한다.
public struct SafeBrowsingV5Provider: ReputationProvider {
    public static let providerName = "Google Safe Browsing"
    public static let defaultEndpoint = URL(string: "https://safebrowsing.googleapis.com/v5/hashes:search")!
    /// 한 요청당 프리픽스 상한(API 제한 1000).
    static let maxPrefixesPerRequest = 1000

    public let name = SafeBrowsingV5Provider.providerName
    private let apiKey: String?
    private let session: URLSession
    private let endpoint: URL

    public init(
        apiKey: String?,
        session: URLSession = URLSession(configuration: HardenedSession.configuration(requestTimeout: 4)),
        endpoint: URL = SafeBrowsingV5Provider.defaultEndpoint
    ) {
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
        self.endpoint = endpoint
    }

    public var isAvailable: Bool { !(apiKey ?? "").isEmpty }

    public func lookup(_ urls: [URL]) async throws -> [URL: ReputationVerdict] {
        guard isAvailable, let apiKey else { throw ReputationProviderError.unavailable }
        guard !urls.isEmpty else { return [:] }

        // 표현식 → 전체 해시, 프리픽스 수집
        var hashesByURL: [URL: [Data]] = [:]
        var urlsByHash: [Data: [URL]] = [:]
        var prefixes: [Data] = []
        var seenPrefixes = Set<Data>()
        for url in urls {
            let hashes = Self.fullHashes(for: url)
            hashesByURL[url] = hashes
            for hash in hashes {
                urlsByHash[hash, default: []].append(url)
                let prefix = hash.prefix(4)
                if seenPrefixes.insert(prefix).inserted { prefixes.append(prefix) }
            }
        }

        var matched: [Data: [String]] = [:]
        var start = 0
        while start < prefixes.count {
            let end = min(start + Self.maxPrefixesPerRequest, prefixes.count)
            let chunk = Array(prefixes[start..<end])
            start = end
            try Task.checkCancellation()
            let response = try await search(prefixes: chunk, apiKey: apiKey)
            for full in response.fullHashes ?? [] {
                guard let data = Data(base64Encoded: full.fullHash) else { continue }
                let types = (full.fullHashDetails ?? []).compactMap(\.threatType)
                matched[data, default: []].append(contentsOf: types.isEmpty ? ["UNSPECIFIED"] : types)
            }
        }

        var verdicts: [URL: ReputationVerdict] = [:]
        for url in urls {
            guard let hashes = hashesByURL[url], !hashes.isEmpty else {
                verdicts[url] = .unknown
                continue
            }
            var threats: [String] = []
            for hash in hashes {
                if let types = matched[hash] { threats.append(contentsOf: types) }
            }
            if threats.isEmpty {
                verdicts[url] = .clean
            } else {
                var unique: [String] = []
                for t in threats where !unique.contains(t) { unique.append(t) }
                verdicts[url] = .malicious(threatTypes: unique)
            }
        }
        return verdicts
    }

    // MARK: - 해시

    /// URL의 모든 표현식에 대한 SHA-256 전체 해시.
    public static func fullHashes(for url: URL) -> [Data] {
        SafeBrowsingCanonicalizer.expressions(for: url).map { expr in
            Data(SHA256.hash(data: Data(expr.utf8)))
        }
    }

    // MARK: - 요청

    struct SearchResponse: Decodable {
        struct FullHash: Decodable {
            struct Detail: Decodable {
                var threatType: String?
                var attributes: [String]?
            }
            var fullHash: String
            var fullHashDetails: [Detail]?
        }
        var fullHashes: [FullHash]?
        var cacheDuration: String?
    }

    private func search(prefixes: [Data], apiKey: String) async throws -> SearchResponse {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw ReputationProviderError.invalidResponse
        }
        var query = "key=" + Self.queryEscape(apiKey)
        for prefix in prefixes {
            query += "&hashPrefixes=" + Self.queryEscape(prefix.base64EncodedString())
        }
        components.percentEncodedQuery = query
        guard let url = components.url else { throw ReputationProviderError.invalidResponse }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ReputationProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ReputationProviderError.httpStatus(http.statusCode) }
        do {
            return try JSONDecoder().decode(SearchResponse.self, from: data)
        } catch {
            throw ReputationProviderError.invalidResponse
        }
    }

    /// `+ / =`까지 인코딩하는 보수적 쿼리 이스케이프(base64 안전 전송).
    static func queryEscape(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
