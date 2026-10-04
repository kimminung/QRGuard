import Foundation
import os
import Testing
import QRGuardCore
@testable import QRGuardNetwork

// MARK: - 스텁 의존성

final class CallCounter: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0)
    var count: Int { value.withLock { $0 } }
    func increment() { value.withLock { $0 += 1 } }
}

struct StubReputationProvider: ReputationProvider {
    var name = "Stub Reputation"
    var isAvailable = true
    var verdict: ReputationVerdict = .clean
    var maliciousHosts: Set<String> = []
    var error: Bool = false
    var delay: Duration?
    let calls = CallCounter()

    func lookup(_ urls: [URL]) async throws -> [URL: ReputationVerdict] {
        calls.increment()
        if let delay { try await Task.sleep(for: delay) }
        if error { throw ReputationProviderError.httpStatus(500) }
        var result: [URL: ReputationVerdict] = [:]
        for url in urls {
            if let host = url.host, maliciousHosts.contains(host) {
                result[url] = .malicious(threatTypes: ["MALWARE"])
            } else {
                result[url] = verdict
            }
        }
        return result
    }
}

struct StubDomainInfo: DomainInfoProviding {
    var date: Date? = Calendar.current.date(byAdding: .year, value: -3, to: .now)
    var error = false
    var delay: Duration?
    let calls = CallCounter()

    func registrationDate(for registrableDomain: String) async throws -> Date? {
        calls.increment()
        if let delay { try await Task.sleep(for: delay) }
        if error { throw RDAPClient.RDAPError.httpStatus(500) }
        return date
    }
}

struct StubPagePrecheck: PagePrechecking {
    var result = PagePrecheckResult(contentType: "text/html")
    var error = false
    let calls = CallCounter()

    func precheck(_ url: URL, timeout: Duration) async throws -> PagePrecheckResult {
        calls.increment()
        if error { throw URLError(.badServerResponse) }
        return result
    }
}

struct HangingResolver: RedirectResolving {
    func resolve(_ url: URL, maxHops: Int, perHopTimeout: Duration, totalTimeout: Duration) async -> RedirectChain {
        try? await Task.sleep(for: .seconds(60))
        return RedirectChain(hops: [RedirectHop(order: 0, url: url, statusCode: nil)], outcome: .timedOut)
    }
}

// MARK: - 이벤트 수집

struct Collected {
    var events: [AnalysisEvent] = []
    var report: RiskReport?
    var snapshot: AnalysisSnapshot?
    var preliminary: RiskReport?

    func outcome(of step: AnalysisStep) -> StepOutcome? {
        for event in events {
            if case .stepFinished(let s, let outcome) = event, s == step { return outcome }
        }
        return nil
    }

    func started(_ step: AnalysisStep) -> Bool {
        events.contains { if case .stepStarted(let s) = $0 { return s == step } else { return false } }
    }
}

func collect(_ pipeline: AnalysisPipeline, _ raw: String, options: AnalysisOptions = .default) async -> Collected {
    var collected = Collected()
    let context = AnalysisContext(source: .camera, options: options)
    for await event in pipeline.analyze(raw, context: context) {
        collected.events.append(event)
        switch event {
        case .preliminary(let report): collected.preliminary = report
        case .finished(let report, let snapshot):
            collected.report = report
            collected.snapshot = snapshot
        default: break
        }
    }
    return collected
}

// MARK: - 테스트

@Suite("AnalysisPipeline (T-4.7)")
struct AnalysisPipelineTests {
    private func resolver(timeout: TimeInterval = 3) -> RedirectResolver {
        RedirectResolver(configuration: mockConfiguration(requestTimeout: timeout))
    }

