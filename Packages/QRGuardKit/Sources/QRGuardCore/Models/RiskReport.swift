import Foundation

/// 위험 등급. 점수는 **위험 점수**(높을수록 위험).
public enum RiskTier: String, Codable, Sendable, CaseIterable, Hashable {
    case safe       // 0–29
    case caution    // 30–69
    case danger     // 70–100

    public init(score: Int) {
        switch score {
        case ..<30: self = .safe
        case 30..<70: self = .caution
        default: self = .danger
        }
    }

    public var range: ClosedRange<Int> {
        switch self {
        case .safe: return 0...29
        case .caution: return 30...69
        case .danger: return 70...100
        }
    }
}

/// 확인 범위. 온라인 검사를 건너뛰거나 시간 초과가 나면 결과 화면에 배지를 표시한다.
public enum AnalysisCoverage: Codable, Sendable, Hashable {
    case full
    case offlineOnly
    /// 완료하지 못한 검사 항목 목록
    case partial([CheckID])

    public var isLimited: Bool {
        if case .full = self { return false }
        return true
    }

    public var missingChecks: [CheckID] {
        switch self {
        case .full: return []
        case .offlineOnly: return [.redirect, .domainAge, .reputation, .pagePrecheck]
        case .partial(let ids): return ids
        }
    }
}

/// 사용자에게 보이는 위험 요소 1건. 음수 점수(B03)는 "통과 항목"으로 표시한다.
public struct RiskFinding: Codable, Sendable, Hashable, Identifiable {
    public let id: RuleID
    /// 가산점(음수 가능: B03 −20, D03 0).
    public let points: Int
    /// 확정 신호의 최저 점수(T01 90, P02 95 등).
    public let floor: Int?
    /// P01/P02: 열기 버튼을 렌더링하지 않는다.
    public let blocksOpening: Bool
    /// 화면 표시용 근거값. 문구의 `{key}` 자리에 치환된다. 예: ["hidden_host": "evil.example"]
    public let evidence: [String: String]
    public let sources: [SourceID]

    public init(
        id: RuleID,
        points: Int,
        floor: Int? = nil,
        blocksOpening: Bool = false,
        evidence: [String: String] = [:],
        sources: [SourceID] = []
    ) {
        self.id = id
        self.points = points
        self.floor = floor
        self.blocksOpening = blocksOpening
        self.evidence = evidence
        self.sources = sources
    }

    public var titleKey: String { "rule.\(id.rawValue).title" }
    public var detailKey: String { "rule.\(id.rawValue).detail" }
    public var adviceKey: String { "rule.\(id.rawValue).advice" }

    /// 확정 신호(floor 보유) 여부. UI에서 "확정" 배지로 표시한다.
    public var isDecisive: Bool { floor != nil }
    /// 양수 가산점이 있는 실제 위험 요소인지.
    public var isRisk: Bool { points > 0 || floor != nil }
}

/// 리다이렉트 경로의 한 홉.
public struct RedirectHop: Codable, Sendable, Hashable, Identifiable {
    public var id: Int { order }
    /// 0 = 스캔한 주소
    public let order: Int
    public let url: URL
    /// 이 URL에 대한 응답 코드(요청하지 않았으면 nil)
    public let statusCode: Int?
    /// meta refresh / location 할당으로 발견된 홉
    public let viaMetaRefresh: Bool

    public init(order: Int, url: URL, statusCode: Int?, viaMetaRefresh: Bool = false) {
        self.order = order
        self.url = url
        self.statusCode = statusCode
        self.viaMetaRefresh = viaMetaRefresh
    }
}

/// 리다이렉트 추적 결과.
public struct RedirectChain: Codable, Sendable, Hashable {
    public enum Outcome: Codable, Sendable, Hashable {
        /// 최종 응답(2xx/4xx/5xx 등)을 받아 끝까지 따라감
        case completed
        /// 홉당·전체 시간 초과
        case timedOut
        /// 최대 홉 수 초과
        case tooManyHops
        /// 같은 URL 재방문
        case loopDetected
        /// `http://` 홉을 만나 접속하지 않고 중단 (ATS, TECH_PRD 6.2)
        case stoppedAtInsecureHop
        /// 사설 IP·localhost·.local 대상이라 요청하지 않음
        case blockedPrivateAddress
        /// TLS 인증서 검증 실패 (H05)
        case tlsFailure
        /// 기타 네트워크 오류
        case failed(String)
    }

