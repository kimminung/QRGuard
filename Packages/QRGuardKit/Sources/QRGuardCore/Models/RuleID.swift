import Foundation

/// 규칙 식별자. `RISK_RULES.md` 3장의 ID와 1:1 대응한다. 예: "U03".
public struct RuleID: Hashable, Sendable, Comparable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.init(value) }

    /// 첫 글자로 계열(P/U/B/C/R/T/D/H)을 판별한다.
    public var category: RuleCategory? {
        rawValue.first.flatMap { RuleCategory(rawValue: String($0)) }
    }

    public var description: String { rawValue }
    public static func < (lhs: RuleID, rhs: RuleID) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension RuleID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - 규칙 카탈로그 ID (RISK_RULES.md 3장)
public extension RuleID {
    // P — 페이로드
    static let P01: RuleID = "P01"
    static let P02: RuleID = "P02"
    static let P03: RuleID = "P03"
    static let P04: RuleID = "P04"
    static let P05: RuleID = "P05"
    static let P05a: RuleID = "P05a"
    static let P06: RuleID = "P06"
    static let P07: RuleID = "P07"
    static let P08: RuleID = "P08"
    static let P09: RuleID = "P09"
    static let P10: RuleID = "P10"
    // U — URL 구조
    static let U01: RuleID = "U01"
    static let U02: RuleID = "U02"
    static let U03: RuleID = "U03"
    static let U04: RuleID = "U04"
    static let U05: RuleID = "U05"
    static let U06: RuleID = "U06"
    static let U07: RuleID = "U07"
    static let U08: RuleID = "U08"
    static let U09: RuleID = "U09"
    static let U10: RuleID = "U10"
    static let U11: RuleID = "U11"
    // B — 브랜드 사칭
    static let B01: RuleID = "B01"
    static let B02: RuleID = "B02"
    static let B03: RuleID = "B03"
    // R — 리다이렉트
    static let R01: RuleID = "R01"
    static let R02: RuleID = "R02"
    static let R03: RuleID = "R03"
    static let R04: RuleID = "R04"
    static let R05: RuleID = "R05"
    // T — 평판
    static let T01: RuleID = "T01"
    // D — 도메인
    static let D01: RuleID = "D01"
    static let D02: RuleID = "D02"
    static let D03: RuleID = "D03"
    // H — 페이지 사전 검사
    static let H01: RuleID = "H01"
    static let H02: RuleID = "H02"
    static let H03: RuleID = "H03"
    static let H05: RuleID = "H05"
    // C — 스캔 상황
    static let C01: RuleID = "C01"
    static let C02: RuleID = "C02"
    static let C03: RuleID = "C03"
}

/// 규칙 계열. 카테고리 상한(U 45 · H 40 · C 30)은 `RiskScorer`가 적용한다.
public enum RuleCategory: String, Codable, Sendable, CaseIterable {
    case payload = "P"
    case urlStructure = "U"
    case brand = "B"
    case context = "C"
    case redirect = "R"
    case reputation = "T"
    case domain = "D"
    case page = "H"

    /// 같은 계열 가산점 합계의 상한. nil이면 상한 없음.
    public var pointCap: Int? {
        switch self {
        case .urlStructure: return 45
        case .page: return 40
        case .context: return 30
        default: return nil
        }
    }
}

/// 규칙 실행 시점. 오프라인 규칙은 네트워크 없이 항상 평가된다.
public enum RuleStage: String, Codable, Sendable {
    case offline
    case online
}

/// 분석 단계(검사 항목) 식별자. 확인 범위(coverage)와 분석 중 화면의 단계 목록에 쓴다.
public enum CheckID: String, Codable, Sendable, CaseIterable, Hashable {
    /// 주소 구조 분석 (P·U·B·C 규칙, 로컬 블록리스트)
    case structure
    /// 실제 도착 주소 확인 (리다이렉트 추적, R 규칙)
    case redirect
    /// 도메인 생성일 확인 (RDAP, D 규칙)
    case domainAge
    /// 악성 사이트 조회 (Safe Browsing 등 평판, T01)
    case reputation
    /// 페이지 사전 검사 (H 규칙, 기본 꺼짐)
    case pagePrecheck
}

/// 근거 출처 ID (`RISK_RULES.md` 7장).
public enum SourceID: String, Codable, Sendable, CaseIterable, Hashable {
    case S1, S2, S3, S4, S5, S6, S7, S8, S9, S10
    /// 일반 보안 원칙 · 일반 피싱 지표처럼 특정 출처가 없는 경우
    case general

    /// 앱 내 "근거" 표시용 기관명 (현지화 키)
    public var organizationKey: String { "source.\(rawValue).org" }
}
