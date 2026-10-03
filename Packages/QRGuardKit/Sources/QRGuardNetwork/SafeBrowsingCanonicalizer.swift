import Foundation

/// Google Safe Browsing URL 정규화 + 접미사/접두사 표현식 생성
/// (https://developers.google.com/safe-browsing/v4/urls-hashing — v5도 동일 규칙).
public enum SafeBrowsingCanonicalizer {
    struct Parts {
        var scheme: String
        var host: String
        var path: String
        var query: String?
        var isIPAddress: Bool
    }

    /// 정규화된 전체 URL 문자열. 파싱할 수 없으면 nil.
    public static func canonicalize(_ url: String) -> String? {
        guard let parts = canonicalParts(url) else { return nil }
        var result = parts.scheme + "://" + parts.host + parts.path
        if let query = parts.query { result += "?" + query }
        return result
    }

    public static func canonicalize(_ url: URL) -> String? {
        canonicalize(url.absoluteString)
    }

    /// 조회 표현식(스킴 없음): 호스트 접미사 ≤5 × 경로 접두사 ≤6.
    public static func expressions(for url: String) -> [String] {
        guard let parts = canonicalParts(url) else { return [] }
        var hosts = [parts.host]
        if !parts.isIPAddress {
            let comps = parts.host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            let n = comps.count
            if n > 2 {
                for length in stride(from: min(5, n - 1), through: 2, by: -1) {
                    hosts.append(comps.suffix(length).joined(separator: "."))
                }
            }
        }

        var paths: [String] = []
        if let query = parts.query { paths.append(parts.path + "?" + query) }
        paths.append(parts.path)
        var segments = parts.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if !parts.path.hasSuffix("/"), !segments.isEmpty { segments.removeLast() }
        var prefix = "/"
        var prefixes = [prefix]
        for segment in segments where prefixes.count < 4 {
            prefix += segment + "/"
            prefixes.append(prefix)
        }
        paths.append(contentsOf: prefixes)

        var seen = Set<String>()
        var result: [String] = []
        for host in hosts {
            for path in paths {
                let expr = host + path
                if seen.insert(expr).inserted { result.append(expr) }
            }
        }
        return result
    }

    public static func expressions(for url: URL) -> [String] {
        expressions(for: url.absoluteString)
    }

    // MARK: - 정규화

    static func canonicalParts(_ input: String) -> Parts? {
        // 1. 탭·CR·LF 제거, 앞뒤 공백 제거
        var bytes = Array(input.utf8).filter { $0 != 0x09 && $0 != 0x0A && $0 != 0x0D }
        while let first = bytes.first, first == 0x20 { bytes.removeFirst() }
        while let last = bytes.last, last == 0x20 { bytes.removeLast() }

        // 2. 프래그먼트 제거
        if let hash = bytes.firstIndex(of: 0x23) { bytes = Array(bytes[..<hash]) }

        // 3. 더 이상 바뀌지 않을 때까지 퍼센트 디코딩
        var iterations = 0
        while iterations < 64 {
            let decoded = percentUnescape(bytes)
            if decoded == bytes { break }
            bytes = decoded
            iterations += 1
        }
        guard !bytes.isEmpty else { return nil }

        // 4. 스킴 분리 (없으면 http)
        var scheme = "http"
        var rest = bytes[...]
        if let sep = findSchemeSeparator(bytes) {
            scheme = String(decoding: bytes[..<sep], as: UTF8.self).lowercased()
            rest = bytes[(sep + 3)...]
        }

        // 5. authority / path / query 분리
        let authorityEnd = rest.firstIndex { $0 == 0x2F || $0 == 0x3F } ?? rest.endIndex
        var authority = Array(rest[rest.startIndex..<authorityEnd])
        var pathAndQuery = Array(rest[authorityEnd...])

        // userinfo 제거
        if let at = authority.lastIndex(of: 0x40) { authority = Array(authority[(at + 1)...]) }
        // 포트 제거 (IPv6 괄호 고려)
        if authority.first == 0x5B, let close = authority.firstIndex(of: 0x5D) {
            authority = Array(authority[...close])
        } else if let colon = authority.lastIndex(of: 0x3A) {
            let portPart = authority[(colon + 1)...]
            if portPart.allSatisfy({ (0x30...0x39).contains($0) }) {
                authority = Array(authority[..<colon])
            }
        }

        // 6. 호스트 정규화
        var hostLower = authority.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }
        while hostLower.first == 0x2E { hostLower.removeFirst() }
        while hostLower.last == 0x2E { hostLower.removeLast() }
        var collapsed: [UInt8] = []
        collapsed.reserveCapacity(hostLower.count)
        for b in hostLower {
            if b == 0x2E, collapsed.last == 0x2E { continue }
            collapsed.append(b)
        }
        guard !collapsed.isEmpty else { return nil }
        var isIP = false
        var hostString: String
        if collapsed.allSatisfy({ $0 < 0x80 }),
           let octets = ipv4Octets(String(decoding: collapsed, as: UTF8.self)) {
            hostString = octets.map(String.init).joined(separator: ".")
            isIP = true
        } else {
            hostString = percentEscape(collapsed)
        }

