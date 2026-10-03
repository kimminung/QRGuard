import Foundation

/// eTLD+1 편의 진입점 (TASKS T-1.2). `a.b.example.co.kr` → `example.co.kr`.
public enum RegistrableDomain {
    /// 호스트의 등록 가능 도메인. IP 리터럴·공개 접미사 자체·빈 호스트면 nil.
    public static func from(host: String, psl: PublicSuffixList = .shared) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !IPAddressParser.isIPLiteral(trimmed) else { return nil }
        return psl.registrableDomain(forHost: trimmed)
    }

    /// 호스트의 공개 접미사(eTLD).
    public static func publicSuffix(host: String, psl: PublicSuffixList = .shared) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !IPAddressParser.isIPLiteral(trimmed) else { return nil }
        return psl.publicSuffix(forHost: trimmed)
    }

    /// 두 호스트가 같은 eTLD+1인지. IP는 문자열 자체를 비교한다.
    public static func sameSite(_ a: String, _ b: String, psl: PublicSuffixList = .shared) -> Bool {
        let ra = from(host: a, psl: psl) ?? a.lowercased()
        let rb = from(host: b, psl: psl) ?? b.lowercased()
        return ra == rb
    }

    /// `DataStore`의 PSL 규칙으로 인덱스를 고른다. 번들 규칙과 같으면 공유 인스턴스를 재사용한다.
    static func list(for data: DataStore) -> PublicSuffixList {
        let bundledRules = DataStore.bundled.publicSuffixRules
        if data.publicSuffixRules.count == bundledRules.count,
           data.publicSuffixRules.first == bundledRules.first,
           data.publicSuffixRules.last == bundledRules.last {
            return .shared
        }
        if data.publicSuffixRules.isEmpty { return .empty }
        return PublicSuffixList(rules: data.publicSuffixRules)
    }
}

extension PublicSuffixList {
    /// 규칙이 없는 인덱스(마지막 두 라벨 폴백).
    static let empty = PublicSuffixList(rules: [])
}

/// IP 리터럴 판별 (IPv4 점 표기·축약형·16진·정수형, 대괄호 IPv6).
public enum IPAddressParser {
    /// IPv4 또는 IPv6 리터럴이면 true.
    public static func isIPLiteral(_ host: String) -> Bool {
        isIPv6(host) || canonicalIPv4(host) != nil
    }

    /// 대괄호 유무와 관계없이 IPv6로 보이면 true (콜론 2개 이상, 허용 문자만).
    public static func isIPv6(_ host: String) -> Bool {
        var h = host
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        guard h.filter({ $0 == ":" }).count >= 2 else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.%")
        return h.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// IPv4 리터럴을 표준 점 표기(`a.b.c.d`)로. `0x7f.1`, `2130706433`, `127.1`, `0177.0.0.1`도 받아들인다.
    public static func canonicalIPv4(_ host: String) -> String? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (1...4).contains(parts.count), !parts.contains("") else { return nil }
        var values: [UInt64] = []
        for part in parts {
            guard let v = parseIPv4Part(part) else { return nil }
            values.append(v)
        }
        // 마지막 부분은 남은 바이트 수만큼의 값을 담을 수 있다.
        let last = values.removeLast()
        let remainingBytes = 4 - values.count
        guard last < (UInt64(1) << (8 * UInt64(remainingBytes))) else { return nil }
        guard values.allSatisfy({ $0 <= 255 }) else { return nil }
        var full: UInt64 = 0
        for v in values { full = (full << 8) | v }
        full = (full << (8 * UInt64(remainingBytes))) | last
        let octets = (0..<4).map { String((full >> (8 * UInt64(3 - $0))) & 0xFF) }
        return octets.joined(separator: ".")
    }

    private static func parseIPv4Part(_ s: String) -> UInt64? {
        let lower = s.lowercased()
        if lower.hasPrefix("0x") {
            let body = lower.dropFirst(2)
            if body.isEmpty { return 0 }
            return UInt64(body, radix: 16)
        }
        if lower.count > 1, lower.hasPrefix("0") {
            return UInt64(lower.dropFirst(), radix: 8)
        }
        guard lower.allSatisfy(\.isNumber) else { return nil }
        return UInt64(lower, radix: 10)
    }
}
