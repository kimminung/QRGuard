import Foundation

/// 규칙 평가 입력. 스냅샷(수집 데이터) + 맥락 + 앞서 발동한 규칙 + 번들 데이터.
public struct RuleInput: Sendable {
    public var snapshot: AnalysisSnapshot
    public var context: AnalysisContext
    /// 이 규칙보다 먼저 평가된 규칙의 결과(C02처럼 다른 규칙에 의존하는 규칙용).
    public var priorFindings: [RiskFinding]
    public var data: DataStore
    /// 도메인 나이 계산 기준 시각(테스트에서 고정 가능)
    public var now: Date

    public init(
        snapshot: AnalysisSnapshot,
        context: AnalysisContext,
        priorFindings: [RiskFinding] = [],
        data: DataStore,
        now: Date = .now
    ) {
        self.snapshot = snapshot
        self.context = context
        self.priorFindings = priorFindings
        self.data = data
        self.now = now
    }

    // 편의 접근자
    public var payload: QRPayload { snapshot.payload }
    public var url: NormalizedURL? { snapshot.url }
    public var finalURL: NormalizedURL? { snapshot.finalURL ?? snapshot.url }
    public var chain: RedirectChain? { snapshot.chain }
    public var domainInfo: DomainInfo? { snapshot.domainInfo }
    public var page: PagePrecheckResult? { snapshot.page }
    public var reputation: [ReputationLookup] { snapshot.reputation }

    public func hasPrior(_ id: RuleID) -> Bool { priorFindings.contains { $0.id == id } }
}

/// 위험 판정 규칙. 파일 하나에 규칙 하나(`Rules/U03_UserInfoAt.swift`, 타입 이름 `UserInfoAtRule`).
public protocol RiskRule: Sendable {
    var id: RuleID { get }
    var stage: RuleStage { get }
    /// 이 입력에 대해 평가할 의미가 있는지. false면 "통과한 검사"에도 포함하지 않는다.
    /// 예: Wi-Fi 규칙(P06)은 URL 페이로드에 적용되지 않고, R 규칙은 체인이 없으면 평가하지 않는다.
    func isApplicable(_ input: RuleInput) -> Bool
    /// 발동하면 finding, 아니면 nil.
    func evaluate(_ input: RuleInput) -> RiskFinding?
}

public extension RiskRule {
    func isApplicable(_ input: RuleInput) -> Bool { true }
}
