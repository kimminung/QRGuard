import Foundation

/// QR 원문 → `QRPayload` (TASKS T-1.1).
///
/// 인식 순서: `WIFI:` → `MATMSG:`/`MECARD:`/`BEGIN:VCARD` → `SMSTO:`/`sms:` → `tel:` → `mailto:` → `geo:` →
/// 암호화폐(`bitcoin:` 등) → 계좌번호 패턴 → `http(s)` URL → 기타 스킴(`://` 포함 또는 알려진 앱 스킴·위험 스킴) → 텍스트(내장 URL 추출).
/// 앞뒤 공백을 제거하고 스킴은 대소문자를 구분하지 않는다.
public enum PayloadParser {
    /// P01·P02가 평가해야 하는 위험 스킴. `://` 없이도 `.appScheme`으로 분류해 규칙까지 전달한다.
    static let dangerousSchemes: Set<String> = ["javascript", "data", "file", "blob", "itms-services", "itms", "itms-apps", "vbscript"]
    static let cryptoSchemes: [String: PaymentPayload.Scheme] = [
        "bitcoin": .bitcoin, "ethereum": .ethereum, "litecoin": .litecoin,
        "bitcoincash": .other, "dogecoin": .other, "monero": .other, "ripple": .other, "tron": .other, "solana": .other,
    ]

    public static func parse(_ raw: String, data: DataStore = .bundled) -> QRPayload {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .text(trimmed, embeddedURLs: []) }
        let lower = trimmed.lowercased()

        if lower.hasPrefix("wifi:"), let wifi = parseWiFi(trimmed) {
            return .wifi(wifi)
        }
        if lower.hasPrefix("matmsg:"), let email = parseMATMSG(trimmed) {
            return email
        }
        if lower.hasPrefix("mecard:") || lower.hasPrefix("begin:vcard") {
            return .contact(raw: trimmed)
        }
        if lower.hasPrefix("smsto:") || lower.hasPrefix("sms:") || lower.hasPrefix("mms:") || lower.hasPrefix("mmsto:") {
            return parseSMS(trimmed)
        }
        if lower.hasPrefix("tel:") {
            let number = String(trimmed.dropFirst(4)).removingPercentEncoding ?? String(trimmed.dropFirst(4))
            return .phone(number.trimmingCharacters(in: .whitespaces))
        }
        if lower.hasPrefix("mailto:") {
            return parseMailto(trimmed)
        }
        if lower.hasPrefix("geo:"), let geo = parseGeo(trimmed) {
            return geo
        }
        if let colon = lower.firstIndex(of: ":") {
            let scheme = String(lower[..<colon])
            if let crypto = cryptoSchemes[scheme] {
                return .payment(parseCrypto(trimmed, scheme: crypto))
            }
        }
        if let account = parseBankAccount(trimmed) {
            return .payment(account)
        }

        if let url = URL(string: trimmed) ?? percentEncodedURL(trimmed), let scheme = url.scheme?.lowercased(), isValidScheme(scheme) {
            if scheme == "http" || scheme == "https" {
                return .url(url)
            }
            let hasAuthority = lower.hasPrefix(scheme + "://")
            if hasAuthority || dangerousSchemes.contains(scheme) || data.appScheme(for: scheme) != nil {
                return .appScheme(url)
            }
        }