        // 7. 경로 정규화 (쿼리는 그대로)
        var queryBytes: [UInt8]?
        if let q = pathAndQuery.firstIndex(of: 0x3F) {
            queryBytes = Array(pathAndQuery[(q + 1)...])
            pathAndQuery = Array(pathAndQuery[..<q])
        }
        let path = percentEscape(resolvePath(pathAndQuery))
        let query = queryBytes.map { percentEscape($0) }

        if hostString.isEmpty { return nil }
        return Parts(scheme: scheme, host: hostString, path: path, query: query, isIPAddress: isIP)
    }

    private static func findSchemeSeparator(_ bytes: [UInt8]) -> Int? {
        guard let colon = bytes.firstIndex(of: 0x3A), colon > 0 else { return nil }
        guard colon + 2 < bytes.count, bytes[colon + 1] == 0x2F, bytes[colon + 2] == 0x2F else { return nil }
        for (i, b) in bytes[..<colon].enumerated() {
            let isAlpha = (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b)
            let isDigit = (0x30...0x39).contains(b)
            if i == 0 { if !isAlpha { return nil } } else if !(isAlpha || isDigit || b == 0x2B || b == 0x2D || b == 0x2E) {
                return nil
            }
        }
        return colon
    }

    static func percentUnescape(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x25, i + 2 < bytes.count,
               let hi = hexValue(bytes[i + 1]), let lo = hexValue(bytes[i + 2]) {
                out.append(hi << 4 | lo)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return out
    }

    private static func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x41...0x46: return b - 0x41 + 10
        case 0x61...0x66: return b - 0x61 + 10
        default: return nil
        }
    }

    /// `/./`·`/../` 해석, 연속 슬래시 축약. 빈 경로는 `/`.
    static func resolvePath(_ path: [UInt8]) -> [UInt8] {
        guard !path.isEmpty else { return [0x2F] }
        let segments = path.split(separator: 0x2F, omittingEmptySubsequences: false)
        var out: [[UInt8]] = []
        for segment in segments {
            if segment.isEmpty { continue }
            if segment.elementsEqual([0x2E]) { continue }
            if segment.elementsEqual([0x2E, 0x2E]) {
                if !out.isEmpty { out.removeLast() }
                continue
            }
            out.append(Array(segment))
        }
        let last = segments.last ?? []
        let trailingSlash = last.isEmpty || last.elementsEqual([0x2E]) || last.elementsEqual([0x2E, 0x2E])
        var result: [UInt8] = [0x2F]
        for (i, seg) in out.enumerated() {
            result.append(contentsOf: seg)
            if i < out.count - 1 || trailingSlash { result.append(0x2F) }
        }
        return result
    }

    /// ≤0x20, ≥0x7F, `#`, `%` 를 대문자 16진으로 퍼센트 인코딩.
    static func percentEscape(_ bytes: [UInt8]) -> String {
        var out = ""
        out.reserveCapacity(bytes.count)
        let hex = Array("0123456789ABCDEF")
        for b in bytes {
            if b <= 0x20 || b >= 0x7F || b == 0x23 || b == 0x25 {
                out.append("%")
                out.append(hex[Int(b >> 4)])
                out.append(hex[Int(b & 0x0F)])
            } else {
                out.append(Character(UnicodeScalar(b)))
            }
        }
        return out
    }

    // MARK: - IPv4

    /// 10진·16진(`0x`)·8진(선행 0)·축약형(1~4 파트)을 4옥텟으로. IPv4가 아니면 nil.
    public static func ipv4Octets(_ host: String) -> [UInt8]? {
        var text = host
        while text.hasSuffix(".") { text.removeLast() }
        guard !text.isEmpty else { return nil }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (1...4).contains(parts.count) else { return nil }
        var values: [UInt64] = []
        for part in parts {
            guard let v = parseIPv4Part(part) else { return nil }
            values.append(v)
        }
        var result: UInt64 = 0
        for (i, v) in values.enumerated() {
            if i == values.count - 1 {
                let remainingBytes = 4 - i
                guard v < (UInt64(1) << (8 * UInt64(remainingBytes))) else { return nil }
                result = (result << (8 * UInt64(remainingBytes))) | v
            } else {
                guard v <= 255 else { return nil }
                result = (result << 8) | v
            }
        }
        return [UInt8((result >> 24) & 0xFF), UInt8((result >> 16) & 0xFF), UInt8((result >> 8) & 0xFF), UInt8(result & 0xFF)]
    }

    private static func parseIPv4Part(_ part: String) -> UInt64? {
        guard !part.isEmpty else { return nil }
        let lower = part.lowercased()
        if lower.hasPrefix("0x") {
            let digits = lower.dropFirst(2)
            guard !digits.isEmpty, digits.count <= 8 else { return nil }
            return UInt64(digits, radix: 16)
        }
        if lower.count > 1, lower.hasPrefix("0") {
            guard lower.count <= 12 else { return nil }
            return UInt64(lower, radix: 8)
        }
        guard lower.count <= 10, lower.allSatisfy(\.isNumber) else { return nil }
        return UInt64(lower, radix: 10)
    }
}
