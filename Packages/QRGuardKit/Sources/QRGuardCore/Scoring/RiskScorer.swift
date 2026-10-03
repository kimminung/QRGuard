import Foundation

/// 점수 산정 (RISK_RULES.md 2장).
///
/// ```
/// rawScore   = Σ points(triggered findings)          // 같은 규칙은 1회만, 카테고리 상한 적용
/// floored    = max(rawScore, max(floor(triggered)))  // 확정 신호의 최저 점수
/// adjusted   = floored + allowlistAdjustment         // B03 −20 (T01 또는 U09와 함께면 미적용)
/// score      = clamp(adjusted, 0, 100)
/// ```
public struct RiskScorer: Sendable {
    public struct Result: Sendable, Hashable {
        public let score: Int
        public let tier: RiskTier
        public let blocksOpening: Bool
        /// 정렬·예외 적용 후의 최종 findings
        public let findings: [RiskFinding]
    }

    public init() {}

    public func score(_ findings: [RiskFinding]) -> Result {
        // 같은 규칙은 1회만
        var seen = Set<RuleID>()
        var unique: [RiskFinding] = []
        for f in findings where !seen.contains(f.id) {
            seen.insert(f.id)
            unique.append(f)
        }

        // B03 예외: T01(블록리스트 적중) 또는 U09(오픈 리다이렉트)와 함께면 적용하지 않는다.
        let hasT01 = seen.contains(.T01)
        let hasU09 = seen.contains(.U09)
        if hasT01 || hasU09 {
            unique.removeAll { $0.id == .B03 }
        }

        // 카테고리별 양수 가산점 합계(상한 적용)
        var perCategory: [RuleCategory: Int] = [:]
        var uncategorized = 0
        for f in unique where f.points > 0 {
            if let cat = f.id.category {
                perCategory[cat, default: 0] += f.points
            } else {
                uncategorized += f.points
            }
        }
        var raw = uncategorized
        for (cat, sum) in perCategory {
            raw += min(sum, cat.pointCap ?? Int.max)
        }

        // 확정 신호의 최저 점수
        let maxFloor = unique.compactMap(\.floor).max() ?? 0
        let floored = max(raw, maxFloor)

        // 허용 목록 조정(음수 가산점)
        let adjustment = unique.filter { $0.points < 0 }.reduce(0) { $0 + $1.points }
        let adjusted = floored + adjustment
        let score = min(100, max(0, adjusted))

        let blocks = unique.contains(where: \.blocksOpening)

        // 정렬: 확정 신호(floor 큰 순) → 가산점 내림차순 → ID
        let sorted = unique.sorted { a, b in
            let fa = a.floor ?? -1, fb = b.floor ?? -1
            if fa != fb { return fa > fb }
            if a.points != b.points { return a.points > b.points }
            return a.id < b.id
        }

        return Result(score: score, tier: RiskTier(score: score), blocksOpening: blocks, findings: sorted)
    }
}
