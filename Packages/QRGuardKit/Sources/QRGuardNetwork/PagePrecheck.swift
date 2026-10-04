import Foundation
import QRGuardCore

/// 페이지 사전 검사 (TASKS T-4.6, RISK_RULES 3.7).
/// 최종 URL의 HTML **앞부분 최대 256KB**를 쿠키 없이 받아 정규식으로만 훑는다. 렌더링·JS 실행 없음.
public struct PagePrecheck: PagePrechecking {
    public static let defaultMaxBytes = 262_144

    private let session: URLSession
    private let maxBytes: Int

    /// - Parameter configuration: 기본은 강화 설정. 리다이렉트는 따라가지 않는다(3xx면 그 응답의 Content-Type만 기록).
    public init(configuration: URLSessionConfiguration = HardenedSession.configuration(requestTimeout: 4), maxBytes: Int = PagePrecheck.defaultMaxBytes) {
        session = URLSession(configuration: configuration, delegate: RedirectRefusingDelegate(), delegateQueue: nil)
        self.maxBytes = maxBytes
    }

    public func precheck(_ url: URL, timeout: Duration) async throws -> PagePrecheckResult {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else {
            throw URLError(.unsupportedURL)
        }
        if let host = url.host, PrivateAddressChecker.isPrivateOrLocal(host: host) {
            throw URLError(.unsupportedURL)
        }
        var mutableRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        mutableRequest.httpMethod = "GET"
        mutableRequest.httpShouldHandleCookies = false
        mutableRequest.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        mutableRequest.timeoutInterval = RedirectResolver.seconds(timeout)
        let request = mutableRequest

        let session = self.session
        let maxBytes = self.maxBytes
        do {
            return try await withTimeout(timeout) {
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    bytes.task.cancel()
                    throw URLError(.badServerResponse)
                }
                let contentType = http.value(forHTTPHeaderField: "Content-Type")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                guard Self.isHTML(contentType: contentType) else {
                    bytes.task.cancel()
                    return PagePrecheckResult(contentType: contentType, bytesRead: 0)
                }

                var data = Data()
                data.reserveCapacity(min(maxBytes, Int(max(0, http.expectedContentLength))))
                do {
                    for try await byte in bytes {
                        data.append(byte)
                        if data.count >= maxBytes { break }
                    }
                } catch {
                    // 일부라도 받았으면 그걸로 분석한다.
                    if data.isEmpty { throw error }
                }
                bytes.task.cancel()

                let html = Self.decode(data, contentType: contentType)
                var result = HTMLScanner.scan(html, pageURL: url)
                result.contentType = contentType
                result.bytesRead = data.count
                return result
            }
        } catch let error as URLError where error.isTLSFailure {
            return PagePrecheckResult(tlsFailed: true)
        }
    }

    static func isHTML(contentType: String?) -> Bool {
        guard let contentType else { return true } // 미상이면 시도(파싱은 텍스트 기반이라 안전)
        let mime = contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? contentType
        return mime == "text/html" || mime == "application/xhtml+xml"
    }

    static func decode(_ data: Data, contentType: String?) -> String {
        if let contentType, let range = contentType.range(of: "charset=") {
            let charset = contentType[range.upperBound...]
                .split(separator: ";").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) } ?? ""
            let encoding: String.Encoding?
            switch charset {
            case "euc-kr", "ks_c_5601-1987", "ksc5601", "cp949": encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
            case "iso-8859-1", "latin1": encoding = .isoLatin1
            case "shift_jis", "sjis": encoding = .shiftJIS
            case "euc-jp": encoding = .japaneseEUC
            case "windows-1252", "cp1252": encoding = .windowsCP1252
            default: encoding = nil
            }
            if let encoding, let text = String(data: data, encoding: encoding) { return text }
        }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - 정규식 기반 HTML 스캐너

/// 태그를 렌더링하지 않고 문자열 패턴만 본다. 보수적으로 동작한다(주석 안의 password input도 발견으로 친다).
enum HTMLScanner {
    static let leadingTextLimit = 2048

    static func scan(_ html: String, pageURL: URL) -> PagePrecheckResult {
        var result = PagePrecheckResult()
        var altTexts: [String] = []

        for tag in tags(in: html) {
            switch tag.name {
            case "input":
                if tag.attributes["type"]?.lowercased() == "password" { result.hasPasswordInput = true }
            case "form":
                if let action = tag.attributes["action"], let host = resolveHost(action, relativeTo: pageURL),
                   !result.formActionHosts.contains(host) {
                    result.formActionHosts.append(host)
                }
            case "meta":
                if tag.attributes["http-equiv"]?.lowercased() == "refresh",
                   result.metaRefreshTarget == nil,
                   let content = tag.attributes["content"],
                   let target = parseMetaRefresh(content, relativeTo: pageURL) {
                    result.metaRefreshTarget = target
                }
            case "img":
                if let alt = tag.attributes["alt"], altTexts.count < 10 {
                    let cleaned = collapseWhitespace(decodeEntities(alt))
                    if !cleaned.isEmpty { altTexts.append(cleaned) }
                }
            default:
                break
            }
        }

        result.title = title(in: html)
        let body = visibleText(in: html)
        let combined = (altTexts + [body]).joined(separator: " ")
        result.leadingText = String(collapseWhitespace(combined).prefix(leadingTextLimit))
        // V09: 숨김 영역(display:none 등)의 텍스트와 불가시 문자 수 — 탐지 회피·인젝션 신호
        result.hiddenText = String(InputSanitizer.hiddenText(inHTML: html).prefix(leadingTextLimit))
        result.invisibleCharacterCount = InputSanitizer.invisibleCharacterCount(in: html)
        return result
    }

