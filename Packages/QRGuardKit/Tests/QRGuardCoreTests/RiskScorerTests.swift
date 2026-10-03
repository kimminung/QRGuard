import Foundation
import Testing
@testable import QRGuardCore

@Suite("RiskScorer (T-1.6)")
struct RiskScorerTests {
    let scorer = RiskScorer()
    private func f(_ id: RuleID, _ points: Int, floor: Int? = nil, blocks: Bool = false) -> RiskFinding {
        RiskFinding(id: id, points: points, floor: floor, blocksOpening: blocks)
    }

    @Test func emptyIsSafeZero() {
        let r = scorer.score([])
        #expect(r.score == 0)
        #expect(r.tier == .safe)
        #expect(!r.blocksOpening)
    }

    @Test func tierBoundaries29and30() {
        // P 계열은 상한이 없으므로 임의 점수로 경계를 만든다.
        #expect(scorer.score([f(.P05, 29)]).tier == .safe)
        #expect(scorer.score([f(.P05, 29)]).score == 29)
        #expect(scorer.score([f(.P05, 30)]).tier == .caution)
        #expect(scorer.score([f(.U01, 15), f(.U04, 10), f(.B01, 4)]).tier == .safe)
        #expect(scorer.score([f(.U01, 15), f(.U04, 10), f(.B01, 5)]).tier == .caution)
    }

    @Test func tierBoundaries69and70() {
        #expect(scorer.score([f(.B01, 30), f(.B02, 35), f(.P05, 4)]).score == 69)
        #expect(scorer.score([f(.B01, 30), f(.B02, 35), f(.P05, 4)]).tier == .caution)
        #expect(scorer.score([f(.B01, 30), f(.B02, 35), f(.P05, 5)]).score == 70)
        #expect(scorer.score([f(.B01, 30), f(.B02, 35), f(.P05, 5)]).tier == .danger)
    }

    @Test func floorOverridesLowSum() {
        let r = scorer.score([f(.T01, 0, floor: 90), f(.U01, 15)])
        #expect(r.score == 90)
        #expect(r.tier == .danger)
        #expect(r.findings.first?.id == .T01)
    }

    @Test func floorDoesNotLowerHigherSum() {
        let r = scorer.score([f(.P09, 0, floor: 40), f(.B01, 30), f(.B02, 35)])
        #expect(r.score == 65)
    }

    @Test func blocksOpening() {
        let r = scorer.score([f(.P02, 0, floor: 95, blocks: true)])
        #expect(r.score == 95)
        #expect(r.blocksOpening)
        #expect(r.tier == .danger)
    }

    @Test func categoryCaps() {
        // U 합계 95 → 45
        let u = scorer.score([f(.U01, 15), f(.U02, 20), f(.U03, 25), f(.U04, 10), f(.U09, 15), f(.U10, 10)])
        #expect(u.score == 45)
        // H 합계 85 → 40
        let h = scorer.score([f(.H01, 15), f(.H02, 20), f(.H03, 20), f(.H05, 30)])
        #expect(h.score == 40)
        // C 합계 50 → 30
        let c = scorer.score([f(.C01, 20), f(.C02, 15), f(.C03, 15)])
        #expect(c.score == 30)
        // 상한은 카테고리별로 따로 적용된다.
        let mixed = scorer.score([f(.U01, 15), f(.U02, 20), f(.U03, 25), f(.C01, 20), f(.C02, 15)])
        #expect(mixed.score == 45 + 30)
    }

    @Test func b03Adjustment() {
        let r = scorer.score([f(.B03, -20)])
        #expect(r.score == 0)
        #expect(r.tier == .safe)
        #expect(r.findings.map(\.id) == [.B03])
        let r2 = scorer.score([f(.B03, -20), f(.U10, 10), f(.U01, 15)])
        #expect(r2.score == 5)
    }

    @Test func b03IgnoredWithT01() {
        let r = scorer.score([f(.T01, 0, floor: 90), f(.B03, -20)])
        #expect(r.score == 90)
        #expect(!r.findings.contains { $0.id == .B03 })
    }

    @Test func b03IgnoredWithU09() {
        let r = scorer.score([f(.U09, 15), f(.B03, -20)])
        #expect(r.score == 15)
        #expect(!r.findings.contains { $0.id == .B03 })
    }

    @Test func duplicatesCountOnce() {
        let r = scorer.score([f(.U10, 10), f(.U10, 10), f(.U10, 10)])
        #expect(r.score == 10)
        #expect(r.findings.count == 1)
    }

    @Test func clampAt100() {
        let r = scorer.score([f(.B01, 30), f(.B02, 35), f(.P05, 20), f(.P06, 30), f(.P07, 25)])
        #expect(r.score == 100)
    }

    @Test func sortingFloorFirstThenPoints() {
        let r = scorer.score([f(.U01, 15), f(.B03, -20), f(.T01, 0, floor: 90), f(.B02, 35), f(.D03, 0)])
        // T01은 B03 때문에 제외되므로 B03 없이 정렬 확인
        #expect(r.findings.map(\.id) == [.T01, .B02, .U01, .D03])
    }

    @Test func specWorkedExamples() {
        // naver.com → B03 → 0 안전
        #expect(scorer.score([f(.B03, -20)]).score == 0)
        // bit.ly → event-gift.site : U11 + U08 + D01 = 45 주의
        let ex2 = scorer.score([f(.U11, 10), f(.U08, 10), f(.D01, 25)])
        #expect(ex2.score == 45 && ex2.tier == .caution)
        // t.ly → naver-login.account-check.xyz (메일): T01 floor 90 + B01 30 + H01 15 + C02 15 + U08 10 + U10 10 + U11 10 = 90 위험
        let ex3 = scorer.score([f(.T01, 0, floor: 90), f(.B01, 30), f(.H01, 15), f(.C02, 15), f(.U08, 10), f(.U10, 10), f(.U11, 10)])
        #expect(ex3.score == 90 && ex3.tier == .danger)
        // itms-services → P02 floor 95 차단
        let ex4 = scorer.score([f(.P02, 0, floor: 95, blocks: true)])
        #expect(ex4.score == 95 && ex4.blocksOpening)
    }
}
