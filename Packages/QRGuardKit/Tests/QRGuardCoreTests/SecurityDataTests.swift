import CryptoKit
import Foundation
import Testing
@testable import QRGuardCore

/// 테스트용 서명 도우미: 매 테스트마다 새 키쌍을 만들어 서명한다(번들 공개키와 독립).
struct SigningFixture {
    let privateKey = Curve25519.Signing.PrivateKey()
    var publicKey: Curve25519.Signing.PublicKey { privateKey.publicKey }
    var verifier: SecurityDataVerifier { SecurityDataVerifier(publicKey: publicKey) }

    func sign(_ data: Data) throws -> Data { try privateKey.signature(for: data) }

    static func json(sequence: Int, schemaVersion: Int = 1, extra: String = "") -> Data {
        Data("""
        {"schemaVersion": \(schemaVersion), "publishedAt": "2026-10-04T01:02:03Z", "sequence": \(sequence)\(extra)}
        """.utf8)
    }
}

@Suite("SecurityDataVerifier (T-6.3)")
struct SecurityDataVerifierTests {
    @Test("유효한 서명은 통과하고 묶음·SHA-256을 돌려준다")
    func acceptsValid() throws {
        let fx = SigningFixture()
        let data = SigningFixture.json(sequence: 5, extra: #", "shorteners": ["Short.Example.TEST"]"#)
        let verified = try fx.verifier.verify(data: data, signature: fx.sign(data), appliedSequence: 4)
        #expect(verified.bundle.sequence == 5)
        #expect(verified.bundle.shorteners == ["Short.Example.TEST"])
        #expect(verified.bundle.includedFields == ["shorteners"])
        #expect(verified.data == data)
        #expect(verified.sha256Hex == SecurityDataVerifier.sha256Hex(data))
        #expect(verified.sha256Hex.count == 64)
        #expect(verified.bundle.publishedDate != nil)
    }

    @Test("base64 서명 텍스트(.sig 파일 내용)도 받는다")
    func acceptsBase64Text() throws {
        let fx = SigningFixture()
        let data = SigningFixture.json(sequence: 1)
        let sig = try fx.sign(data).base64EncodedString() + "\n"
        let verified = try fx.verifier.verify(data: data, base64Signature: sig, appliedSequence: nil)
        #expect(verified.bundle.sequence == 1)
    }

    @Test("바이트가 하나라도 바뀌면 거부한다")
    func rejectsTampered() throws {
        let fx = SigningFixture()
        let data = SigningFixture.json(sequence: 5)
        let signature = try fx.sign(data)
        var tampered = data
        tampered[tampered.count - 2] = UInt8(ascii: "6") // sequence 5 → 6
        #expect(throws: SecurityDataError.invalidSignature) {
            _ = try fx.verifier.verify(data: tampered, signature: signature, appliedSequence: nil)
        }
    }

