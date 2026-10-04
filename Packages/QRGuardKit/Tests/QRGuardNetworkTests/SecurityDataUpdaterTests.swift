import CryptoKit
import Foundation
import Testing
import QRGuardCore
@testable import QRGuardNetwork

@Suite("SecurityDataUpdater (T-6.3)")
struct SecurityDataUpdaterTests {
    /// 테스트마다 격리된 캐시 디렉터리·호스트.
    struct Harness {
        let host: MockHost
        let cacheDirectory: URL

        init(_ name: String) {
            host = MockHost("secdata-\(name)")
            cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("qrg-secdata-\(name)-\(UUID().uuidString)", isDirectory: true)
        }

        func cleanup() { try? FileManager.default.removeItem(at: cacheDirectory) }

        func updater(publicKey: Curve25519.Signing.PublicKey, timeout: Duration = .seconds(4)) -> SecurityDataUpdater {
            SecurityDataUpdater(
                endpoint: host.url("/security-data.json"),
                publicKey: publicKey,
                cacheDirectory: cacheDirectory,
                session: mockSession(requestTimeout: 3),
                totalTimeout: timeout
            )
        }

        /// 번들 공개키로 서명된 커밋 픽스처를 서빙한다.
        func serveFixture(data: String = "security-data", signature: String = "security-data") throws {
            host.stub("/security-data.json", MockResponse(status: 200, headers: ["Content-Type": "application/json"], body: try fixtureData(data, extension: "json")))
            host.stub("/security-data.json.sig", MockResponse(status: 200, headers: ["Content-Type": "text/plain"], body: try fixtureData(signature + ".json", extension: "sig")))
        }

        /// 테스트 키로 서명한 임의 순번의 묶음을 서빙한다.
        func serve(sequence: Int, signedWith key: Curve25519.Signing.PrivateKey) throws {
            let data = Data(#"{"schemaVersion":1,"publishedAt":"2026-10-04T00:00:00Z","sequence":\#(sequence),"shorteners":["s\#(sequence).example.test"]}"#.utf8)
            let sig = try key.signature(for: data).base64EncodedString()
            host.stub("/security-data.json", MockResponse(status: 200, headers: ["Content-Type": "application/json"], body: data))
            host.stub("/security-data.json.sig", MockResponse(status: 200, headers: ["Content-Type": "text/plain"], body: Data(sig.utf8)))
        }

        var dataFileExists: Bool { FileManager.default.fileExists(atPath: SecurityDataFiles.dataURL(in: cacheDirectory).path) }
    }

    static let bundledKey: Curve25519.Signing.PublicKey = {
        guard let key = SecurityDataVerifier.bundledPublicKey else { fatalError("번들 공개키 리소스가 없습니다") }
        return key
    }()

    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("유효한 묶음을 적용하고 캐시·상태를 기록한다 → DataStore가 덮어쓰기를 읽는다")
    func appliesValidBundle() async throws {
        let h = Harness("valid")
        defer { h.cleanup() }
        try h.serveFixture()
        let updater = h.updater(publicKey: Self.bundledKey)

        let outcome = await updater.updateIfNeeded(now: Self.t0)
        #expect(outcome == .applied(sequence: 2))
        #expect(h.dataFileExists)

        let cached = try #require(try await updater.cachedBundle())
        #expect(cached.sequence == 2)
        #expect(cached.brands?.first?.brand == "테스트은행")
        #expect(cached.blocklist?.domains == ["overlay-blocked.example.test"])

        let state = await updater.currentState()
        #expect(state.appliedSequence == 2)
        #expect(state.lastCheckedAt == Self.t0)
        #expect(state.appliedSHA256?.count == 64)

        // 캐시된 바이트는 서버가 보낸 바이트와 완전히 같아야 한다(재인코딩 금지).
        let served = try fixtureData("security-data", extension: "json")
        #expect(try Data(contentsOf: SecurityDataFiles.dataURL(in: h.cacheDirectory)) == served)

        // 앱 시작 시 로드 경로: 번들 공개키로 재검증해 적용된다.
        let store = DataStore.loadApplyingCachedUpdate(cacheDirectory: h.cacheDirectory)
        #expect(store.remoteSequence == 2)
        #expect(store.brands.map(\.brand) == ["테스트은행"])
        #expect(!store.shorteners.isEmpty)

        // 요청은 쿠키 없이, 두 파일만.
        let requests = h.host.requests
        #expect(requests.count == 2)
        #expect(Set(requests.map(\.url.path)) == ["/security-data.json", "/security-data.json.sig"])
        #expect(requests.allSatisfy { $0.headers["Cookie"] == nil })
    }