    /// hops[0]은 항상 스캔한 주소. 요청하지 않은 홉도 기록된다(statusCode nil).
    public var hops: [RedirectHop]
    public var outcome: Outcome
    /// 최종 응답의 Content-Type (P03/P04 승격용)
    public var finalContentType: String?
    public var finalStatusCode: Int?

    public init(hops: [RedirectHop], outcome: Outcome, finalContentType: String? = nil, finalStatusCode: Int? = nil) {
        self.hops = hops
        self.outcome = outcome
        self.finalContentType = finalContentType
        self.finalStatusCode = finalStatusCode
    }

    public var originalURL: URL? { hops.first?.url }
    public var finalURL: URL? { hops.last?.url }
    /// 실제 이동 횟수(스캔한 주소 제외)
    public var redirectCount: Int { max(0, hops.count - 1) }
    public var didReachFinal: Bool { outcome == .completed }
}

/// 도메인 정보 (상세 화면 "도메인 정보" 섹션).
public struct DomainInfo: Codable, Sendable, Hashable {
    /// eTLD+1 (ASCII)
    public var registrableDomain: String
    /// 표시용 유니코드 호스트
    public var unicodeHost: String
    /// IDN이면 퓨니코드 원문
    public var punycodeHost: String?
    /// RDAP 등록일. 조회 실패/미지원이면 nil
    public var registrationDate: Date?
    /// RDAP 조회를 시도했으나 실패(D03)
    public var lookupFailed: Bool

    public init(
        registrableDomain: String,
        unicodeHost: String,
        punycodeHost: String? = nil,
        registrationDate: Date? = nil,
        lookupFailed: Bool = false
    ) {
        self.registrableDomain = registrableDomain
        self.unicodeHost = unicodeHost
        self.punycodeHost = punycodeHost
        self.registrationDate = registrationDate
        self.lookupFailed = lookupFailed
    }

    public func ageInDays(asOf now: Date = .now) -> Int? {
        guard let registrationDate else { return nil }
        return Calendar(identifier: .gregorian).dateComponents([.day], from: registrationDate, to: now).day
    }
}

/// 평판 조회 결과.
public enum ReputationVerdict: Codable, Sendable, Hashable {
    case clean
    case malicious(threatTypes: [String])
    case unknown

    public var isMalicious: Bool {
        if case .malicious = self { return true }
        return false
    }
}

/// URL 1건에 대한 평판 조회 결과(제공자 이름 포함).
public struct ReputationLookup: Codable, Sendable, Hashable {
    public let url: URL
    public let provider: String
    public let verdict: ReputationVerdict

    public init(url: URL, provider: String, verdict: ReputationVerdict) {
        self.url = url
        self.provider = provider
        self.verdict = verdict
    }
}

/// 페이지 사전 검사 결과(HTML 앞부분 정적 파싱, JS 미실행).
public struct PagePrecheckResult: Codable, Sendable, Hashable {
    public var hasPasswordInput: Bool
    /// `<form action>`의 호스트 목록(상대 경로는 제외)
    public var formActionHosts: [String]
    public var title: String?
    /// 로고 alt·본문 상단 텍스트 일부(브랜드 위장 탐지용, 최대 2KB)
    public var leadingText: String
    public var metaRefreshTarget: URL?
    public var contentType: String?
    public var tlsFailed: Bool
    public var bytesRead: Int
    /// `display:none`·`font-size:0`·`aria-hidden` 등 사용자에게 보이지 않는 요소의 텍스트(V09, 최대 수 KB).
    /// 메모리에서만 다루고 기록에는 빈 문자열로 저장해도 된다.
    public var hiddenText: String
    /// HTML 본문에서 발견된 불가시 문자(`Cf`·BOM·양방향 제어 문자) 수(V09).
    public var invisibleCharacterCount: Int