    @Test("다른 키로 만든 서명은 거부한다")
    func rejectsWrongKey() throws {
        let signer = SigningFixture()
        let other = SigningFixture()
        let data = SigningFixture.json(sequence: 5)
        #expect(throws: SecurityDataError.invalidSignature) {
            _ = try other.verifier.verify(data: data, signature: signer.sign(data), appliedSequence: nil)
        }
    }

    @Test("형식이 틀린 서명은 malformedSignature")
    func rejectsMalformedSignature() throws {
        let fx = SigningFixture()
        let data = SigningFixture.json(sequence: 5)
        #expect(throws: SecurityDataError.malformedSignature) {
            _ = try fx.verifier.verify(data: data, signature: Data(repeating: 1, count: 10), appliedSequence: nil)
        }
        #expect(throws: SecurityDataError.malformedSignature) {
            _ = try fx.verifier.verify(data: data, base64Signature: "not base64!!", appliedSequence: nil)
        }
    }

    @Test("적용된 순번 이하(롤백·동일)는 거부한다", arguments: [5, 7])
    func rejectsRollback(applied: Int) throws {
        let fx = SigningFixture()
        let data = SigningFixture.json(sequence: 5)
        #expect(throws: SecurityDataError.notNewer(received: 5, applied: applied)) {
            _ = try fx.verifier.verify(data: data, signature: fx.sign(data), appliedSequence: applied)
        }
    }

    @Test("지원하지 않는 스키마 버전은 거부한다", arguments: [0, 2, 99])
    func rejectsUnsupportedSchema(version: Int) throws {
        let fx = SigningFixture()
        let data = SigningFixture.json(sequence: 9, schemaVersion: version)
        #expect(throws: SecurityDataError.unsupportedSchemaVersion(version)) {
            _ = try fx.verifier.verify(data: data, signature: fx.sign(data), appliedSequence: nil)
        }
    }

    @Test("서명은 맞지만 JSON이 깨졌으면 malformedJSON")
    func rejectsMalformedJSON() throws {
        let fx = SigningFixture()
        let data = Data("{not json".utf8)
        #expect {
            _ = try fx.verifier.verify(data: data, signature: fx.sign(data), appliedSequence: nil)
        } throws: { error in
            if case .malformedJSON = error as? SecurityDataError { return true }
            return false
        }
    }

    @Test("번들 공개키 리소스를 읽을 수 있다(주석 줄 무시)")
    func bundledPublicKeyLoads() throws {
        let key = try #require(SecurityDataVerifier.bundledPublicKey)
        #expect(key.rawRepresentation.count == 32)
        #expect(SecurityDataVerifier.bundled != nil)
        let parsed = try SecurityDataVerifier.publicKey(base64: "# comment\n  " + key.rawRepresentation.base64EncodedString() + "\n")
        #expect(parsed.rawRepresentation == key.rawRepresentation)
        #expect(throws: SecurityDataError.malformedPublicKey) {
            _ = try SecurityDataVerifier.publicKey(base64: "AAAA")
        }
    }
}

@Suite("DataStore 원격 데이터 덮어쓰기 (T-6.3)")
struct DataStoreOverlayTests {
    static let overlayBrand = BrandEntry(brand: "테스트은행", keywords: ["testbank"], domains: ["testbank.example.test"])

    static func overlay(sequence: Int = 2) -> SecurityDataBundle {
        SecurityDataBundle(
            publishedAt: "2026-10-04T00:00:00Z",
            sequence: sequence,
            brands: [overlayBrand],
            blocklist: Blocklist(domains: ["overlay-blocked.example.test"], source: "fixture", updatedAt: "2026-10-04")
        )
    }

    @Test("묶음에 있는 항목만 바뀌고 나머지는 번들 그대로")
    func overlayReplacesOnlyPresentFields() {
        let base = DataStore.bundled
        let overlaid = base.applying(Self.overlay())

        #expect(overlaid.brands == [Self.overlayBrand])
        #expect(overlaid.brands != base.brands)
        #expect(overlaid.shorteners == base.shorteners)
        #expect(!overlaid.shorteners.isEmpty)
        #expect(overlaid.suspiciousTLDs == base.suspiciousTLDs)
        #expect(overlaid.appSchemes == base.appSchemes)
        #expect(overlaid.paymentMobilityDomains == base.paymentMobilityDomains)
        #expect(overlaid.baitKeywords == base.baitKeywords)
        #expect(overlaid.confusables == base.confusables)
        #expect(overlaid.publicSuffixRules == base.publicSuffixRules)
        #expect(overlaid.blocklist.domains == ["overlay-blocked.example.test"])
        #expect(overlaid.blocklist.source == "fixture")

        #expect(base.sourceDescription == DataStore.bundledSourceDescription)
        #expect(base.updatedAt == nil)
        #expect(!base.isRemotelyUpdated)
        #expect(overlaid.sourceDescription == "remote #2 2026-10-04T00:00:00Z")
        #expect(overlaid.remoteSequence == 2)
        #expect(overlaid.isRemotelyUpdated)
        #expect(overlaid.updatedAt == ISO8601DateFormatter().date(from: "2026-10-04T00:00:00Z"))
    }

