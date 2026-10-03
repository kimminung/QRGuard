import Foundation

/// URL 정규화 (TASKS T-1.3).
///
/// - 소문자 호스트, 끝 점 제거, 기본 포트 제거, 프래그먼트 분리
/// - 퍼센트 인코딩 비율·이중 인코딩(`%25XX`) 감지
/// - Punycode(RFC 3492) 디코딩 → 표시용 유니코드 호스트, 문자 체계(Script) 판별·혼합 감지
/// - userinfo(`@`) 분리, IP 리터럴(IPv4 축약형 `0x7f.1` 포함) 판별, PSL 기반 eTLD+1
public enum URLNormalizer {
    public static func normalize(_ url: URL, data: DataStore = .bundled) -> NormalizedURL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                ?? URLComponents(string: url.absoluteString)
                ?? percentEncodedComponents(url.absoluteString),
              let rawScheme = components.scheme else { return nil }
        let scheme = rawScheme.lowercased()
        components.scheme = scheme

        // 호스트: percentEncodedHost → 디코딩 → 비ASCII 라벨은 퓨니코드로. IPv6는 대괄호 유지.
        var host = (components.percentEncodedHost?.removingPercentEncoding ?? components.host ?? "").lowercased()
        while host.hasSuffix("."), host.count > 1 { host.removeLast() }
        let isIPv6 = IPAddressParser.isIPv6(host)
        if isIPv6 {
            if !host.hasPrefix("[") { host = "[" + host + "]" }
        } else if host.unicodeScalars.contains(where: { $0.value >= 0x80 }) {
            host = Punycode.encodeHost(host)
        }
        if !host.isEmpty {
            components.percentEncodedHost = host
        }

        // 기본 포트 제거
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        let port = components.port

        // 프래그먼트 분리
        let fragment = components.fragment
        components.fragment = nil

        // userinfo
        let userInfo: String? = components.user.map { user in
            components.password.map { "\(user):\($0)" } ?? user
        }

        let isIPv4 = !isIPv6 && IPAddressParser.canonicalIPv4(host) != nil
        let isIP = isIPv4 || isIPv6
        let labels = (host.isEmpty || isIPv6) ? [] : host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)

        // eTLD+1
        let registrable: String? = (isIP || host.isEmpty) ? nil : RegistrableDomain.list(for: data).registrableDomain(forHost: host)

        // 경로·쿼리
        let path = components.percentEncodedPath
        let query = components.percentEncodedQuery
        let queryItems: [URLQueryItem] = components.queryItems
            ?? components.percentEncodedQueryItems?.map {
                URLQueryItem(name: $0.name.removingPercentEncoding ?? $0.name, value: $0.value?.removingPercentEncoding ?? $0.value)
            }
            ?? []

        let encodedPortion = path + (query.map { "?" + $0 } ?? "")
        let ratio = percentEncodedRatio(of: encodedPortion)
        let doubleEncoded = hasDoubleEncoding(encodedPortion) || hasDoubleEncoding(host)

        // 표시용 유니코드 호스트·문자 체계
        let isIDN = labels.contains { $0.hasPrefix(Punycode.acePrefix) }
        let unicodeHost = isIDN ? Punycode.decodeHost(host) : host
        let (scripts, mixed) = HostScriptDetector.analyze(unicodeHost: unicodeHost)

        let normalized = components.url ?? url

        return NormalizedURL(
            original: url,
            normalized: normalized,
            scheme: scheme,
            host: host,
            unicodeHost: unicodeHost,
            registrableDomain: registrable,
            hostLabels: labels,
            isIPAddress: isIP,
            userInfo: userInfo,
            port: port,
            path: path,
            query: query,
            fragment: fragment,
            queryItems: queryItems,
            percentEncodedRatio: ratio,
            hasDoubleEncoding: doubleEncoded,
            isIDN: isIDN,
            scripts: scripts,
            hasMixedScript: mixed,
            length: url.absoluteString.count
        )
    }

    /// 문자열에서 바로 정규화한다(붙여넣기 입력 등). URL로 해석되지 않으면 nil.
    public static func normalize(string: String, data: DataStore = .bundled) -> NormalizedURL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) ?? percentEncodedComponents(trimmed)?.url else { return nil }
        return normalize(url, data: data)
    }

    // MARK: - 보조

    /// 인코딩되지 않은 유니코드가 섞인 원문을 퍼센트 인코딩해서 다시 시도한다.
    private static func percentEncodedComponents(_ raw: String) -> URLComponents? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.insert(charactersIn: "#[]@:/?")
        guard let encoded = raw.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URLComponents(string: encoded)
    }

    /// `%XX` 세 글자 묶음이 차지하는 비율(0...1).
    /// ASCII 바이트(0x00–0x7F)를 인코딩한 묶음만 센다 — 한글 경로처럼 UTF-8 다중 바이트를 인코딩한 것은 국제화일 뿐 난독화가 아니다.
    static func percentEncodedRatio(of text: String) -> Double {
        guard !text.isEmpty else { return 0 }
        var count = 0
        let chars = Array(text.utf8)
        var i = 0
        while i < chars.count {
            if chars[i] == UInt8(ascii: "%"), i + 2 < chars.count, isHex(chars[i + 1]), isHex(chars[i + 2]) {
                if hexValue(chars[i + 1]) < 8 { count += 1 }   // 상위 니블 < 8 → ASCII 바이트
                i += 3
            } else {
                i += 1
            }
        }
        return Double(count * 3) / Double(chars.count)
    }

    private static func hexValue(_ b: UInt8) -> UInt8 {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x41...0x46: return b - 0x41 + 10
        case 0x61...0x66: return b - 0x61 + 10
        default: return 0
        }
    }

    /// `%25` 뒤에 16진 두 자리가 따라오면 이중 인코딩으로 본다.
    static func hasDoubleEncoding(_ text: String) -> Bool {
        let chars = Array(text.utf8)
        guard chars.count >= 5 else { return false }
        for i in 0...(chars.count - 5) {
            if chars[i] == UInt8(ascii: "%"), chars[i + 1] == UInt8(ascii: "2"), chars[i + 2] == UInt8(ascii: "5"),
               isHex(chars[i + 3]), isHex(chars[i + 4]) {
                return true
            }
        }
        return false
    }

    private static func isHex(_ b: UInt8) -> Bool {
        (0x30...0x39).contains(b) || (0x41...0x46).contains(b) || (0x61...0x66).contains(b)
    }
}