    @Test("단축 URL → 다른 도메인: 체인 2, coverage full, 이벤트 순서")
    func shortenerChain() async throws {
        let short = MockHost("pipe-short")
        let landing = MockHost("pipe-landing")
        short.stub("/abc", .redirect(302, to: landing.url("/offer").absoluteString))
        landing.stub("/offer", .status(200, contentType: "text/html; charset=utf-8"))
        let reputation = StubReputationProvider()
        let domain = StubDomainInfo()
        let pipeline = AnalysisPipeline(dependencies: .init(
            redirectResolver: resolver(), reputationProviders: [reputation], domainInfo: domain, pagePrecheck: StubPagePrecheck()
        ))

        let result = await collect(pipeline, short.url("/abc").absoluteString)

        let snapshot = try #require(result.snapshot)
        let report = try #require(result.report)
        #expect(result.preliminary != nil)
        #expect(snapshot.chain?.hops.count == 2)
        #expect(snapshot.chain?.outcome == .completed)
        #expect(snapshot.chain?.finalContentType == "text/html; charset=utf-8")
        #expect(snapshot.finalURL?.host == landing.host)
        #expect(report.finalURL == landing.url("/offer"))
        #expect(snapshot.coverage == .full)
        #expect(report.coverage == .full)
        #expect(snapshot.reputation.count == 2)
        #expect(snapshot.reputation.allSatisfy { $0.provider == "Stub Reputation" && $0.verdict == .clean })
        #expect(snapshot.domainInfo?.registrationDate != nil)
        #expect(snapshot.domainInfo?.lookupFailed == false)
        #expect(snapshot.page == nil)

        #expect(result.outcome(of: .structure) != nil)
        #expect(result.outcome(of: .redirect) == .flagged(1))
        #expect(result.outcome(of: .reputation) == .passed)
        #expect(result.outcome(of: .domainAge) == .passed)
        #expect(result.outcome(of: .pagePrecheck) == .skipped)
        #expect(reputation.calls.count == 1)
        #expect(domain.calls.count == 1)

        // 순서: structure 시작·종료 → preliminary → redirect 시작·종료 → … → finished
        var order: [String] = []
        for event in result.events {
            switch event {
            case .stepStarted(let s): order.append("start:\(s.rawValue)")
            case .stepFinished(let s, _): order.append("end:\(s.rawValue)")
            case .preliminary: order.append("preliminary")
            case .finished: order.append("finished")
            }
        }
        #expect(order.prefix(5) == ["start:structure", "end:structure", "preliminary", "start:redirect", "end:redirect"])
        #expect(order.last == "finished")
        #expect(order.filter { $0 == "finished" }.count == 1)
    }

    @Test("리다이렉트 꺼짐: 요청 없음, redirect skipped, coverage full")
    func redirectsDisabled() async throws {
        let host = MockHost("pipe-noredirect")
        host.stubAll(.status(200, contentType: "text/html"))
        let pipeline = AnalysisPipeline(dependencies: .init(
            redirectResolver: resolver(), reputationProviders: [StubReputationProvider()], domainInfo: StubDomainInfo()
        ))
        let options = AnalysisOptions(followRedirects: false)

        let result = await collect(pipeline, host.url("/x").absoluteString, options: options)

        let snapshot = try #require(result.snapshot)
        #expect(host.requests.isEmpty)
        #expect(result.outcome(of: .redirect) == .skipped)
        #expect(!result.started(.redirect))
        #expect(snapshot.chain == nil)
        #expect(snapshot.finalURL?.original == host.url("/x"))
        #expect(snapshot.coverage == .full)
        #expect(snapshot.reputation.count == 1)
    }

