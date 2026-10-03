import Foundation

/// RFC 3492 Punycode 인코더·디코더. IDNA 라벨(`xn--` 접두사)을 표시용 유니코드로 바꾸는 데 쓴다.
public enum Punycode {
    private static let base: UInt32 = 36
    private static let tMin: UInt32 = 1
    private static let tMax: UInt32 = 26
    private static let skew: UInt32 = 38
    private static let damp: UInt32 = 700
    private static let initialBias: UInt32 = 72
    private static let initialN: UInt32 = 128
    private static let delimiter: Character = "-"

    public static let acePrefix = "xn--"

    // MARK: - 라벨 단위

    /// `xn--` 접두사가 **없는** 퓨니코드 본문을 디코딩한다. 잘못된 입력이면 nil.
    public static func decode(_ input: String) -> String? {
        var output: [UInt32] = []
        var n = initialN
        var i: UInt32 = 0
        var bias = initialBias

        let scalars = Array(input.unicodeScalars)
        // 마지막 구분자 앞은 그대로 복사되는 기본(ASCII) 문자열
        var basicEnd = 0
        var index = 0
        if let lastDelim = scalars.lastIndex(where: { $0 == "-" }) {
            basicEnd = lastDelim
            index = lastDelim + 1
        }
        for j in 0..<basicEnd {
            guard scalars[j].value < 0x80 else { return nil }
            output.append(scalars[j].value)
        }
        while index < scalars.count {
            let oldi = i
            var w: UInt32 = 1
            var k = base
            while true {
                guard index < scalars.count else { return nil }
                guard let digit = digitValue(scalars[index]) else { return nil }
                index += 1
                let (mul, overflow1) = digit.multipliedReportingOverflow(by: w)
                guard !overflow1 else { return nil }
                let (sum, overflow2) = i.addingReportingOverflow(mul)
                guard !overflow2 else { return nil }
                i = sum
                let t: UInt32 = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                if digit < t { break }
                let (nw, overflow3) = w.multipliedReportingOverflow(by: base - t)
                guard !overflow3 else { return nil }
                w = nw
                k += base
            }
            let outLen = UInt32(output.count + 1)
            bias = adapt(delta: i - oldi, numPoints: outLen, firstTime: oldi == 0)
            let (nn, overflow4) = n.addingReportingOverflow(i / outLen)
            guard !overflow4 else { return nil }
            n = nn
            i %= outLen
            guard n <= 0x10FFFF, Unicode.Scalar(n) != nil else { return nil }
            output.insert(n, at: Int(i))
            i += 1
        }

        var view = String.UnicodeScalarView()
        for v in output {
            guard let s = Unicode.Scalar(v) else { return nil }
            view.append(s)
        }
        return String(view)
    }

    /// 유니코드 라벨을 퓨니코드 본문(접두사 없음)으로 인코딩한다.
    public static func encode(_ input: String) -> String? {
        let scalars = Array(input.unicodeScalars).map(\.value)
        var output: [UInt32] = []
        for v in scalars where v < 0x80 { output.append(v) }
        let basicCount = UInt32(output.count)
        var h = basicCount
        if basicCount > 0 { output.append(UInt32(UInt8(ascii: "-"))) }

        var n = initialN
        var delta: UInt32 = 0
        var bias = initialBias
        let total = UInt32(scalars.count)

        while h < total {
            guard let m = scalars.filter({ $0 >= n }).min() else { return nil }
            let (d1, o1) = (m - n).multipliedReportingOverflow(by: h + 1)
            guard !o1 else { return nil }
            let (d2, o2) = delta.addingReportingOverflow(d1)
            guard !o2 else { return nil }
            delta = d2
            n = m
            for c in scalars {
                if c < n {
                    let (d, o) = delta.addingReportingOverflow(1)
                    guard !o else { return nil }
                    delta = d
                }
                if c == n {
                    var q = delta
                    var k = base
                    while true {
                        let t: UInt32 = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                        if q < t { break }
                        output.append(encodeDigit(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(encodeDigit(q))
                    bias = adapt(delta: delta, numPoints: h + 1, firstTime: h == basicCount)
                    delta = 0
                    h += 1
                }
            }
            delta += 1
            n += 1
        }
        var view = String.UnicodeScalarView()
        for v in output {
            guard let s = Unicode.Scalar(v) else { return nil }
            view.append(s)
        }
        return String(view)
    }

    // MARK: - 호스트 단위

    /// 호스트의 `xn--` 라벨을 모두 디코딩한다. 디코딩 실패 라벨은 원문 유지.
    public static func decodeHost(_ host: String) -> String {
        host.split(separator: ".", omittingEmptySubsequences: false).map { label -> String in
            let s = String(label)
            guard s.lowercased().hasPrefix(acePrefix) else { return s }
            let body = String(s.dropFirst(acePrefix.count))
            return decode(body) ?? s
        }.joined(separator: ".")
    }

    /// 비ASCII 라벨을 `xn--` 라벨로 인코딩한다(소문자화 포함). 실패 라벨은 원문 유지.
    public static func encodeHost(_ host: String) -> String {
        host.split(separator: ".", omittingEmptySubsequences: false).map { label -> String in
            let s = String(label).lowercased()
            guard s.unicodeScalars.contains(where: { $0.value >= 0x80 }) else { return s }
            return encode(s).map { acePrefix + $0 } ?? s
        }.joined(separator: ".")
    }

    // MARK: - 내부

    private static func adapt(delta: UInt32, numPoints: UInt32, firstTime: Bool) -> UInt32 {
        var delta = firstTime ? delta / damp : delta / 2
        delta += delta / numPoints
        var k: UInt32 = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            k += base
        }
        return k + (base - tMin + 1) * delta / (delta + skew)
    }

    private static func digitValue(_ s: Unicode.Scalar) -> UInt32? {
        switch s.value {
        case 0x30...0x39: return s.value - 0x30 + 26   // 0-9
        case 0x41...0x5A: return s.value - 0x41        // A-Z
        case 0x61...0x7A: return s.value - 0x61        // a-z
        default: return nil
        }
    }

    private static func encodeDigit(_ d: UInt32) -> UInt32 {
        d < 26 ? d + 0x61 : d - 26 + 0x30
    }
}
