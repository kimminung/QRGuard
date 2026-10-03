import Foundation
import Testing
@testable import QRGuardCore

/// 테스트 공용 도우미.
enum TestSupport {
    static let engine = RiskEngine(data: .bundled)
    static let data = DataStore.bundled
    static let camera = AnalysisContext(source: .camera, options: .offline)

    static func normalized(_ string: String) -> NormalizedURL? {
        URLNormalizer.normalize(string: string, data: data)
    }

    static func snapshot(_ raw: String) -> AnalysisSnapshot {
        engine.offlineSnapshot(for: raw)
    }

    static func input(_ raw: String, context: AnalysisContext = camera, prior: [RiskFinding] = [], now: Date = .now) -> RuleInput {
        RuleInput(snapshot: snapshot(raw), context: context, priorFindings: prior, data: data, now: now)
    }

    static func input(snapshot: AnalysisSnapshot, context: AnalysisContext = camera, prior: [RiskFinding] = [], now: Date = .now) -> RuleInput {
        RuleInput(snapshot: snapshot, context: context, priorFindings: prior, data: data, now: now)
    }

    static func report(_ raw: String, context: AnalysisContext = camera) -> RiskReport {
        engine.offlineReport(for: raw, context: context)
    }

    static func ruleIDs(_ report: RiskReport) -> Set<RuleID> { Set(report.findings.map(\.id)) }

    static func chain(_ urls: [String], outcome: RedirectChain.Outcome = .completed, contentType: String? = nil, metaRefreshAt: Int? = nil) -> RedirectChain {
        let hops = urls.enumerated().map { i, s in
            RedirectHop(order: i, url: URL(string: s)!, statusCode: i == urls.count - 1 ? 200 : 302, viaMetaRefresh: metaRefreshAt == i)
        }
        return RedirectChain(hops: hops, outcome: outcome, finalContentType: contentType, finalStatusCode: 200)
    }

    /// 체인이 있는 스냅샷. `finalURL`은 체인의 마지막 홉으로 정규화한다.
    static func snapshot(_ raw: String, chain: RedirectChain?, domainInfo: DomainInfo? = nil,
                         reputation: [ReputationLookup] = [], page: PagePrecheckResult? = nil) -> AnalysisSnapshot {
        var s = snapshot(raw)
        s.chain = chain
        if let last = chain?.finalURL { s.finalURL = URLNormalizer.normalize(last, data: data) }
        s.domainInfo = domainInfo
        s.reputation = reputation
        s.page = page
        return s
    }

    static func daysAgo(_ days: Int, from now: Date) -> Date {
        Calendar(identifier: .gregorian).date(byAdding: .day, value: -days, to: now)!
    }
}