    @Test("응답 없는 서버: redirect timedOut, coverage partial([.redirect]), 8초 이내")
    func hangingRedirect() async throws {
        let host = MockHost("pipe-hang")
        host.stubAll(.hanging)
        let pipeline = AnalysisPipeline(dependencies: .init(
            redirectResolver: resolver(timeout: 3), reputationProviders: [StubReputationProvider()], domainInfo: StubDomainInfo()
        ))
        let clock = ContinuousClock()
        let start = clock.now

        let result = await collect(pipeline, host.url("/slow").absoluteString)

        #expect(clock.now - start < .seconds(8))
        let snapshot = try #require(result.snapshot)
        #expect(result.outcome(of: .redirect) == .timedOut)
        #expect(snapshot.chain?.outcome == .timedOut)
        #expect(snapshot.coverage == .partial([.redirect]))
        #expect(result.outcome(of: .reputation) == .passed)
        #expect(result.outcome(of: .domainAge) == .passed)
    }

    @Test("리졸버 자체가 멈춰도 파이프라인 예산으로 끝낸다")
    func hangingResolverDependency() async throws {
        var budget = AnalysisPipeline.Budget()
        budget.redirectTotalTimeout = .milliseconds(300)
        let pipeline = AnalysisPipeline(
            dependencies: .init(redirectResolver: HangingResolver(), reputationProviders: [StubReputationProvider()], domainInfo: StubDomainInfo()),
            engine: RiskEngine(), budget: budget
        )
        let clock = ContinuousClock()
        let start = clock.now
        let result = await collect(pipeline, "https://pipe-hangdep.example.test/")
        #expect(clock.now - start < .seconds(3))
        #expect(result.outcome(of: .redirect) == .timedOut)
        #expect(result.snapshot?.coverage == .partial([.redirect]))
    }

    @Test("온라인 전부 꺼짐: offlineOnly, 어떤 의존성도 호출하지 않음")
    func offlineOptions() async throws {
        let host = MockHost("pipe-offline")
        host.stubAll(.status(200, contentType: "text/html"))
        let reputation = StubReputationProvider()
        let domain = StubDomainInfo()
        let page = StubPagePrecheck()
        let pipeline = AnalysisPipeline(dependencies: .init(
            redirectResolver: resolver(), reputationProviders: [reputation], domainInfo: domain, pagePrecheck: page
        ))

        let result = await collect(pipeline, host.url("/").absoluteString, options: .offline)

        #expect(result.snapshot?.coverage == .offlineOnly)
        #expect(result.report?.coverage == .offlineOnly)
        for step in [AnalysisStep.redirect, .reputation, .domainAge, .pagePrecheck] {
            #expect(result.outcome(of: step) == .skipped)
        }
        #expect(host.requests.isEmpty)
        #expect(reputation.calls.count == 0)
        #expect(domain.calls.count == 0)
        #expect(page.calls.count == 0)
    }

    @Test("URL이 아닌 페이로드(Wi-Fi)는 온라인 단계 없이 full")
    func nonURLPayload() async throws {
        let reputation = StubReputationProvider()
        let pipeline = AnalysisPipeline(dependencies: .init(redirectResolver: resolver(), reputationProviders: [reputation], domainInfo: StubDomainInfo()))
        let result = await collect(pipeline, "WIFI:T:WPA;S:cafe;P:secret;;")
        #expect(result.snapshot?.payload.kind == .wifi)
        #expect(result.snapshot?.coverage == .full)
        #expect(result.outcome(of: .redirect) == .skipped)
        #expect(result.outcome(of: .reputation) == .skipped)
        #expect(reputation.calls.count == 0)
    }

    @Test("평판 적중은 flagged(n)과 스냅샷에 기록")
    func reputationHit() async throws {
        let host = MockHost("pipe-malicious")
        host.stubAll(.status(200, contentType: "text/html"))
        let reputation = StubReputationProvider(name: "Google Safe Browsing", maliciousHosts: [host.host])
        let pipeline = AnalysisPipeline(dependencies: .init(redirectResolver: resolver(), reputationProviders: [reputation], domainInfo: StubDomainInfo()))

        let result = await collect(pipeline, host.url("/bad").absoluteString)

        #expect(result.outcome(of: .reputation) == .flagged(1))
        #expect(result.snapshot?.reputation.first?.verdict == .malicious(threatTypes: ["MALWARE"]))
        #expect(result.snapshot?.reputation.first?.provider == "Google Safe Browsing")
        #expect(result.snapshot?.coverage == .full)
    }

