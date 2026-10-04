import Foundation
import Testing
@testable import QRGuardCore

/// `Fixtures/cases.json` 회귀 테스트 (T-1.7). 형식은 RISK_RULES.md 6장.
struct FixtureCase: Decodable, Sendable, CustomTestStringConvertible {
    struct Context: Decodable, Sendable {
        var source: ScanSource? = nil
        var place: PlaceContext? = nil
        var distinctCodesInFrame: Int? = nil
    }
    /// 페이지 사전 검사 결과 중 V09가 읽는 필드만(T-8.1).
    struct Page: Decodable, Sendable {
        var hiddenText: String? = nil
        var invisibleCharacterCount: Int? = nil
    }
    struct Expect: Decodable, Sendable {
        var rules: [RuleID]? = nil
        var notRules: [RuleID]? = nil
        var tier: RiskTier? = nil
        var tierAtLeast: RiskTier? = nil
        var scoreMin: Int? = nil
        var scoreMax: Int? = nil
        var score: Int? = nil
        var blocksOpening: Bool? = nil
        var payloadKind: QRPayload.Kind? = nil
    }
    var name: String? = nil
    var input: String
    var context: Context? = nil
    /// 비전 신호(V01–V03). 없으면 스냅샷의 `vision`은 nil.
    var vision: VisionSignals? = nil
    /// 페이지 숨김 텍스트·불가시 문자 수(V09). 없으면 `page`는 nil.
    var page: Page? = nil
    var expect: Expect

    var testDescription: String { name ?? input }

    static func load() throws -> [FixtureCase] {
        guard let url = Bundle.module.url(forResource: "cases", withExtension: "json", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode([FixtureCase].self, from: Data(contentsOf: url))
    }
}

@Suite("Fixture regression (T-1.7)")
struct FixtureTests {
    static let cases: [FixtureCase] = (try? FixtureCase.load()) ?? []
    static let tierOrder: [RiskTier] = [.safe, .caution, .danger]

    @Test func fixturesLoadedAndEnough() throws {
        let cases = try FixtureCase.load()
        #expect(cases.count >= 60, "fixture count \(cases.count)")
        let covered = Set(cases.flatMap { $0.expect.rules ?? [] })
        // 오프라인에서 발동 가능한 규칙(P·U·B·C·T01)이 모두 최소 한 번은 양성으로 등장해야 한다.
        let offlineIDs: [RuleID] = [.P01, .P02, .P03, .P04, .P05, .P05a, .P06, .P07, .P08, .P09, .P10,
                                    .U01, .U02, .U03, .U04, .U05, .U06, .U07, .U08, .U09, .U10, .U11,
                                    .B01, .B02, .B03, .T01, .C01, .C02, .C03,
                                    .V01, .V02, .V03, .V09]
        for id in offlineIDs { #expect(covered.contains(id), "no positive fixture for \(id)") }
        #expect(cases.filter { $0.vision != nil }.count >= 6, "need ≥6 fixtures with a vision object")
    }

    @Test(arguments: cases)
    func runCase(_ c: FixtureCase) {
        let context = AnalysisContext(
            source: c.context?.source ?? .camera,
            place: c.context?.place,
            distinctCodesInFrame: c.context?.distinctCodesInFrame ?? 1,
            options: .offline
        )
        var snapshot = TestSupport.engine.offlineSnapshot(for: c.input)
        snapshot.vision = c.vision
        if let page = c.page {
            snapshot.page = PagePrecheckResult(hiddenText: page.hiddenText ?? "", invisibleCharacterCount: page.invisibleCharacterCount ?? 0)
        }
        let report = TestSupport.engine.report(snapshot: snapshot, context: context)
        let ids = TestSupport.ruleIDs(report)
        let summary = Comment(rawValue: "score=\(report.score) tier=\(report.tier) rules=\(report.findings.map(\.id.rawValue).sorted())")

        for id in c.expect.rules ?? [] { #expect(ids.contains(id), "expected \(id) — \(summary)") }
        for id in c.expect.notRules ?? [] { #expect(!ids.contains(id), "unexpected \(id) — \(summary)") }
        if let tier = c.expect.tier { #expect(report.tier == tier, summary) }
        if let atLeast = c.expect.tierAtLeast {
            #expect(Self.tierOrder.firstIndex(of: report.tier)! >= Self.tierOrder.firstIndex(of: atLeast)!, summary)
        }
        if let min = c.expect.scoreMin { #expect(report.score >= min, summary) }
        if let max = c.expect.scoreMax { #expect(report.score <= max, summary) }
        if let score = c.expect.score { #expect(report.score == score, summary) }
        if let blocks = c.expect.blocksOpening { #expect(report.blocksOpening == blocks, summary) }
        if let kind = c.expect.payloadKind { #expect(report.payloadKind == kind, summary) }

        // 공통 불변식
        #expect((0...100).contains(report.score))
        #expect(report.tier == RiskTier(score: report.score))
        #expect(report.coverage == .offlineOnly)
        #expect(Set(report.passedChecks).isDisjoint(with: ids), "passed ∩ fired must be empty")
        #expect(!report.passedChecks.contains(.B03))
        if report.blocksOpening { #expect(report.tier == .danger) }
    }
}