    // MARK: 태그·속성

    struct Tag {
        var name: String
        var attributes: [String: String]
    }

    private static let tagRegex = try! NSRegularExpression(
        pattern: #"<(input|form|meta|img)\b([^>]*)>"#, options: [.caseInsensitive]
    )
    private static let attributeRegex = try! NSRegularExpression(
        pattern: #"([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#, options: []
    )
    private static let titleRegex = try! NSRegularExpression(
        pattern: #"<title\b[^>]*>([\s\S]*?)</title\s*>"#, options: [.caseInsensitive]
    )
    private static let removalRegex = try! NSRegularExpression(
        pattern: #"<script\b[\s\S]*?</script\s*>|<style\b[\s\S]*?</style\s*>|<!--[\s\S]*?-->|<head\b[\s\S]*?</head\s*>|<template\b[\s\S]*?</template\s*>"#,
        options: [.caseInsensitive]
    )
    private static let anyTagRegex = try! NSRegularExpression(pattern: #"<[^>]*>"#, options: [])
    private static let whitespaceRegex = try! NSRegularExpression(pattern: #"\s+"#, options: [])

    static func tags(in html: String) -> [Tag] {
        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)
        return tagRegex.matches(in: html, options: [], range: range).map { match in
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            let attrs = attributes(in: ns.substring(with: match.range(at: 2)))
            return Tag(name: name, attributes: attrs)
        }
    }

    static func attributes(in text: String) -> [String: String] {
        let ns = text as NSString
        var result: [String: String] = [:]
        for match in attributeRegex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            var value = ""
            for group in 2...4 {
                let r = match.range(at: group)
                if r.location != NSNotFound { value = ns.substring(with: r); break }
            }
            if result[name] == nil { result[name] = decodeEntities(value) }
        }
        return result
    }

    static func title(in html: String) -> String? {
        let ns = html as NSString
        guard let match = titleRegex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let raw = ns.substring(with: match.range(at: 1))
        let cleaned = collapseWhitespace(decodeEntities(stripTags(raw)))
        return cleaned.isEmpty ? nil : String(cleaned.prefix(300))
    }

    static func visibleText(in html: String) -> String {
        let withoutBlocks = removalRegex.stringByReplacingMatches(
            in: html, options: [], range: NSRange(location: 0, length: (html as NSString).length), withTemplate: " "
        )
        // 전체를 처리하면 비용이 크므로 앞부분만(태그 포함 64KB) 본다.
        let head = String(withoutBlocks.prefix(65_536))
        return collapseWhitespace(decodeEntities(stripTags(head)))
    }

    static func stripTags(_ text: String) -> String {
        anyTagRegex.stringByReplacingMatches(
            in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length), withTemplate: " "
        )
    }

    static func collapseWhitespace(_ text: String) -> String {
        whitespaceRegex.stringByReplacingMatches(
            in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length), withTemplate: " "
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 엔티티

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "copy": "©", "reg": "®",
        "middot": "·", "hellip": "…", "ndash": "–", "mdash": "—", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        var i = text.startIndex
        while i < text.endIndex {
            guard text[i] == "&", let semi = text[i...].prefix(12).firstIndex(of: ";") else {
                out.append(text[i])
                i = text.index(after: i)
                continue
            }
            let entity = text[text.index(after: i)..<semi]
            var replacement: String?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                if let code = UInt32(entity.dropFirst(2), radix: 16), let scalar = UnicodeScalar(code) { replacement = String(Character(scalar)) }
            } else if entity.hasPrefix("#") {
                if let code = UInt32(entity.dropFirst(1)), let scalar = UnicodeScalar(code) { replacement = String(Character(scalar)) }
            } else {
                replacement = namedEntities[String(entity).lowercased()]
            }
            if let replacement {
                out.append(replacement)
                i = text.index(after: semi)
            } else {
                out.append(text[i])
                i = text.index(after: i)
            }
        }
        return out
    }

    // MARK: URL 해석

    static func resolveHost(_ action: String, relativeTo pageURL: URL) -> String? {
        let trimmed = action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("javascript:") || lower.hasPrefix("data:") || lower.hasPrefix("mailto:") || lower.hasPrefix("#") {
            return nil
        }
        guard let url = URL(string: trimmed, relativeTo: pageURL)?.absoluteURL
                ?? trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap({ URL(string: $0, relativeTo: pageURL)?.absoluteURL }),
              let host = url.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        return host
    }

    /// `content="0; url=https://…"` → 대상 URL. `url=` 없이 주소만 오는 변형도 허용.
    static func parseMetaRefresh(_ content: String, relativeTo pageURL: URL) -> URL? {
        guard let semi = content.firstIndex(where: { $0 == ";" || $0 == "," }) else { return nil }
        var rest = content[content.index(after: semi)...].trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.lowercased().hasPrefix("url") {
            rest = String(rest.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("=") else { return nil }
            rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        guard !rest.isEmpty else { return nil }
        guard let url = URL(string: rest, relativeTo: pageURL)?.absoluteURL
                ?? rest.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap({ URL(string: $0, relativeTo: pageURL)?.absoluteURL }),
              url.scheme != nil else {
            return nil
        }
        return url
    }
}