    @Test("키 없는 제공자는 호출하지 않고 reputation을 누락으로 기록")
    func unavailableProvider() async throws {
        let host = MockHost("pipe-nokey")
        host.stubAll(.status(200, contentType: "text/html"))
        let reputation = StubReputationProvider(isAvailable: false)
        let pipeline = AnalysisPipeline(dependencies: .init(redirectResolver: resolver(), reputationProviders: [reputation], domainInfo: StubDomainInfo()))

        let result = await collect(pipeline, host.url("/").absoluteString)

        #expect(reputation.calls.count == 0)
        #expect(result.outcome(of: .reputation) == .skipped)
        #expect(result.snapshot?.coverage == .partial([.reputation]))
    }

    @Test("제공자 오류·시간 초과는 partial([.reputation])")
    func providerFailureAndTimeout() async throws {
        let host = MockHost("pipe-repfail")
        host.stubAll(.status(200, contentType: "text/html"))
        let failing = AnalysisPipeline(dependencies: .init(
            redirectResolver: resolver(), reputationProviders: [StubReputationProvider(error: true)], domainInfo: StubDomainInfo()
        ))
        let failed = await collect(failing, host.url("/").absoluteString)
        #expect(failed.outcome(of: .reputation) == .failed)
        #expect(failed.snapshot?.coverage == .partial([.reputation]))

        var budget = AnalysisPipeline.Budget()
        budget.reputationTimeout = .milliseconds(200)
        let slow = AnalysisPipeline(
            dependencies: .init(redirectResolver: resolver(), reputationProviders: [StubReputationProvider(delay: .seconds(5))], domainInfo: StubDomainInfo()),
            engine: RiskEngine(), budget: budget
        )
        let clock = ContinuousClock()
        let start = clock.now
        let timedOut = await collect(slow, host.url("/").absoluteString)
        #expect(clock.now - start < .seconds(3))
        #expect(timedOut.outcome(of: .reputation) == .timedOut)
        #expect(timedOut.snapshot?.coverage == .partial([.reputation]))
    }

    @Test("URLhaus는 urlhausLookup이 켜진 경우에만 호출")
    func urlhausGating() async throws {
        let host = MockHost("pipe-urlhaus")
        host.stubAll(.status(200, contentType: "text/html"))
        let safeBrowsing = StubReputationProvider(name: "Google Safe Browsing")
        let urlhaus = StubReputationProvider(name: URLhausProvider.providerName)
        let pipeline = AnalysisPipeline(dependencies: .init(
            redirectResolver: resolver(), reputationProviders: [safeBrowsing, urlhaus], domainInfo: StubDomainInfo()
        ))

        _ = await collect(pipeline, host.url("/").absoluteString, options: AnalysisOptions(urlhausLookup: false))
        #expect(safeBrowsing.calls.count == 1)
        #expect(urlhaus.calls.count == 0)

        let both = await collect(pipeline, host.url("/").absoluteString, options: AnalysisOptions(urlhausLookup: true))
        #expect(safeBrowsing.calls.count == 2)
        #expect(urlhaus.calls.count == 1)
        #expect(both.snapshot?.reputation.map(\.provider).sorted() == ["Google Safe Browsing", "URLhaus"])

        let onlyURLhaus = await collect(pipeline, host.url("/").absoluteString, options: AnalysisOptions(reputationLookup: false, urlhausLookup: true))
        #expect(safeBrowsing.calls.count == 2)
        #expect(urlhaus.calls.count == 2)
        #expect(onlyURLhaus.snapshot?.coverage == .full)
    }

