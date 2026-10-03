import Foundation

/// 규칙 실행 + 점수 산정 + `RiskReport` 생성.
///
/// 평가 순서: P → U → B → (R → T → D → H, 데이터가 있을 때만) → C(앞선 결과에 의존).
/// 온라인 데이터는 스냅샷에 있으면 쓰고 없으면 해당 규칙을 평가하지 않는다. 따라서
/// 같은 스냅샷에 대해 맥락(장소 칩)만 바꿔 다시 호출하면 네트워크 재요청 없이 재채점된다.
public struct RiskEngine: Sendable {
    public let data: DataStore
    public let rules: [any RiskRule]
    public let scorer: RiskScorer

    public init(data: DataStore = .bundled, rules: [any RiskRule] = RuleCatalog.allRules, scorer: RiskScorer = RiskScorer()) {
        self.data = data
        self.rules = rules
        self.scorer = scorer
    }

    /// 규칙을 모두 평가해 발동한 finding과 통과한 규칙 ID를 돌려준다.
    public func evaluate(snapshot: AnalysisSnapshot, context: AnalysisContext, now: Date = .now) -> (findings: [RiskFinding], passed: [RuleID]) {
        var findings: [RiskFinding] = []
        var passed: [RuleID] = []

        // 맥락(C) 규칙은 다른 규칙 결과에 의존하므로 마지막에 평가한다.
        let ordered = rules.filter { $0.id.category != .context } + rules.filter { $0.id.category == .context }

        for rule in ordered {
            let input = RuleInput(snapshot: snapshot, context: context, priorFindings: findings, data: data, now: now)
            guard rule.isApplicable(input) else { continue }
            if let finding = rule.evaluate(input) {
                findings.append(finding)
            } else if rule.id != .B03 {
                // B03은 "공식 도메인 확인"이라는 양성 통과 항목이므로 미발동을 통과로 세지 않는다.
                passed.append(rule.id)
            }
        }
        return (findings, passed)
    }

    /// 스냅샷 + 맥락으로 최종 보고서를 만든다.
    public func report(snapshot: AnalysisSnapshot, context: AnalysisContext, now: Date = .now) -> RiskReport {
        let (findings, passed) = evaluate(snapshot: snapshot, context: context, now: now)
        let result = scorer.score(findings)

        let chainHops: [RedirectHop]
        if let chain = snapshot.chain, !chain.hops.isEmpty {
            chainHops = chain.hops
        } else if let original = snapshot.url?.original {
            chainHops = [RedirectHop(order: 0, url: original, statusCode: nil)]
        } else {
            chainHops = []
        }

        let domain: DomainInfo? = snapshot.domainInfo ?? snapshot.finalURL.flatMap { final in
            guard let rd = final.registrableDomain else { return nil }
            return DomainInfo(
                registrableDomain: rd,
                unicodeHost: final.unicodeHost,
                punycodeHost: final.isIDN ? final.host : nil
            )
        }

        return RiskReport(
            score: result.score,
            tier: result.tier,
            blocksOpening: result.blocksOpening,
            findings: result.findings,
            passedChecks: passed.sorted(),
            rawPayload: snapshot.raw,
            payloadKind: snapshot.payload.kind,
            originalURL: snapshot.url?.original,
            finalURL: snapshot.chain?.finalURL ?? snapshot.finalURL?.original ?? snapshot.url?.original,
            redirectChain: chainHops,
            domain: domain,
            coverage: snapshot.coverage,
            analyzedAt: now
        )
    }

    /// 원문 → 오프라인 전용 스냅샷. 파이프라인과 테스트의 공통 진입점.
    public func offlineSnapshot(for raw: String, coverage: AnalysisCoverage = .offlineOnly, now: Date = .now) -> AnalysisSnapshot {
        let payload = PayloadParser.parse(raw)
        let url = payload.primaryURL.flatMap { URLNormalizer.normalize($0, data: data) }
        return AnalysisSnapshot(raw: raw, payload: payload, url: url, coverage: coverage, analyzedAt: now)
    }

    /// 오프라인 규칙만으로 즉시 보고서를 만든다(네트워크 없음).
    public func offlineReport(for raw: String, context: AnalysisContext, now: Date = .now) -> RiskReport {
        report(snapshot: offlineSnapshot(for: raw, now: now), context: context, now: now)
    }
}