    @Test("도메인·TLD 목록은 번들과 같은 규칙으로 정규화한다")
    func overlayNormalizesLists() {
        let bundle = SecurityDataBundle(
            publishedAt: "2026-10-04T00:00:00Z", sequence: 3,
            shorteners: [" Sh.Example.TEST. ", ""],
            suspiciousTLDs: [".XYZ", "top"],
            paymentMobility: ["Pay.Example.TEST"],
            baitKeywords: []
        )
        let overlaid = DataStore.empty.applying(bundle)
        #expect(overlaid.shorteners == ["sh.example.test"])
        #expect(overlaid.suspiciousTLDs == ["xyz", "top"])
        #expect(overlaid.paymentMobilityDomains == ["pay.example.test"])
        // 빈 미끼 키워드 목록은 무시하고 기본값을 유지한다(규칙이 무력화되지 않도록).
        #expect(overlaid.baitKeywords == DataStore.defaultBaitKeywords)
    }

    @Test("overlay가 nil이면 load(from:)과 같다 · 캐시 디렉터리가 비어 있으면 .bundled와 같다")
    func nilOverlayIsBundled() {
        // 테스트 타깃의 Bundle.module은 Core 리소스가 없는 번들이므로 두 경로가 같은 결과(빈 데이터)를 내는지만 본다.
        let plain = DataStore.load(from: Bundle.module, overlay: nil)
        #expect(plain.brands == DataStore.load(from: Bundle.module).brands)
        #expect(plain.sourceDescription == DataStore.bundledSourceDescription)
        #expect(plain.remoteSequence == nil)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qrg-empty-\(UUID().uuidString)", isDirectory: true)
        let fromCache = DataStore.loadApplyingCachedUpdate(cacheDirectory: dir)
        #expect(fromCache.brands == DataStore.bundled.brands)
        #expect(!fromCache.brands.isEmpty)
        #expect(fromCache.sourceDescription == DataStore.bundledSourceDescription)
    }

    @Test("캐시 디렉터리의 서명된 데이터를 다시 검증해 적용한다 · 없거나 변조되면 번들")
    func loadsFromVerifiedCache() throws {
        let fx = SigningFixture()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qrg-overlay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1) 캐시 없음 → 번들
        #expect(DataStore.loadApplyingCachedUpdate(cacheDirectory: dir, verifier: fx.verifier).sourceDescription == DataStore.bundledSourceDescription)

        // 2) 유효한 캐시 → 적용
        let data = try JSONEncoder().encode(Self.overlay(sequence: 7))
        try data.write(to: SecurityDataFiles.dataURL(in: dir))
        try fx.sign(data).base64EncodedString().write(to: SecurityDataFiles.signatureURL(in: dir), atomically: true, encoding: .utf8)
        let applied = DataStore.loadApplyingCachedUpdate(cacheDirectory: dir, verifier: fx.verifier)
        #expect(applied.remoteSequence == 7)
        #expect(applied.brands == [Self.overlayBrand])

        // 3) 데이터 파일이 변조됨 → 번들 (서명 재검증)
        var tampered = data
        tampered.append(UInt8(ascii: " "))
        try tampered.write(to: SecurityDataFiles.dataURL(in: dir))
        #expect(DataStore.loadApplyingCachedUpdate(cacheDirectory: dir, verifier: fx.verifier).sourceDescription == DataStore.bundledSourceDescription)

        // 4) 공개키 없음(검증기 nil) → 번들
        try data.write(to: SecurityDataFiles.dataURL(in: dir))
        #expect(DataStore.loadApplyingCachedUpdate(cacheDirectory: dir, verifier: nil).sourceDescription == DataStore.bundledSourceDescription)
    }

    @Test("덮어쓴 블록리스트의 도메인은 RiskEngine에서 T01로 잡힌다")
    func engineUsesOverlayBlocklist() {
        let overlaid = RiskEngine(data: DataStore.bundled.applying(Self.overlay()))
        let bundled = RiskEngine(data: .bundled)
        let raw = "https://www.overlay-blocked.example.test/login"

        let report = overlaid.offlineReport(for: raw, context: TestSupport.camera)
        let finding = report.findings.first { $0.id == .T01 }
        #expect(finding != nil)
        #expect(finding?.evidence["provider"] == ThreatListHitRule.localProviderName)
        #expect(finding?.evidence["entry"] == "overlay-blocked.example.test")
        #expect(report.tier == .danger)
        #expect(report.score >= 90)

        #expect(!bundled.offlineReport(for: raw, context: TestSupport.camera).findings.contains { $0.id == .T01 })
    }
}