    @Test("도메인 조회 실패는 lookupFailed + partial([.domainAge])")
    func domainLookupFailure() async throws {
        let host = MockHost("pipe-rdapfail")
        host.stubAll(.status(200, contentType: "text/html"))
        let pipeline = AnalysisPipeline(dependencies: .init(
            redirectResolver: resolver(), reputationProviders: [StubReputationProvider()], domainInfo: StubDomainInfo(error: true)
        ))
        let result = await collect(pipeline, host.url("/").absoluteString)
        #expect(result.outcome(of: .domainAge) == .failed)
        #expect(result.snapshot?.domainInfo?.lookupFailed == true)
        #expect(result.snapshot?.domainInfo?.registrationDate == nil)
        #expect(result.snapshot?.coverage == .partial([.domainAge]))

        let young = AnalysisPipeline(dependencies: .init(
            redirectResolver: resolver(), reputationProviders: [StubReputationProvider()],
            domainInfo: StubDomainInfo(date: Calendar.current.date(byAdding: .day, value: -10, to: .now))
        ))
        let youngResult = await collect(young, host.url("/").absoluteString)
        #expect(youngResult.outcome(of: .domainAge) == .flagged(1))
        #expect(youngResult.snapshot?.coverage == .full)
    }

    @Test("도메인 조회 꺼짐: 호출 없음, domainInfo는 lookupFailed=false")
    func domainLookupDisabled() async throws {
        let host = MockHost("pipe-rdapoff")
        host.stubAll(.status(200, contentType: "text/html"))
        let domain = StubDomainInfo()
        let pipeline = AnalysisPipeline(dependencies: .init(redirectResolver: resolver(), reputationProviders: [StubReputationProvider()], domainInfo: domain))
        let result = await collect(pipeline, host.url("/").absoluteString, options: AnalysisOptions(domainAgeLookup: false))
        #expect(domain.calls.count == 0)
        #expect(result.outcome(of: .domainAge) == .skipped)
        #expect(result.snapshot?.domainInfo?.lookupFailed == false)
        #expect(result.snapshot?.coverage == .full)
    }

    @Test("페이지 사전 검사: meta refresh 홉 추가, Content-Type 승격")
    func pagePrecheckEnrichesChain() async throws {
        let host = MockHost("pipe-page")
        host.stubAll(.status(200))   // Content-Type 없음
        let target = URL(string: "https://pipe-page-target.example.test/next")!
        let page = StubPagePrecheck(result: PagePrecheckResult(
            hasPasswordInput: true, title: "Login", metaRefreshTarget: target, contentType: "text/html; charset=utf-8", bytesRead: 1200
        ))
        let pipeline = AnalysisPipeline(dependencies: .init(
            redirectResolver: resolver(), reputationProviders: [StubReputationProvider()], domainInfo: StubDomainInfo(), pagePrecheck: page
        ))

        let result = await collect(pipeline, host.url("/").absoluteString, options: AnalysisOptions(pagePrecheck: true))

        let snapshot = try #require(result.snapshot)
        #expect(page.calls.count == 1)
        #expect(result.outcome(of: .pagePrecheck) == .flagged(2))
        #expect(snapshot.page?.hasPasswordInput == true)
        #expect(snapshot.chain?.hops.count == 2)
        #expect(snapshot.chain?.hops.last?.viaMetaRefresh == true)
        #expect(snapshot.chain?.hops.last?.url == target)
        #expect(snapshot.chain?.hops.last?.statusCode == nil)
        #expect(snapshot.chain?.finalContentType == "text/html; charset=utf-8")
        #expect(snapshot.finalURL?.host == "pipe-page-target.example.test")
        #expect(result.report?.finalURL == target)
        #expect(snapshot.coverage == .full)
    }