        return .text(trimmed, embeddedURLs: urls(in: trimmed))
    }

    /// 텍스트 안의 첫 번째 URL.
    public static func firstURL(in text: String) -> URL? {
        urls(in: text).first
    }

    /// 텍스트 안의 모든 http(s) URL(맨 도메인 `example.com/path` 포함). 중복 제거.
    public static func urls(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        var result: [URL] = []
        for match in detector.matches(in: text, options: [], range: range) {
            guard let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
            if seen.insert(url.absoluteString).inserted { result.append(url) }
        }
        return result
    }

    // MARK: - WIFI:T:WPA;S:ssid;P:pass;H:true;;

    static func parseWiFi(_ raw: String) -> WiFiConfig? {
        let body = String(raw.dropFirst("WIFI:".count))
        let fields = splitEscapedFields(body)
        var ssid: String?
        var type: String?
        var password: String?
        var hidden = false
        for (key, value) in fields {
            switch key.uppercased() {
            case "S": ssid = value
            case "T": type = value
            case "P": password = value
            case "H": hidden = ["true", "1", "yes"].contains(value.lowercased())
            default: break
            }
        }
        guard let ssid, !ssid.isEmpty else { return nil }
        let security: WiFiConfig.Security
        switch (type ?? "").uppercased() {
        case "", "NOPASS", "NONE", "OPEN": security = .nopass
        case "WEP": security = .wep
        case let t where t.hasPrefix("WPA") || t == "SAE" || t == "RSN": security = .wpa
        default: security = .other
        }
        let pw = (password?.isEmpty ?? true) ? nil : password
        return WiFiConfig(ssid: ssid, security: security, password: pw, isHidden: hidden)
    }

    /// `KEY:value;KEY:value;;` 형식을 (key, value) 배열로. `\;` `\:` `\\` `\,` 이스케이프를 푼다.
    static func splitEscapedFields(_ body: String) -> [(String, String)] {
        var fields: [(String, String)] = []
        var current = ""
        var escaped = false
        var segments: [String] = []
        for ch in body {
            if escaped {
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == ";" {
                segments.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { segments.append(current) }
        for segment in segments where !segment.isEmpty {
            guard let colon = segment.firstIndex(of: ":") else { continue }
            let key = String(segment[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(segment[segment.index(after: colon)...])
            fields.append((key, value))
        }
        return fields
    }

    // MARK: - SMS

    static func parseSMS(_ raw: String) -> QRPayload {
        guard let colon = raw.firstIndex(of: ":") else { return .text(raw, embeddedURLs: urls(in: raw)) }
        let rest = String(raw[raw.index(after: colon)...])
        // sms:number?body=... (RFC 5724)
        if let q = rest.firstIndex(of: "?") {
            let number = String(rest[..<q]).removingPercentEncoding ?? String(rest[..<q])
            let query = String(rest[rest.index(after: q)...])
            var body: String?
            if let items = URLComponents(string: "?" + query)?.queryItems {
                body = items.first { $0.name.lowercased() == "body" }?.value
            }
            if body == nil, let fallback = URLComponents(string: "?" + query.replacingOccurrences(of: " ", with: "%20"))?.queryItems {
                body = fallback.first { $0.name.lowercased() == "body" }?.value
            }
            return .sms(number: number.trimmingCharacters(in: .whitespaces), body: body.flatMap { $0.isEmpty ? nil : $0 })
        }
        // SMSTO:number:body
        if let second = rest.firstIndex(of: ":") {
            let number = String(rest[..<second])
            let body = String(rest[rest.index(after: second)...])
            return .sms(number: number.trimmingCharacters(in: .whitespaces), body: body.isEmpty ? nil : body)
        }
        return .sms(number: rest.trimmingCharacters(in: .whitespaces), body: nil)
    }

    // MARK: - 이메일

    static func parseMailto(_ raw: String) -> QRPayload {
        let rest = String(raw.dropFirst("mailto:".count))
        var address = rest
        var subject: String?
        var body: String?
        if let q = rest.firstIndex(of: "?") {
            address = String(rest[..<q])
            let query = String(rest[rest.index(after: q)...])
            let items = URLComponents(string: "?" + query)?.queryItems
                ?? URLComponents(string: "?" + query.replacingOccurrences(of: " ", with: "%20"))?.queryItems
                ?? []
            subject = items.first { $0.name.lowercased() == "subject" }?.value
            body = items.first { $0.name.lowercased() == "body" }?.value
        }
        address = address.removingPercentEncoding ?? address
        return .email(address: address.trimmingCharacters(in: .whitespaces), subject: subject, body: body)
    }

    static func parseMATMSG(_ raw: String) -> QRPayload? {
        let body = String(raw.dropFirst("MATMSG:".count))
        var to: String?
        var sub: String?
        var msg: String?
        for (key, value) in splitEscapedFields(body) {
            switch key.uppercased() {
            case "TO": to = value
            case "SUB": sub = value
            case "BODY": msg = value
            default: break
            }
        }
        guard let to, !to.isEmpty else { return nil }
        return .email(address: to.trimmingCharacters(in: .whitespaces), subject: sub, body: msg)
    }

    // MARK: - geo:lat,lon[,alt][?q=]

    static func parseGeo(_ raw: String) -> QRPayload? {
        var rest = String(raw.dropFirst("geo:".count))
        if let q = rest.firstIndex(where: { $0 == "?" || $0 == ";" }) { rest = String(rest[..<q]) }
        let parts = rest.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return .geo(latitude: lat, longitude: lon)
    }

    // MARK: - 결제

    static func parseCrypto(_ raw: String, scheme: PaymentPayload.Scheme) -> PaymentPayload {
        guard let colon = raw.firstIndex(of: ":") else {
            return PaymentPayload(scheme: scheme, address: raw, amount: nil, url: nil)
        }
        let rest = String(raw[raw.index(after: colon)...])
        var address = rest
        var amount: String?
        if let q = rest.firstIndex(of: "?") {
            address = String(rest[..<q])
            let items = URLComponents(string: "?" + String(rest[rest.index(after: q)...]))?.queryItems ?? []
            amount = items.first { ["amount", "value", "uint256"].contains($0.name.lowercased()) }?.value
        }
        // ethereum:addr@chainId 형식의 체인 ID 제거
        if let at = address.firstIndex(of: "@") { address = String(address[..<at]) }
        if address.hasPrefix("//") { address.removeFirst(2) }
        return PaymentPayload(scheme: scheme, address: address, amount: amount, url: URL(string: raw) ?? percentEncodedURL(raw))
    }

    /// 한국 은행 계좌번호처럼 보이는 텍스트. "계좌" 또는 은행명 + 하이픈으로 나뉜 10자리 이상 숫자.
    static func parseBankAccount(_ raw: String) -> PaymentPayload? {
        let bankWords = ["계좌", "은행", "뱅크", "국민", "신한", "우리", "하나", "농협", "기업", "카카오뱅크", "토스뱅크", "케이뱅크",
                         "새마을", "수협", "부산", "대구", "광주", "전북", "경남", "제주", "씨티", "SC제일", "우체국", "신협", "입금", "송금"]
        guard bankWords.contains(where: { raw.contains($0) }) else { return nil }
        guard let regex = try? NSRegularExpression(pattern: #"\d{2,6}(?:-\d{2,8}){1,3}"#) else { return nil }
        let range = NSRange(raw.startIndex..., in: raw)
        for match in regex.matches(in: raw, options: [], range: range) {
            guard let r = Range(match.range, in: raw) else { continue }
            let candidate = String(raw[r])
            let digits = candidate.filter(\.isNumber)
            // 휴대전화(010-xxxx-xxxx)는 제외
            if digits.count >= 10, !candidate.hasPrefix("010"), !candidate.hasPrefix("+82") {
                var amount: String?
                if let amtRegex = try? NSRegularExpression(pattern: #"([\d,]{2,})\s*원"#),
                   let m = amtRegex.firstMatch(in: raw, options: [], range: range),
                   let ar = Range(m.range(at: 1), in: raw) {
                    amount = String(raw[ar])
                }
                return PaymentPayload(scheme: .bankAccount, address: candidate, amount: amount, url: nil)
            }
        }
        return nil
    }

    // MARK: - 보조

    static func isValidScheme(_ scheme: String) -> Bool {
        guard let first = scheme.first, first.isLetter, first.isASCII else { return false }
        return scheme.unicodeScalars.allSatisfy { s in
            (s.value >= 0x61 && s.value <= 0x7A) || (s.value >= 0x30 && s.value <= 0x39) || s == "+" || s == "-" || s == "."
        }
    }

    static func percentEncodedURL(_ raw: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.insert(charactersIn: "#[]@:/?")
        guard let encoded = raw.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: encoded)
    }
}
