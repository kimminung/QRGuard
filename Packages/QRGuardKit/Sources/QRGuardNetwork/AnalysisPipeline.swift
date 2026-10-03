import Foundation
import QRGuardCore

/// 분석 파이프라인 (TECH_PRD 4장, TASKS T-4.7).
///
/// 순서: 구조 분석(오프라인) → `.preliminary` → 리다이렉트 추적(최종 주소 확정) →
/// 평판·도메인 생성일·페이지 사전 검사를 `withTaskGroup`으로 병렬 수행(각각 개별 타임아웃) → `.finished`.
/// 설정에서 꺼진 검사는 어떤 요청도 보내지 않고 `.skipped`로 보고한다.
///
/// 확인 범위(coverage) 규칙:
/// - 온라인 토글이 전부 꺼져 있으면 `.offlineOnly`.
/// - URL이 아닌 페이로드(Wi-Fi·전화 등)나 웹이 아닌 스킴은 더 확인할 것이 없으므로 `.full`.
/// - 사용자가 **켠** 검사 중 실패·시간 초과·수행 불가(키 없음, `http://` 홉에서 중단 등)한 항목만 `.partial([...])`에 넣는다.
///   꺼둔 검사는 누락으로 세지 않는다.
public actor AnalysisPipeline {
    public struct Dependencies: Sendable {
        public var redirectResolver: (any RedirectResolving)?
        public var reputationProviders: [any ReputationProvider]
        public var domainInfo: (any DomainInfoProviding)?
        public var pagePrecheck: (any PagePrechecking)?

        public init(
            redirectResolver: (any RedirectResolving)? = nil,
            reputationProviders: [any ReputationProvider] = [],
            domainInfo: (any DomainInfoProviding)? = nil,
            pagePrecheck: (any PagePrechecking)? = nil
        ) {
            self.redirectResolver = redirectResolver
            self.reputationProviders = reputationProviders
            self.domainInfo = domainInfo
            self.pagePrecheck = pagePrecheck
        }
    }

    /// 단계별 시간 예산. 최악의 경우 리다이렉트 6초 + 병렬 단계 4초 ≈ 10초 안에 끝난다.
    public struct Budget: Sendable, Hashable {
        public var maxHops: Int = 10
        public var perHopTimeout: Duration = .seconds(3)
        public var redirectTotalTimeout: Duration = .seconds(6)
        public var reputationTimeout: Duration = .seconds(4)
        public var domainAgeTimeout: Duration = .seconds(3)
        public var pagePrecheckTimeout: Duration = .seconds(4)
        /// D01/D02 경계: 이 일수 미만이면 분석 중 화면에 "발견"으로 표시
        public var youngDomainDays: Int = 180

        public init() {}
        public static let `default` = Budget()
    }

    public nonisolated let engine: RiskEngine
    public nonisolated let dependencies: Dependencies
    public nonisolated let budget: Budget

    public init(dependencies: Dependencies = Dependencies(), engine: RiskEngine = RiskEngine()) {
        self.init(dependencies: dependencies, engine: engine, budget: .default)
    }

    public init(dependencies: Dependencies, engine: RiskEngine, budget: Budget) {
        self.dependencies = dependencies
        self.engine = engine
        self.budget = budget
    }

    /// 실제 서비스에 연결된 파이프라인. 키가 없으면 Safe Browsing Provider는 비활성(요청 없음)이며 coverage가 partial이 된다.
    /// URLhaus는 `options.urlhausLookup`이 켜진 경우에만 호출된다.
    public static func live(safeBrowsingAPIKey: String?, engine: RiskEngine = RiskEngine()) -> AnalysisPipeline {
        AnalysisPipeline(
            dependencies: Dependencies(
                redirectResolver: RedirectResolver(),
                reputationProviders: [
                    SafeBrowsingV5Provider(apiKey: safeBrowsingAPIKey),
                    URLhausProvider(authKey: nil, enabled: true),
                ],
                domainInfo: RDAPClient(),
                pagePrecheck: PagePrecheck()
            ),
            engine: engine
        )
    }

    /// 의존성이 전혀 없는 오프라인 파이프라인(미리보기·테스트).
    public static func offline(engine: RiskEngine = RiskEngine()) -> AnalysisPipeline {
        AnalysisPipeline(dependencies: Dependencies(), engine: engine)
    }

    /// 분석을 시작하고 이벤트 스트림을 돌려준다. 소비자가 취소하지 않는 한 항상 `.finished`로 끝난다.
    public nonisolated func analyze(_ raw: String, context: AnalysisContext) -> AsyncStream<AnalysisEvent> {
        AsyncStream { continuation in
            let task = Task {
                await self.run(raw: raw, context: context, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 실행

    private func run(raw: String, context: AnalysisContext, continuation: AsyncStream<AnalysisEvent>.Continuation) async {
        let options = context.options

        // 1. 구조 분석 (오프라인)
        continuation.yield(.stepStarted(.structure))
        var snapshot = engine.offlineSnapshot(for: raw)
        let preliminary = engine.report(snapshot: snapshot, context: context)
        let offlineRisks = preliminary.riskFindings.count
        continuation.yield(.stepFinished(.structure, offlineRisks == 0 ? .passed : .flagged(offlineRisks)))
        continuation.yield(.preliminary(preliminary))

        // 2. 온라인 단계 계획
        guard options.anyOnline else {
            skipAll(continuation)
            snapshot.coverage = .offlineOnly
            continuation.yield(.finished(engine.report(snapshot: snapshot, context: context), snapshot))
            return
        }
        guard let url = snapshot.url, url.isWeb else {
            // URL이 아니거나 웹이 아닌 스킴: 온라인으로 더 확인할 것이 없다.
            skipAll(continuation)
            snapshot.coverage = .full
            continuation.yield(.finished(engine.report(snapshot: snapshot, context: context), snapshot))
            return
        }

        let runner = OnlineRunner(dependencies: dependencies, budget: budget)
        var missing: [CheckID] = []

        // 3. 리다이렉트 추적 (최종 주소를 정하므로 먼저)
        var chain: RedirectChain?
        if options.followRedirects {
            if dependencies.redirectResolver != nil {
                continuation.yield(.stepStarted(.redirect))
                let resolved = await runner.resolveChain(url.original)
                chain = resolved
                let outcome: StepOutcome
                switch resolved.outcome {
                case .completed:
                    outcome = resolved.redirectCount == 0 ? .passed : .flagged(resolved.redirectCount)
                case .timedOut:
                    outcome = .timedOut
                    missing.append(.redirect)
                case .failed, .tlsFailure:
                    outcome = .failed
                    missing.append(.redirect)
                case .stoppedAtInsecureHop, .blockedPrivateAddress, .loopDetected, .tooManyHops:
                    // 이동이 하나도 기록되지 않았으면(예: 사설·예약 주소라 요청 자체를 안 함) "N번 이동" 대신 "확인 못 함"으로 보여준다.
                    outcome = resolved.redirectCount == 0 ? .failed : .flagged(resolved.redirectCount)
                    missing.append(.redirect)
                }
                continuation.yield(.stepFinished(.redirect, outcome))
            } else {
                missing.append(.redirect)
                continuation.yield(.stepFinished(.redirect, .skipped))
            }
        } else {
            continuation.yield(.stepFinished(.redirect, .skipped))
        }

        if Task.isCancelled { return }

        snapshot.chain = chain
        var finalURL = chain?.finalURL.flatMap { URLNormalizer.normalize($0, data: engine.data) } ?? url
        snapshot.finalURL = finalURL

        // 4. 병렬 단계 계획
        let providers = dependencies.reputationProviders.filter { provider in
            guard provider.isAvailable else { return false }
            return Self.isURLhaus(provider) ? options.urlhausLookup : options.reputationLookup
        }
        let wantsReputation = options.reputationLookup || options.urlhausLookup
        let runReputation = wantsReputation && !providers.isEmpty
        if wantsReputation, !runReputation { missing.append(.reputation) }

        let registrable = finalURL.registrableDomain
        let domainApplicable = registrable != nil && !finalURL.isIPAddress
        let runDomainAge = options.domainAgeLookup && dependencies.domainInfo != nil && domainApplicable
        if options.domainAgeLookup, domainApplicable, dependencies.domainInfo == nil { missing.append(.domainAge) }

        let chainReachedFinal = chain.map { $0.outcome == .completed } ?? true
        let pageTarget = chain?.finalURL ?? url.original
        let pageApplicable = chainReachedFinal && pageTarget.scheme?.lowercased() == "https"
        let runPage = options.pagePrecheck && dependencies.pagePrecheck != nil
        if options.pagePrecheck, !(runPage && pageApplicable) { missing.append(.pagePrecheck) }

        var urlsToCheck: [URL] = []
        for candidate in (chain?.hops.map(\.url) ?? [url.original]) where !urlsToCheck.contains(candidate) {
            urlsToCheck.append(candidate)
        }

        var plan: [OnlineRunner.Job] = []
        if runReputation { plan.append(.reputation(urls: urlsToCheck, providers: providers)) }
        if runDomainAge, let registrable { plan.append(.domainAge(registrable)) }
        if runPage, pageApplicable { plan.append(.pagePrecheck(pageTarget)) }

        for step in [AnalysisStep.reputation, .domainAge, .pagePrecheck] where !plan.contains(where: { $0.step == step }) {
            continuation.yield(.stepFinished(step, .skipped))
        }
        for job in plan { continuation.yield(.stepStarted(job.step)) }

        // 5. 병렬 실행 + 결과 반영
        var registrationDate: Date?
        var domainLookupFailed = false
        var pageResult: PagePrecheckResult?

        await withTaskGroup(of: OnlineRunner.Result.self) { group in
            for job in plan {
                group.addTask { await runner.perform(job) }
            }
            for await result in group {
                switch result {
                case .reputation(let lookups, let failed, let timedOut):
                    snapshot.reputation.append(contentsOf: lookups)
                    let hits = lookups.filter(\.verdict.isMalicious).count
                    if failed || timedOut { missing.append(.reputation) }
                    let outcome: StepOutcome = hits > 0 ? .flagged(hits) : timedOut ? .timedOut : failed ? .failed : .passed
                    continuation.yield(.stepFinished(.reputation, outcome))

                case .domainAge(let date, let failed, let timedOut):
                    registrationDate = date
                    domainLookupFailed = date == nil
                    if date == nil { missing.append(.domainAge) }
                    let outcome: StepOutcome
                    if let date {
                        let days = Calendar(identifier: .gregorian).dateComponents([.day], from: date, to: .now).day ?? Int.max
                        outcome = days < budget.youngDomainDays ? .flagged(1) : .passed
                    } else {
                        outcome = timedOut ? .timedOut : .failed
                    }
                    _ = failed
                    continuation.yield(.stepFinished(.domainAge, outcome))

                case .pagePrecheck(let page, _, let timedOut):
                    pageResult = page
                    if page == nil { missing.append(.pagePrecheck) }
                    let outcome: StepOutcome
                    if let page {
                        var flags = 0
                        if page.hasPasswordInput { flags += 1 }
                        if page.tlsFailed { flags += 1 }
                        if page.metaRefreshTarget != nil { flags += 1 }
                        outcome = flags > 0 ? .flagged(flags) : .passed
                    } else {
                        outcome = timedOut ? .timedOut : .failed
                    }
                    continuation.yield(.stepFinished(.pagePrecheck, outcome))
                }
            }
        }

        if Task.isCancelled { return }

        // 6. 페이지 결과 → 체인 보강 (R05 meta refresh, P03/P04 Content-Type)
        if let page = pageResult {
            snapshot.page = page
            var updated = snapshot.chain ?? RedirectChain(
                hops: [RedirectHop(order: 0, url: pageTarget, statusCode: nil)],
                outcome: .completed
            )
            if updated.finalContentType == nil, let contentType = page.contentType {
                updated.finalContentType = contentType
            }
            if let target = page.metaRefreshTarget,
               let last = updated.hops.last,
               RedirectResolver.visitKey(target) != RedirectResolver.visitKey(last.url) {
                updated.hops.append(RedirectHop(order: updated.hops.count, url: target, statusCode: nil, viaMetaRefresh: true))
                finalURL = URLNormalizer.normalize(target, data: engine.data) ?? finalURL
                snapshot.finalURL = finalURL
            }
            snapshot.chain = updated
        }

        // 7. 도메인 정보 (항상 최종 URL 기준으로 구성)
        if let registrable = finalURL.registrableDomain {
            snapshot.domainInfo = DomainInfo(
                registrableDomain: registrable,
                unicodeHost: finalURL.unicodeHost,
                punycodeHost: finalURL.isIDN ? finalURL.host : nil,
                registrationDate: runDomainAge ? registrationDate : nil,
                lookupFailed: runDomainAge && domainLookupFailed
            )
        }

        // 8. 범위 확정 + 최종 보고서
        var uniqueMissing: [CheckID] = []
        for id in missing where !uniqueMissing.contains(id) { uniqueMissing.append(id) }
        snapshot.coverage = uniqueMissing.isEmpty ? .full : .partial(uniqueMissing)
        snapshot.analyzedAt = .now
        continuation.yield(.finished(engine.report(snapshot: snapshot, context: context), snapshot))
    }

    private func skipAll(_ continuation: AsyncStream<AnalysisEvent>.Continuation) {
        for step in [AnalysisStep.redirect, .reputation, .domainAge, .pagePrecheck] {
            continuation.yield(.stepFinished(step, .skipped))
        }
    }

    private static func isURLhaus(_ provider: any ReputationProvider) -> Bool {
        provider is URLhausProvider || provider.name == URLhausProvider.providerName
    }
}

// MARK: - 온라인 단계 실행기 (actor 밖에서 병렬로 돈다)

private struct OnlineRunner: Sendable {
    enum Job: Sendable {
        case reputation(urls: [URL], providers: [any ReputationProvider])
        case domainAge(String)
        case pagePrecheck(URL)

        var step: AnalysisStep {
            switch self {
            case .reputation: return .reputation
            case .domainAge: return .domainAge
            case .pagePrecheck: return .pagePrecheck
            }
        }
    }

    enum Result: Sendable {
        case reputation([ReputationLookup], failed: Bool, timedOut: Bool)
        case domainAge(Date?, failed: Bool, timedOut: Bool)
        case pagePrecheck(PagePrecheckResult?, failed: Bool, timedOut: Bool)
    }

    let dependencies: AnalysisPipeline.Dependencies
    let budget: AnalysisPipeline.Budget

    func resolveChain(_ url: URL) async -> RedirectChain {
        guard let resolver = dependencies.redirectResolver else {
            return RedirectChain(hops: [RedirectHop(order: 0, url: url, statusCode: nil)], outcome: .failed("no resolver"))
        }
        let budget = self.budget
        do {
            // 리졸버 자체 예산에 1초 여유를 둔 안전망.
            return try await withTimeout(budget.redirectTotalTimeout + .seconds(1)) {
                await resolver.resolve(url, maxHops: budget.maxHops, perHopTimeout: budget.perHopTimeout, totalTimeout: budget.redirectTotalTimeout)
            }
        } catch {
            return RedirectChain(hops: [RedirectHop(order: 0, url: url, statusCode: nil)], outcome: .timedOut)
        }
    }

    func perform(_ job: Job) async -> Result {
        switch job {
        case .reputation(let urls, let providers):
            return await lookupReputation(urls: urls, providers: providers)
        case .domainAge(let domain):
            return await lookupDomainAge(domain)
        case .pagePrecheck(let url):
            return await precheckPage(url)
        }
    }

    private func lookupReputation(urls: [URL], providers: [any ReputationProvider]) async -> Result {
        let timeout = budget.reputationTimeout
        var lookups: [ReputationLookup] = []
        var failed = false
        var timedOut = false

        await withTaskGroup(of: (String, [URL: ReputationVerdict]?, Bool).self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        let verdicts = try await withTimeout(timeout) { try await provider.lookup(urls) }
                        return (provider.name, verdicts, false)
                    } catch is TimeoutError {
                        return (provider.name, nil, true)
                    } catch {
                        return (provider.name, nil, false)
                    }
                }
            }
            for await (name, verdicts, didTimeOut) in group {
                guard let verdicts else {
                    if didTimeOut { timedOut = true } else { failed = true }
                    continue
                }
                for url in urls {
                    lookups.append(ReputationLookup(url: url, provider: name, verdict: verdicts[url] ?? .unknown))
                }
            }
        }
        return .reputation(lookups, failed: failed, timedOut: timedOut)
    }

    private func lookupDomainAge(_ domain: String) async -> Result {
        guard let provider = dependencies.domainInfo else { return .domainAge(nil, failed: true, timedOut: false) }
        do {
            let date = try await withTimeout(budget.domainAgeTimeout) { try await provider.registrationDate(for: domain) }
            return .domainAge(date, failed: date == nil, timedOut: false)
        } catch is TimeoutError {
            return .domainAge(nil, failed: false, timedOut: true)
        } catch {
            return .domainAge(nil, failed: true, timedOut: false)
        }
    }

    private func precheckPage(_ url: URL) async -> Result {
        guard let checker = dependencies.pagePrecheck else { return .pagePrecheck(nil, failed: true, timedOut: false) }
        let timeout = budget.pagePrecheckTimeout
        do {
            let page = try await withTimeout(timeout) { try await checker.precheck(url, timeout: timeout) }
            return .pagePrecheck(page, failed: false, timedOut: false)
        } catch is TimeoutError {
            return .pagePrecheck(nil, failed: false, timedOut: true)
        } catch {
            return .pagePrecheck(nil, failed: true, timedOut: false)
        }
    }
}
