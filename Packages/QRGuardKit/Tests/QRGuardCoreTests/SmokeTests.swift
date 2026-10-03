import Foundation
import Testing
@testable import QRGuardCore

@Suite struct SmokeTests {
    @Test func tierBoundaries() {
        #expect(RiskTier(score: 29) == .safe)
        #expect(RiskTier(score: 30) == .caution)
        #expect(RiskTier(score: 69) == .caution)
        #expect(RiskTier(score: 70) == .danger)
    }

    @Test func bundledDataLoads() {
        let d = DataStore.bundled
        #expect(d.brands.count >= 40)
        #expect(d.shorteners.contains("bit.ly"))
        #expect(!d.shorteners.contains("youtu.be"))
        #expect(d.suspiciousTLDs.contains("xyz") && !d.suspiciousTLDs.contains("shop"))
        #expect(d.appSchemes.contains { $0.scheme == "kakaotalk" })
        #expect(d.paymentMobilityDomains.contains("kakaomobility.com"))
        #expect(d.blocklist.domains.contains("malware.example.test"))
        #expect(d.confusables[Character("а")] == "a")    // 키릴 а
        #expect(d.confusables[Character("ο")] == "o")    // 그리스 ο
        #expect(d.publicSuffixRules.count > 10_000)
        #expect(d.baitKeywords.contains("인증") && d.baitKeywords.contains("login"))
    }

    @Test func emptyDataStoreDoesNotCrash() {
        let engine = RiskEngine(data: .empty)
        let report = engine.offlineReport(for: "https://naver-login.example.test/verify", context: AnalysisContext(source: .paste))
        #expect(report.score >= 0)
        #expect(!TestSupport.ruleIDs(report).contains(.B01))   // 브랜드 데이터 없음
    }

    @Test func reportShapeForOfficialDomain() {
        let report = TestSupport.report("https://www.naver.com/")
        #expect(report.score == 0)
        #expect(report.tier == .safe)
        #expect(report.findings.map(\.id) == [.B03])
        #expect(report.positiveFindings.count == 1)
        #expect(report.riskFindings.isEmpty)
        #expect(report.passedChecks.contains(.U01) && report.passedChecks.contains(.U03))
        #expect(!report.passedChecks.contains(.P06))     // Wi-Fi 규칙은 URL에 적용되지 않음
        #expect(report.originalURL?.host() == "www.naver.com")
        #expect(report.domain?.registrableDomain == "naver.com")
        #expect(report.payloadKind == .url)
    }

    @Test func offlineReportIsFast() {
        let engine = TestSupport.engine
        let ctx = AnalysisContext(source: .camera, place: .emailOrMessage, options: .offline)
        let inputs = [
            "https://naver-login.account-check.xyz/verify?next=https%3A%2F%2Fevil.example.invalid%2F",
            "https://www.naver.com/",
            "http://user@192.168.0.1:8080/login",
            "WIFI:T:nopass;S:Free;;",
            "https://xn--navr-x4d.com/",
        ]
        _ = engine.offlineReport(for: inputs[0], context: ctx) // warm-up
        let start = ContinuousClock.now
        for i in 0..<100 { _ = engine.offlineReport(for: inputs[i % inputs.count], context: ctx) }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(1), "100 offline reports took \(elapsed)")
    }
}