    @Test("변조된 묶음은 거부하고 캐시를 건드리지 않는다")
    func rejectsTampered() async throws {
        let h = Harness("tampered")
        defer { h.cleanup() }
        try h.serveFixture(data: "security-data-tampered", signature: "security-data")
        let updater = h.updater(publicKey: Self.bundledKey)

        let outcome = await updater.updateIfNeeded(now: Self.t0)
        #expect(outcome == .rejected(.invalidSignature))
        #expect(!h.dataFileExists)
        #expect(try await updater.cachedBundle() == nil)
        #expect(DataStore.loadApplyingCachedUpdate(cacheDirectory: h.cacheDirectory).sourceDescription == DataStore.bundledSourceDescription)
    }

    @Test("다른 키로 서명된 묶음은 거부한다")
    func rejectsWrongKey() async throws {
        let h = Harness("wrongkey")
        defer { h.cleanup() }
        try h.serve(sequence: 9, signedWith: Curve25519.Signing.PrivateKey())
        let outcome = await h.updater(publicKey: Self.bundledKey).updateIfNeeded(now: Self.t0)
        #expect(outcome == .rejected(.invalidSignature))
        #expect(!h.dataFileExists)
    }

    @Test("24시간 안에 다시 부르면 요청 없이 건너뛴다 · 지나면 다시 확인(upToDate)")
    func skipsRecentThenUpToDate() async throws {
        let h = Harness("interval")
        defer { h.cleanup() }
        try h.serveFixture()
        let updater = h.updater(publicKey: Self.bundledKey)

        #expect(await updater.updateIfNeeded(now: Self.t0) == .applied(sequence: 2))
        let afterFirst = h.host.requests.count

        #expect(await updater.updateIfNeeded(now: Self.t0.addingTimeInterval(3_600)) == .skippedRecently)
        #expect(await updater.updateIfNeeded(now: Self.t0.addingTimeInterval(86_399)) == .skippedRecently)
        #expect(h.host.requests.count == afterFirst)

        let later = Self.t0.addingTimeInterval(90_000)
        #expect(await updater.updateIfNeeded(now: later) == .upToDate)
        #expect(h.host.requests.count == afterFirst + 2)
        let state = await updater.currentState()
        #expect(state.lastCheckedAt == later)
        #expect(state.appliedSequence == 2)
    }

    @Test("적용된 순번보다 낮은 묶음은 롤백으로 거부한다")
    func rejectsRollback() async throws {
        let h = Harness("rollback")
        defer { h.cleanup() }
        let key = Curve25519.Signing.PrivateKey()
        let updater = h.updater(publicKey: key.publicKey)

        try h.serve(sequence: 5, signedWith: key)
        #expect(await updater.updateIfNeeded(now: Self.t0) == .applied(sequence: 5))

        try h.serve(sequence: 4, signedWith: key)
        #expect(await updater.updateIfNeeded(now: Self.t0.addingTimeInterval(90_000)) == .rejected(.notNewer(received: 4, applied: 5)))
        #expect(try await updater.cachedBundle()?.sequence == 5)

        try h.serve(sequence: 6, signedWith: key)
        #expect(await updater.updateIfNeeded(now: Self.t0.addingTimeInterval(180_000)) == .applied(sequence: 6))
        #expect(try await updater.cachedBundle()?.sequence == 6)
    }

