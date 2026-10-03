import Foundation

/// 분석 중 화면의 단계 목록. 이벤트로만 갱신한다(가짜 진행 표시 금지).
public enum AnalysisStep: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case structure      // 주소 구조 분석
    case redirect       // 실제 도착 주소 확인
    case domainAge      // 도메인 생성일 확인
    case reputation     // 악성 사이트 조회
    case pagePrecheck   // 페이지 미리 검사 (옵션)

    public var id: String { rawValue }

    public var checkID: CheckID {
        switch self {
        case .structure: return .structure
        case .redirect: return .redirect
        case .domainAge: return .domainAge
        case .reputation: return .reputation
        case .pagePrecheck: return .pagePrecheck
        }
    }
}

public enum StepOutcome: Codable, Sendable, Hashable {
    case passed
    /// 발견된 위험 요소 수 또는 부가 정보(예: 리다이렉트 횟수)
    case flagged(Int)
    case skipped
    case timedOut
    case failed
}

/// 파이프라인이 내보내는 이벤트.
public enum AnalysisEvent: Sendable {
    case stepStarted(AnalysisStep)
    case stepFinished(AnalysisStep, StepOutcome)
    /// 오프라인 규칙만으로 만든 잠정 결과(온라인 단계 진행 중 미리 보여줄 수 있음)
    case preliminary(RiskReport)
    /// 최종 결과. 스냅샷을 함께 전달해 장소 칩 변경 시 네트워크 재요청 없이 재채점한다.
    case finished(RiskReport, AnalysisSnapshot)
}

/// 한 번의 분석에서 수집한 모든 입력(맥락 제외). `RiskEngine.report(snapshot:context:)`로 재채점할 수 있다.
public struct AnalysisSnapshot: Codable, Sendable, Hashable {
    public var raw: String
    public var payload: QRPayload
    /// 대표 URL 정규화 결과
    public var url: NormalizedURL?
    public var chain: RedirectChain?
    /// 최종 도착 주소 정규화 결과(리다이렉트가 없으면 url과 같음)
    public var finalURL: NormalizedURL?
    public var domainInfo: DomainInfo?
    public var reputation: [ReputationLookup]
    public var page: PagePrecheckResult?
    public var coverage: AnalysisCoverage
    public var analyzedAt: Date

    public init(
        raw: String,
        payload: QRPayload,
        url: NormalizedURL?,
        chain: RedirectChain? = nil,
        finalURL: NormalizedURL? = nil,
        domainInfo: DomainInfo? = nil,
        reputation: [ReputationLookup] = [],
        page: PagePrecheckResult? = nil,
        coverage: AnalysisCoverage = .offlineOnly,
        analyzedAt: Date = .now
    ) {
        self.raw = raw
        self.payload = payload
        self.url = url
        self.chain = chain
        self.finalURL = finalURL ?? url
        self.domainInfo = domainInfo
        self.reputation = reputation
        self.page = page
        self.coverage = coverage
        self.analyzedAt = analyzedAt
    }

    /// 체인의 모든 URL(스캔한 주소 포함). 체인이 없으면 대표 URL만.
    public var allURLs: [URL] {
        if let chain, !chain.hops.isEmpty { return chain.hops.map(\.url) }
        return [url?.original].compactMap { $0 }
    }
}
