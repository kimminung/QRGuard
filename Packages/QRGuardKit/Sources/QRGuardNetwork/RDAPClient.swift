import Foundation
import QRGuardCore

/// RDAP 등록일 조회 (TASKS T-4.5). `https://rdap.org/domain/{eTLD+1}` → 레지스트리로 리다이렉트된다
/// (스캔한 주소가 아니므로 리다이렉트는 정상적으로 따라간다).
public struct RDAPClient: DomainInfoProviding {
    public enum RDAPError: Error, Sendable, Hashable {
        case httpStatus(Int)
        case invalidResponse
    }

    public static let defaultBaseURL = URL(string: "https://rdap.org/domain/")!

    private let session: URLSession
    private let baseURL: URL
    private let timeout: Duration

    public init(
        session: URLSession = URLSession(configuration: HardenedSession.configuration(requestTimeout: 3)),
        baseURL: URL = RDAPClient.defaultBaseURL,
        timeout: Duration = .seconds(3)
    ) {
        self.session = session
        self.baseURL = baseURL
        self.timeout = timeout
    }

    /// 404(미등록·미지원 TLD)는 nil, 네트워크 오류·시간 초과는 throw.
    public func registrationDate(for registrableDomain: String) async throws -> Date? {
        let domain = registrableDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !domain.isEmpty,
              let encoded = domain.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: encoded, relativeTo: baseURL)?.absoluteURL else {
            throw RDAPError.invalidResponse
        }
        var mutableRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        mutableRequest.httpMethod = "GET"
        mutableRequest.setValue("application/rdap+json, application/json;q=0.9", forHTTPHeaderField: "Accept")
        mutableRequest.timeoutInterval = RedirectResolver.seconds(timeout)
        let request = mutableRequest

        let session = self.session
        let (data, response) = try await withTimeout(timeout) {
            try await session.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else { throw RDAPError.invalidResponse }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw RDAPError.httpStatus(http.statusCode) }
        return try Self.parseRegistrationDate(from: data)
    }

    struct RDAPResponse: Decodable {
        struct Event: Decodable {
            var eventAction: String?
            var eventDate: String?
        }
        var events: [Event]?
    }

    /// `events[eventAction == "registration"].eventDate` (ISO 8601, 소수점 초 허용).
    static func parseRegistrationDate(from data: Data) throws -> Date? {
        let decoded: RDAPResponse
        do {
            decoded = try JSONDecoder().decode(RDAPResponse.self, from: data)
        } catch {
            throw RDAPError.invalidResponse
        }
        guard let event = decoded.events?.first(where: { $0.eventAction?.lowercased() == "registration" }),
              let raw = event.eventDate else {
            return nil
        }
        return parseISO8601(raw)
    }

    static func parseISO8601(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        // 시간대 생략(일부 레지스트리) → UTC로 간주
        let noZone = DateFormatter()
        noZone.locale = Locale(identifier: "en_US_POSIX")
        noZone.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            noZone.dateFormat = format
            if let date = noZone.date(from: text) { return date }
        }
        return nil
    }
}
