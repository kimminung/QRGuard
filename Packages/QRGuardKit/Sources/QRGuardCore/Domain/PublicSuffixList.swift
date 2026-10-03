import Foundation

/// Public Suffix List 인덱스 (TASKS T-1.2). 와일드카드(`*.ck`)·예외(`!www.ck`) 규칙과 ICANN·PRIVATE 섹션을 모두 지원한다.
///
/// 초기화 때 규칙을 한 번 해시 집합으로 색인하므로 이후 조회는 라벨 수만큼의 해시 조회(마이크로초대)로 끝난다.
/// 유니코드 규칙은 퓨니코드(`xn--`) 형태도 함께 색인해 어느 쪽 호스트든 그대로 조회할 수 있다.
public final class PublicSuffixList: Sendable {
    /// 일반 규칙(예: "com", "co.kr", "github.io")
    private let rules: Set<String>
    /// 와일드카드 규칙의 기준(예: "*.kobe.jp" → "kobe.jp")
    private let wildcardBases: Set<String>
    /// 예외 규칙(예: "!city.kobe.jp" → "city.kobe.jp")
    private let exceptions: Set<String>

    /// 규칙이 하나도 없으면 마지막 두 라벨 폴백을 쓴다.
    public var isEmpty: Bool { rules.isEmpty && wildcardBases.isEmpty && exceptions.isEmpty }
    public var ruleCount: Int { rules.count + wildcardBases.count + exceptions.count }

    /// 번들 PSL로 만든 공유 인스턴스. 첫 접근 시 한 번만 색인한다.
    public static let shared = PublicSuffixList(rules: DataStore.bundled.publicSuffixRules)

    /// `public_suffix_list.dat`의 줄 배열로 색인을 만든다. 주석(`//`)·빈 줄은 무시한다.
    public init(rules lines: [String]) {
        var rules = Set<String>()
        var wildcards = Set<String>()
        var exceptions = Set<String>()
        rules.reserveCapacity(lines.count)

        for rawLine in lines {
            // 규칙은 첫 공백까지만 유효하다(PSL 명세).
            guard let firstToken = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else { continue }
            var rule = String(firstToken)
            if rule.isEmpty || rule.hasPrefix("//") { continue }
            rule = rule.lowercased()

            var isException = false
            var isWildcard = false
            if rule.hasPrefix("!") {
                isException = true
                rule.removeFirst()
            } else if rule.hasPrefix("*.") {
                isWildcard = true
                rule.removeFirst(2)
            }
            if rule.hasPrefix(".") { rule.removeFirst() }
            guard !rule.isEmpty else { continue }

            var forms = [rule]
            if rule.unicodeScalars.contains(where: { $0.value >= 0x80 }) {
                let ace = Punycode.encodeHost(rule)
                if ace != rule { forms.append(ace) }
            }
            for form in forms {
                if isException { exceptions.insert(form) }
                else if isWildcard { wildcards.insert(form) }
                else { rules.insert(form) }
            }
        }
        self.rules = rules
        self.wildcardBases = wildcards
        self.exceptions = exceptions
    }

    // MARK: - 조회

    /// 호스트의 공개 접미사(eTLD). 호스트가 비어 있으면 nil.
    public func publicSuffix(forHost host: String) -> String? {
        let labels = Self.labels(of: host)
        guard !labels.isEmpty else { return nil }
        let count = matchLength(labels: labels)
        return labels.suffix(count).joined(separator: ".")
    }

    /// 등록 가능 도메인(eTLD+1). 호스트 자체가 공개 접미사이거나 라벨이 부족하면 nil.
    public func registrableDomain(forHost host: String) -> String? {
        let labels = Self.labels(of: host)
        guard labels.count >= 2 else { return nil }
        let count = matchLength(labels: labels)
        guard labels.count > count else { return nil }
        return labels.suffix(count + 1).joined(separator: ".")
    }

    // MARK: - 내부

    /// 공개 접미사를 이루는 라벨 수. 예외 규칙 우선, 그다음 가장 긴 일치, 없으면 1(`*`).
    private func matchLength(labels: [String]) -> Int {
        if isEmpty { return 1 }
        var best = 1
        var suffix = ""
        for i in stride(from: labels.count - 1, through: 0, by: -1) {
            suffix = suffix.isEmpty ? labels[i] : labels[i] + "." + suffix
            let length = labels.count - i
            if exceptions.contains(suffix) {
                // 예외 규칙: 첫 라벨을 뺀 부분이 공개 접미사
                return length - 1
            }
            if rules.contains(suffix) {
                best = max(best, length)
            }
            if i < labels.count - 1 {
                let parent = labels[(i + 1)...].joined(separator: ".")
                if wildcardBases.contains(parent) {
                    best = max(best, length)
                }
            }
        }
        return best
    }

    private static func labels(of host: String) -> [String] {
        var h = host.lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        while h.hasPrefix(".") { h.removeFirst() }
        if h.isEmpty { return [] }
        return h.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    }
}