    @Test("404 · 네트워크 오류 · 시간 초과는 failed, 캐시 없음 → 번들 데이터로 동작")
    func failuresFallBackToBundled() async throws {
        let notFound = Harness("404")
        defer { notFound.cleanup() }
        notFound.host.stubAll(.status(404))
        let o1 = await notFound.updater(publicKey: Self.bundledKey).updateIfNeeded(now: Self.t0)
        guard case .failed(let reason) = o1 else { Issue.record("expected .failed, got \(o1)"); return }
        #expect(reason.contains("404"))
        #expect(!notFound.dataFileExists)
        #expect(DataStore.loadApplyingCachedUpdate(cacheDirectory: notFound.cacheDirectory).sourceDescription == DataStore.bundledSourceDescription)
        // 실패는 lastCheckedAt을 남기지 않아 다음 실행에서 바로 재시도한다.
        #expect(await notFound.updater(publicKey: Self.bundledKey).currentState().lastCheckedAt == nil)

        let down = Harness("down")
        defer { down.cleanup() }
        down.host.stubAll(.failing(.cannotConnectToHost))
        guard case .failed = await down.updater(publicKey: Self.bundledKey).updateIfNeeded(now: Self.t0) else {
            Issue.record("expected .failed"); return
        }

        let hanging = Harness("hang")
        defer { hanging.cleanup() }
        hanging.host.stubAll(.hanging)
        let start = ContinuousClock.now
        let o3 = await hanging.updater(publicKey: Self.bundledKey, timeout: .milliseconds(400)).updateIfNeeded(now: Self.t0)
        #expect(o3 == .failed("timeout"))
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(!hanging.dataFileExists)
    }

    @Test("서명 파일만 없으면(404) 적용하지 않는다")
    func missingSignatureIsFailure() async throws {
        let h = Harness("nosig")
        defer { h.cleanup() }
        h.host.stub("/security-data.json", MockResponse(status: 200, headers: ["Content-Type": "application/json"], body: try fixtureData("security-data", extension: "json")))
        h.host.stub("/security-data.json.sig", .status(404))
        guard case .failed = await h.updater(publicKey: Self.bundledKey).updateIfNeeded(now: Self.t0) else {
            Issue.record("expected .failed"); return
        }
        #expect(!h.dataFileExists)
    }

    @Test("http 엔드포인트에는 요청하지 않는다")
    func rejectsInsecureEndpoint() async {
        let h = Harness("http")
        defer { h.cleanup() }
        let updater = SecurityDataUpdater(
            endpoint: URL(string: "http://\(h.host.host)/security-data.json")!,
            publicKey: Self.bundledKey, cacheDirectory: h.cacheDirectory, session: mockSession()
        )
        guard case .failed(let reason) = await updater.updateIfNeeded(now: Self.t0) else { Issue.record("expected .failed"); return }
        #expect(reason.contains("https"))
        #expect(h.host.requests.isEmpty)
    }

    @Test("clearCache 후에는 즉시 다시 확인하고 적용한다")
    func clearCacheResets() async throws {
        let h = Harness("clear")
        defer { h.cleanup() }
        try h.serveFixture()
        let updater = h.updater(publicKey: Self.bundledKey)
        #expect(await updater.updateIfNeeded(now: Self.t0) == .applied(sequence: 2))
        await updater.clearCache()
        #expect(!h.dataFileExists)
        #expect(try await updater.cachedBundle() == nil)
        #expect(await updater.updateIfNeeded(now: Self.t0.addingTimeInterval(10)) == .applied(sequence: 2))
    }

    @Test("서명 URL은 데이터 URL 뒤에 .sig를 붙인다")
    func signatureURLMapping() {
        let base = URL(string: "https://cdn.example.test/qrguard/v1/security-data.json?x=1")!
        #expect(SecurityDataUpdater.signatureURL(for: base).absoluteString == "https://cdn.example.test/qrguard/v1/security-data.json.sig")
    }

    @Test("Info.plist 설정값 해석: 빈 값·미치환 변수·http는 비활성", arguments: [
        ("", false), ("   ", false), ("$(SECURITY_DATA_URL)", false), ("http://cdn.example.test/security-data.json", false),
        ("not a url", false), ("https://cdn.example.test/qrguard/security-data.json", true),
    ])
    func endpointSetting(raw: String, enabled: Bool) {
        #expect((SecurityDataConfiguration.endpoint(fromSetting: raw) != nil) == enabled)
        #expect(SecurityDataConfiguration.infoPlistKey == "SecurityDataURL")
    }

    @Test("Info.plist에 키가 없으면 갱신기를 만들지 않는다")
    func makeUpdaterDisabledWithoutKey() {
        #expect(SecurityDataConfiguration.endpoint(in: Bundle.module) == nil)
        #expect(SecurityDataConfiguration.makeUpdater(bundle: Bundle.module, cacheDirectory: FileManager.default.temporaryDirectory) == nil)
    }
}