    public init(
        hasPasswordInput: Bool = false,
        formActionHosts: [String] = [],
        title: String? = nil,
        leadingText: String = "",
        metaRefreshTarget: URL? = nil,
        contentType: String? = nil,
        tlsFailed: Bool = false,
        bytesRead: Int = 0,
        hiddenText: String = "",
        invisibleCharacterCount: Int = 0
    ) {
        self.hasPasswordInput = hasPasswordInput
        self.formActionHosts = formActionHosts
        self.title = title
        self.leadingText = leadingText
        self.metaRefreshTarget = metaRefreshTarget
        self.contentType = contentType
        self.tlsFailed = tlsFailed
        self.bytesRead = bytesRead
        self.hiddenText = hiddenText
        self.invisibleCharacterCount = invisibleCharacterCount
    }

    private enum CodingKeys: String, CodingKey {
        case hasPasswordInput, formActionHosts, title, leadingText, metaRefreshTarget, contentType, tlsFailed, bytesRead
        case hiddenText, invisibleCharacterCount
    }

    /// T-8.1 이전에 저장된 기록에는 `hiddenText`·`invisibleCharacterCount` 키가 없으므로 관대하게 읽는다.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hasPasswordInput = try c.decodeIfPresent(Bool.self, forKey: .hasPasswordInput) ?? false
        formActionHosts = try c.decodeIfPresent([String].self, forKey: .formActionHosts) ?? []
        title = try c.decodeIfPresent(String.self, forKey: .title)
        leadingText = try c.decodeIfPresent(String.self, forKey: .leadingText) ?? ""
        metaRefreshTarget = try c.decodeIfPresent(URL.self, forKey: .metaRefreshTarget)
        contentType = try c.decodeIfPresent(String.self, forKey: .contentType)
        tlsFailed = try c.decodeIfPresent(Bool.self, forKey: .tlsFailed) ?? false
        bytesRead = try c.decodeIfPresent(Int.self, forKey: .bytesRead) ?? 0
        hiddenText = try c.decodeIfPresent(String.self, forKey: .hiddenText) ?? ""
        invisibleCharacterCount = try c.decodeIfPresent(Int.self, forKey: .invisibleCharacterCount) ?? 0
    }
}

/// 분석 결과 (RISK_RULES.md 4장 계약 + 저장·표시용 필드).
public struct RiskReport: Codable, Sendable, Hashable {
    /// 0...100 위험 점수
    public let score: Int
    public let tier: RiskTier
    /// P01·P02: 열기 버튼 자체를 숨긴다
    public let blocksOpening: Bool
    /// 확정 신호 → 가산점 내림차순. 음수·0점 항목은 뒤에.
    public let findings: [RiskFinding]
    /// 평가했지만 발동하지 않은 규칙("통과한 검사")
    public let passedChecks: [RuleID]
    public let rawPayload: String
    public let payloadKind: QRPayload.Kind
    public let originalURL: URL?
    public let finalURL: URL?
    public let redirectChain: [RedirectHop]
    public let domain: DomainInfo?
    public let coverage: AnalysisCoverage
    public let analyzedAt: Date

    public init(
        score: Int,
        tier: RiskTier,
        blocksOpening: Bool,
        findings: [RiskFinding],
        passedChecks: [RuleID],
        rawPayload: String,
        payloadKind: QRPayload.Kind,
        originalURL: URL?,
        finalURL: URL?,
        redirectChain: [RedirectHop],
        domain: DomainInfo?,
        coverage: AnalysisCoverage,
        analyzedAt: Date = .now
    ) {
        self.score = score
        self.tier = tier
        self.blocksOpening = blocksOpening
        self.findings = findings
        self.passedChecks = passedChecks
        self.rawPayload = rawPayload
        self.payloadKind = payloadKind
        self.originalURL = originalURL
        self.finalURL = finalURL
        self.redirectChain = redirectChain
        self.domain = domain
        self.coverage = coverage
        self.analyzedAt = analyzedAt
    }

    /// 양수 가산점 또는 확정 신호가 있는 위험 요소만.
    public var riskFindings: [RiskFinding] { findings.filter(\.isRisk) }
    /// B03처럼 통과를 뜻하는 음수 항목.
    public var positiveFindings: [RiskFinding] { findings.filter { $0.points < 0 } }
    /// 결과 화면 요약용 상위 3개.
    public var topFindings: [RiskFinding] { Array(riskFindings.prefix(3)) }
    public var hasRedirect: Bool { redirectChain.count > 1 }
    /// 열기 대상 URL(최종 도착 주소 우선).
    public var openTarget: URL? { finalURL ?? originalURL }
}