    @Test("페이지 사전 검사 꺼짐(기본)에서는 호출하지 않고 누락으로도 세지 않는다")
    func pagePrecheckDisabledByDefault() async throws {
        let host = MockHost("pipe-pageoff")
        host.stubAll(.status(200, contentType: "text/html"))
        let page = StubPagePrecheck()
        let pipeline = AnalysisPipeline(dependencies: .init(
            redirectResolver: resolver(), reputationProviders: [StubReputationProvider()], domainInfo: StubDomainInfo(), pagePrecheck: page
        ))
        let result = await collect(pipeline, host.url("/").absoluteString)
        #expect(page.calls.count == 0)
        #expect(result.outcome(of: .pagePrecheck) == .skipped)
        #expect(result.snapshot?.coverage == .full)
    }

    @Test("http:// 원문: 요청 없이 stoppedAtInsecureHop, redirect 누락")
    func insecureOriginal() async throws {
        let reputation = StubReputationProvider()
        let page = StubPagePrecheck()
        let pipeline = AnalysisPipeline(dependencies: .init(
            redirectResolver: resolver(), reputationProviders: [reputation], domainInfo: StubDomainInfo(), pagePrecheck: page
        ))
        let result = await collect(pipeline, "http://pipe-insecure.example.test/login", options: AnalysisOptions(pagePrecheck: true))

        #expect(MockURLProtocol.registry.requests(host: "pipe-insecure.example.test").isEmpty)
        #expect(result.snapshot?.chain?.outcome == .stoppedAtInsecureHop)
        // 이동이 하나도 기록되지 않았으므로 "N번 이동"이 아니라 "확인 못 함"으로 보고한다.
        #expect(result.outcome(of: .redirect) == .failed)
        #expect(result.outcome(of: .pagePrecheck) == .skipped)
        #expect(page.calls.count == 0)
        #expect(reputation.calls.count == 1)
        #expect(result.snapshot?.coverage == .partial([.redirect, .pagePrecheck]))
    }

    @Test("의존성 없는 오프라인 파이프라인도 finished로 끝난다")
    func offlinePipelineFinishes() async throws {
        let result = await collect(AnalysisPipeline.offline(), "https://pipe-nodeps.example.test/")
        #expect(result.report != nil)
        #expect(result.snapshot?.coverage == .partial([.redirect, .reputation, .domainAge]))
        #expect(result.outcome(of: .redirect) == .skipped)
    }

    @Test("live 파이프라인 구성: 키 없으면 Safe Browsing 비활성")
    func liveWiring() async {
        let pipeline = AnalysisPipeline.live(safeBrowsingAPIKey: nil)
        let deps = pipeline.dependencies
        #expect(deps.redirectResolver is RedirectResolver)
        #expect(deps.domainInfo is RDAPClient)
        #expect(deps.pagePrecheck is PagePrecheck)
        #expect(deps.reputationProviders.count == 2)
        #expect(deps.reputationProviders.first { $0.name == SafeBrowsingV5Provider.providerName }?.isAvailable == false)
        #expect(deps.reputationProviders.first { $0.name == URLhausProvider.providerName }?.isAvailable == true)

        let keyed = AnalysisPipeline.live(safeBrowsingAPIKey: "abc")
        #expect(keyed.dependencies.reputationProviders.first { $0.name == SafeBrowsingV5Provider.providerName }?.isAvailable == true)
    }

    @Test("소비자가 취소하면 스트림이 끝나고 추가 요청을 보내지 않는다")
    func consumerCancellation() async throws {
        let host = MockHost("pipe-cancel")
        host.stubAll(.hanging)
        let reputation = StubReputationProvider()
        let pipeline = AnalysisPipeline(dependencies: .init(redirectResolver: resolver(), reputationProviders: [reputation], domainInfo: StubDomainInfo()))
        let context = AnalysisContext(source: .camera)

        let task = Task {
            var count = 0
            for await event in pipeline.analyze(host.url("/").absoluteString, context: context) {
                count += 1
                if case .stepStarted(.redirect) = event { break }
            }
            return count
        }
        let count = await task.value
        #expect(count >= 4)
        try await Task.sleep(for: .milliseconds(300))
        #expect(reputation.calls.count == 0)
    }
}
