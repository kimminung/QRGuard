import CryptoKit
import Foundation
import os
import QRGuardCore

private let logger = Logger(subsystem: "QRGuardNetwork", category: "SecurityDataUpdater")

/// 정적 호스팅(GitHub Releases 등)에서 서명된 보안 데이터를 하루 1회 받아 검증 후 캐시에 적용한다 (TASKS T-6.3).
///
/// - `endpoint`는 `security-data.json`의 URL. 서명은 같은 URL에 `.sig`를 붙인 곳에서 받는다.
/// - 검증(`SecurityDataVerifier`)을 통과한 **원본 바이트만** `cacheDirectory/security-data.json`에 원자적으로 쓴다.
/// - 네트워크는 `HardenedSession`(ephemeral · 쿠키 없음)만 쓰고 전체 4초 안에 끝낸다.
/// - 실패하면 캐시를 건드리지 않으므로 앱은 이전 캐시 또는 번들 데이터로 계속 동작한다.
///
/// 적용 후 `DataStore.loadApplyingCachedUpdate(cacheDirectory:)`로 데이터를 다시 읽어 `RiskEngine`을 재구성한다.
public actor SecurityDataUpdater {
    public enum UpdateOutcome: Sendable, Hashable {
        /// 마지막 확인으로부터 `minimumInterval`이 지나지 않아 요청하지 않음
        case skippedRecently
        /// 서버의 순번이 이미 적용된 순번과 같음
        case upToDate
        /// 검증을 통과해 캐시에 저장함
        case applied(sequence: Int)
        /// 검증 실패(서명·스키마·롤백). 캐시는 바뀌지 않음
        case rejected(SecurityDataError)
        /// 네트워크·디스크 오류. 캐시는 바뀌지 않음
        case failed(String)
    }

    /// 캐시 디렉터리의 `security-data-state.json`에 저장되는 상태.
    public struct State: Codable, Sendable, Hashable {
        public var lastCheckedAt: Date?
        public var appliedSequence: Int?
        public var appliedSHA256: String?
        public var appliedAt: Date?
        public var appliedPublishedAt: String?

        public init(lastCheckedAt: Date? = nil, appliedSequence: Int? = nil, appliedSHA256: String? = nil, appliedAt: Date? = nil, appliedPublishedAt: String? = nil) {
            self.lastCheckedAt = lastCheckedAt
            self.appliedSequence = appliedSequence
            self.appliedSHA256 = appliedSHA256
            self.appliedAt = appliedAt
            self.appliedPublishedAt = appliedPublishedAt
        }
    }

    /// 받아들일 최대 크기. 정적 JSON이 이보다 크면 잘못된 서버로 보고 중단한다.
    public static let maxDataBytes = 4 * 1024 * 1024
    public static let maxSignatureBytes = 1024

    public nonisolated let endpoint: URL
    public nonisolated let signatureEndpoint: URL
    public nonisolated let cacheDirectory: URL
    private let verifier: SecurityDataVerifier
    private let session: URLSession
    private let totalTimeout: Duration

    /// - Parameters:
    ///   - endpoint: `security-data.json`의 https URL
    ///   - publicKey: 서명 검증용 Ed25519 공개키(보통 `SecurityDataVerifier.bundledPublicKey`)
    ///   - cacheDirectory: 검증된 데이터·상태 파일을 둘 디렉터리(없으면 만든다)
    ///   - session: 기본은 강화 ephemeral 세션. 테스트에서는 `MockURLProtocol` 세션을 넣는다.
    ///   - totalTimeout: 두 파일을 모두 받는 데 허용하는 전체 시간
    public init(
        endpoint: URL,
        publicKey: Curve25519.Signing.PublicKey,
        cacheDirectory: URL,
        session: URLSession = URLSession(configuration: HardenedSession.configuration(requestTimeout: 4)),
        totalTimeout: Duration = .seconds(4)
    ) {
        self.endpoint = endpoint
        self.signatureEndpoint = Self.signatureURL(for: endpoint)
        self.cacheDirectory = cacheDirectory
        self.verifier = SecurityDataVerifier(publicKey: publicKey)
        self.session = session
        self.totalTimeout = totalTimeout
    }

    /// `…/security-data.json` → `…/security-data.json.sig` (쿼리·프래그먼트는 유지하지 않는다).
    public static func signatureURL(for endpoint: URL) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.path += ".sig"
        components.query = nil
        components.fragment = nil
        return components.url ?? endpoint.appendingPathExtension("sig")
    }

    // MARK: 갱신

    /// 필요하면 원격 데이터를 확인해 적용한다. 절대 던지지 않고 결과를 돌려준다.
    /// - Parameters:
    ///   - now: 현재 시각(테스트 주입용)
    ///   - minimumInterval: 마지막 확인 이후 이 시간이 지나지 않았으면 요청하지 않는다(기본 24시간)
    public func updateIfNeeded(now: Date = .now, minimumInterval: Duration = .seconds(86_400)) async -> UpdateOutcome {
        var state = loadState()
        if let last = state.lastCheckedAt {
            let elapsed = now.timeIntervalSince(last)
            // 시계가 뒤로 간 경우(elapsed < 0)도 "최근 확인"으로 본다.
            if elapsed < Self.seconds(minimumInterval) {
                return .skippedRecently
            }
        }

        guard endpoint.scheme?.lowercased() == "https" else {
            return .failed("endpoint must use https: \(endpoint.absoluteString)")
        }

        let data: Data
        let signatureText: String
        do {
            (data, signatureText) = try await fetchBoth()
        } catch let error as FetchError {
            logger.error("보안 데이터 다운로드 실패: \(error.description)")
            return .failed(error.description)
        } catch is TimeoutError {
            logger.error("보안 데이터 다운로드 시간 초과")
            return .failed("timeout")
        } catch {
            logger.error("보안 데이터 다운로드 실패: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }

        let verified: SecurityDataVerifier.Verified
        do {
            verified = try verifier.verify(data: data, base64Signature: signatureText, appliedSequence: state.appliedSequence)
        } catch let error as SecurityDataError {
            if case .notNewer(let received, let applied) = error, received == applied {
                state.lastCheckedAt = now
                saveState(state)
                logger.info("보안 데이터 최신 상태(#\(applied))")
                return .upToDate
            }
            logger.error("보안 데이터 거부: \(error.code) — 캐시는 변경하지 않음")
            state.lastCheckedAt = now
            saveState(state)
            return .rejected(error)
        } catch {
            return .failed(error.localizedDescription)
        }

        do {
            try writeCache(verified: verified, signatureText: signatureText)
        } catch {
            logger.error("보안 데이터 캐시 쓰기 실패: \(error.localizedDescription)")
            return .failed("cache write failed: \(error.localizedDescription)")
        }

        state.lastCheckedAt = now
        state.appliedSequence = verified.bundle.sequence
        state.appliedSHA256 = verified.sha256Hex
        state.appliedAt = now
        state.appliedPublishedAt = verified.bundle.publishedAt
        saveState(state)
        logger.info("보안 데이터 적용 #\(verified.bundle.sequence) sha256=\(verified.sha256Hex) fields=\(verified.bundle.includedFields.joined(separator: ","))")
        return .applied(sequence: verified.bundle.sequence)
    }

    // MARK: 캐시 조회

    /// 캐시에 저장된(이전에 검증된) 묶음. 저장 시점 이후 파일이 변조되었으면 nil을 돌려주고 캐시를 지운다.
    public func cachedBundle() throws -> SecurityDataBundle? {
        let dataURL = SecurityDataFiles.dataURL(in: cacheDirectory)
        guard FileManager.default.fileExists(atPath: dataURL.path) else { return nil }
        let data = try Data(contentsOf: dataURL)
        let signature = try String(contentsOf: SecurityDataFiles.signatureURL(in: cacheDirectory), encoding: .utf8)
        do {
            return try verifier.verify(data: data, base64Signature: signature, appliedSequence: nil).bundle
        } catch {
            logger.error("캐시된 보안 데이터 검증 실패(\(error.code)) — 캐시를 지웁니다")
            clearCache()
            return nil
        }
    }

    /// 현재 상태(마지막 확인 시각·적용 순번).
    public func currentState() -> State { loadState() }

    /// 데이터·서명·상태 파일을 모두 지운다. 다음 `updateIfNeeded`는 즉시 확인한다.
    public func clearCache() {
        let fm = FileManager.default
        for url in [SecurityDataFiles.dataURL(in: cacheDirectory), SecurityDataFiles.signatureURL(in: cacheDirectory), SecurityDataFiles.stateURL(in: cacheDirectory)] {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - 내부

    enum FetchError: Error, CustomStringConvertible {
        case httpStatus(Int, URL)
        case notHTTP(URL)
        case tooLarge(URL, Int)
        case notUTF8(URL)

        var description: String {
            switch self {
            case .httpStatus(let code, let url): "HTTP \(code) for \(url.lastPathComponent)"
            case .notHTTP(let url): "non-HTTP response for \(url.lastPathComponent)"
            case .tooLarge(let url, let size): "\(url.lastPathComponent) too large (\(size) bytes)"
            case .notUTF8(let url): "\(url.lastPathComponent) is not UTF-8 text"
            }
        }
    }

    private func fetchBoth() async throws -> (Data, String) {
        let session = self.session
        let dataURL = endpoint
        let sigURL = signatureEndpoint
        return try await withTimeout(totalTimeout) {
            async let dataBytes = Self.fetch(dataURL, session: session, maxBytes: Self.maxDataBytes)
            async let sigBytes = Self.fetch(sigURL, session: session, maxBytes: Self.maxSignatureBytes)
            let (d, s) = try await (dataBytes, sigBytes)
            guard let text = String(data: s, encoding: .utf8) else { throw FetchError.notUTF8(sigURL) }
            return (d, text)
        }
    }

    private static func fetch(_ url: URL, session: URLSession, maxBytes: Int) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.httpMethod = "GET"
        request.setValue("application/json, application/octet-stream, text/plain;q=0.9, */*;q=0.1", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetchError.notHTTP(url) }
        guard (200..<300).contains(http.statusCode) else { throw FetchError.httpStatus(http.statusCode, url) }
        guard data.count <= maxBytes else { throw FetchError.tooLarge(url, data.count) }
        return data
    }

    /// 검증된 바이트와 서명을 원자적으로 쓴다. 디렉터리가 없으면 만든다.
    private func writeCache(verified: SecurityDataVerifier.Verified, signatureText: String) throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try verified.data.write(to: SecurityDataFiles.dataURL(in: cacheDirectory), options: .atomic)
        try Data(signatureText.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
            .write(to: SecurityDataFiles.signatureURL(in: cacheDirectory), options: .atomic)
    }

    private func loadState() -> State {
        let url = SecurityDataFiles.stateURL(in: cacheDirectory)
        guard let data = try? Data(contentsOf: url) else { return State() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(State.self, from: data)) ?? State()
    }

    private func saveState(_ state: State) {
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(state).write(to: SecurityDataFiles.stateURL(in: cacheDirectory), options: .atomic)
        } catch {
            logger.error("보안 데이터 상태 저장 실패: \(error.localizedDescription)")
        }
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        let c = duration.components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }
}

// MARK: - 설정(Info.plist)

/// 원격 보안 데이터 엔드포인트 설정. 빌드 설정 `SECURITY_DATA_URL` → Info.plist `SecurityDataURL`로 주입된다.
/// 값이 비어 있으면 갱신기가 비활성화된다(요청을 전혀 보내지 않음).
public enum SecurityDataConfiguration {
    /// Info.plist 키. 앱 타깃의 Info.plist에 `<key>SecurityDataURL</key><string>$(SECURITY_DATA_URL)</string>`를 둔다.
    public static let infoPlistKey = "SecurityDataURL"

    /// Info.plist에서 엔드포인트를 읽는다. 비어 있거나 https가 아니면 nil(비활성).
    public static func endpoint(in bundle: Bundle = .main) -> URL? {
        guard let raw = bundle.object(forInfoDictionaryKey: infoPlistKey) as? String else { return nil }
        return endpoint(fromSetting: raw)
    }

    /// 설정 문자열을 검사해 URL로 만든다. 빈 값·`$(…)` 미치환·http는 nil.
    public static func endpoint(fromSetting raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("$("), let url = URL(string: text),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }

    /// Info.plist와 번들 공개키로 갱신기를 만든다. 엔드포인트가 비어 있거나 공개키 리소스가 없으면 nil(비활성).
    public static func makeUpdater(
        bundle: Bundle = .main,
        cacheDirectory: URL = SecurityDataFiles.defaultCacheDirectory,
        session: URLSession = URLSession(configuration: HardenedSession.configuration(requestTimeout: 4))
    ) -> SecurityDataUpdater? {
        guard let endpoint = endpoint(in: bundle) else {
            logger.info("SecurityDataURL 비어 있음 — 원격 보안 데이터 갱신 비활성")
            return nil
        }
        guard let key = SecurityDataVerifier.bundledPublicKey else {
            logger.error("보안 데이터 공개키 리소스 없음 — 원격 갱신 비활성")
            return nil
        }
        return SecurityDataUpdater(endpoint: endpoint, publicKey: key, cacheDirectory: cacheDirectory, session: session)
    }
}