/// 호스트 문자 체계(Script) 판별. 숫자·하이픈·점은 무시한다.
public enum HostScriptDetector {
    /// 라틴과 섞이면 혼동을 일으키기 쉬운 문자 체계.
    public static let confusableWithLatin: Set<HostScript> = [.cyrillic, .greek, .armenian]

    /// 호스트 전체의 문자 체계 집합과 혼합 여부.
    /// 혼합 = 한 라벨에 2개 이상의 체계가 있거나, TLD를 뺀 라벨들 사이에 라틴 + 혼동 체계(키릴·그리스·아르메니아)가 함께 쓰임.
    /// (TLD는 거의 항상 라틴이므로 `аррӏе.com`처럼 라벨 하나가 통째로 키릴인 경우는 B02의 몫으로 남긴다.)
    public static func analyze(unicodeHost: String) -> (scripts: Set<HostScript>, mixed: Bool) {
        var all = Set<HostScript>()
        var withoutTLD = Set<HostScript>()
        var mixed = false
        let labels = unicodeHost.split(separator: ".")
        for (index, label) in labels.enumerated() {
            var labelScripts = Set<HostScript>()
            for scalar in label.unicodeScalars {
                if let s = script(of: scalar) { labelScripts.insert(s) }
            }
            if labelScripts.count >= 2 { mixed = true }
            all.formUnion(labelScripts)
            if index < labels.count - 1 { withoutTLD.formUnion(labelScripts) }
        }
        if withoutTLD.contains(.latin), !withoutTLD.isDisjoint(with: confusableWithLatin) { mixed = true }
        return (all, mixed)
    }

    /// 스칼라의 문자 체계. 숫자·구두점·기호는 nil.
    public static func script(of s: Unicode.Scalar) -> HostScript? {
        let v = s.value
        switch v {
        case 0x30...0x39, 0x2D, 0x2E, 0x5F: return nil                    // 0-9 - . _
        case 0x41...0x5A, 0x61...0x7A: return .latin
        case 0x00C0...0x024F, 0x1E00...0x1EFF, 0x2C60...0x2C7F, 0xA720...0xA7FF, 0xFF21...0xFF3A, 0xFF41...0xFF5A:
            if v == 0x00D7 || v == 0x00F7 { return nil }                  // × ÷
            return .latin
        case 0x0250...0x02AF: return .latin                               // IPA 확장(ɡ ɩ 등)
        case 0x0370...0x03FF, 0x1F00...0x1FFF: return .greek
        case 0x0400...0x052F, 0x2DE0...0x2DFF, 0xA640...0xA69F, 0x1C80...0x1C8F: return .cyrillic
        case 0x0530...0x058F, 0xFB13...0xFB17: return .armenian
        case 0x0590...0x05FF, 0xFB1D...0xFB4F: return .hebrew
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return .arabic
        case 0x0900...0x097F, 0xA8E0...0xA8FF: return .devanagari
        case 0x0E00...0x0E7F: return .thai
        case 0x10A0...0x10FF, 0x2D00...0x2D2F, 0x1C90...0x1CBF: return .georgian
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7FF: return .hangul
        case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return .kana
        case 0x2E80...0x2FDF, 0x3005...0x3007, 0x3021...0x3029, 0x3038...0x303B, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xF900...0xFAFF, 0x20000...0x3134F: return .han
        case 0x2000...0x206F, 0x3000...0x3004, 0xFF00...0xFF20, 0xFF3B...0xFF40, 0xFF5B...0xFF65: return nil // 구두점·전각 기호·숫자
        default:
            return s.properties.isAlphabetic ? .other : nil
        }
    }
}
