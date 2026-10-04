import Foundation

/// 공격자가 통제하는 텍스트(QR 원문·페이지 숨김 텍스트·OCR 결과)를 규칙·모델에 넘기기 전에 정제한다.
/// (AI_ONDEVICE_DEFENSE.md 5장 · T-8.1, 순수 Foundation)
///
/// - 불가시 문자(`Cf` 범주·BOM·소프트 하이픈·단어 결합자·한글 채움 문자) 제거 + 개수 집계
/// - 양방향 재정렬 제어 문자(U+202A–U+202E, U+2066–U+2069) 제거 + 플래그
/// - NFKC(전각 → 반각 등) 정규화
/// - 호환 자모 나열(`ㅂㅏㄴ`) → 음절(`반`) 재조합(최선 노력)
/// - 분석 도구를 겨냥한 지시문(프롬프트 주입) 패턴 탐지
/// - HTML에서 사용자에게 보이지 않는 요소의 텍스트 추출
public enum InputSanitizer {

    // MARK: - 결과 타입

    public struct SanitizedText: Sendable, Hashable {
        /// 정제된 텍스트(규칙·모델 입력용)
        public let cleaned: String
        /// 제거한 불가시 문자 수(양방향 제어 문자 포함)
        public let removedInvisibleCount: Int
        /// 양방향 재정렬·격리 제어 문자가 있었는지
        public let hadBidiOverride: Bool
        /// NFKC 정규화가 텍스트를 바꿨는지(전각 영숫자·결합 문자 등)
        public let nfkcChanged: Bool
        /// 호환 자모 나열을 음절로 합친 횟수
        public let composedSyllableCount: Int

        public init(cleaned: String, removedInvisibleCount: Int, hadBidiOverride: Bool, nfkcChanged: Bool, composedSyllableCount: Int = 0) {
            self.cleaned = cleaned
            self.removedInvisibleCount = removedInvisibleCount
            self.hadBidiOverride = hadBidiOverride
            self.nfkcChanged = nfkcChanged
            self.composedSyllableCount = composedSyllableCount
        }

        /// 정제 과정에서 무언가 바뀌었는지.
        public var wasModified: Bool { removedInvisibleCount > 0 || nfkcChanged || composedSyllableCount > 0 }
    }

    public struct InjectionMatch: Sendable, Hashable {
        /// 일치한 패턴(정규식 원문). 디버깅·테스트용
        public let pattern: String
        /// 정제된 텍스트에서 일치한 조각(최대 80자)
        public let snippet: String

        public init(pattern: String, snippet: String) {
            self.pattern = pattern
            self.snippet = snippet
        }
    }

    // MARK: - 불가시 문자

    /// `Cf`가 아니지만 화면에 아무것도 그리지 않는 문자(한글 채움 문자 등).
    static let extraInvisibleScalars: Set<UInt32> = [
        0x115F, 0x1160,   // Hangul choseong/jungseong filler
        0x3164,           // Hangul filler
        0xFFA0,           // halfwidth Hangul filler
    ]

    static func isBidiControl(_ scalar: Unicode.Scalar) -> Bool {
        (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
    }

    /// 제거 대상 불가시 문자인지. 이모지 사이의 ZWJ(가족 이모지 등)는 정상 사용이라 제외한다.
    static func isInvisible(_ scalar: Unicode.Scalar, previous: Unicode.Scalar?, next: Unicode.Scalar?) -> Bool {
        if extraInvisibleScalars.contains(scalar.value) { return true }
        guard scalar.properties.generalCategory == .format else { return false }
        if scalar.value == 0x200D, let previous, let next, isEmojiLike(previous), isEmojiLike(next) { return false }
        return true
    }

    private static func isEmojiLike(_ scalar: Unicode.Scalar) -> Bool {
        let p = scalar.properties
        return p.isEmojiPresentation || p.isEmojiModifier || p.isEmojiModifierBase || scalar.value == 0xFE0F
    }

    /// 텍스트의 불가시 문자 수(제거하지 않고 세기만). 페이지 사전 검사가 `invisibleCharacterCount`를 채울 때 쓴다.
    public static func invisibleCharacterCount(in text: String) -> Int {
        let scalars = Array(text.unicodeScalars)
        var count = 0
        for (i, s) in scalars.enumerated() {
            let prev = i > 0 ? scalars[i - 1] : nil
            let next = i + 1 < scalars.count ? scalars[i + 1] : nil
            if isInvisible(s, previous: prev, next: next) { count += 1 }
        }
        return count
    }

    // MARK: - 정제

    public static func sanitize(_ text: String) -> SanitizedText {
        // 1) 불가시·양방향 제어 문자 제거
        let scalars = Array(text.unicodeScalars)
        var kept = String.UnicodeScalarView()
        var removed = 0
        var bidi = false
        for (i, s) in scalars.enumerated() {
            let prev = i > 0 ? scalars[i - 1] : nil
            let next = i + 1 < scalars.count ? scalars[i + 1] : nil
            if isBidiControl(s) { bidi = true; removed += 1; continue }
            if isInvisible(s, previous: prev, next: next) { removed += 1; continue }
            kept.append(s)
        }
        let stripped = String(kept)

        // 2) 호환 자모 구간과 나머지를 나눠, 나머지는 NFKC, 자모 구간은 음절 재조합
        var output = ""
        var nfkcChanged = false
        var composed = 0
        var run = String.UnicodeScalarView()
        var runIsJamo: Bool? = nil

        func flush() {
            guard !run.isEmpty, let isJamo = runIsJamo else { return }
            let piece = String(run)
            if isJamo {
                let (text, n) = HangulCompatJamo.compose(piece)
                composed += n
                output += text
            } else {
                let nfkc = piece.precomposedStringWithCompatibilityMapping
                if nfkc != piece { nfkcChanged = true }
                output += nfkc
            }
            run = String.UnicodeScalarView()
        }

        for s in stripped.unicodeScalars {
            let isJamo = HangulCompatJamo.isCompatibilityJamo(s)
            if runIsJamo != isJamo { flush(); runIsJamo = isJamo }
            run.append(s)
        }
        flush()

        return SanitizedText(
            cleaned: output,
            removedInvisibleCount: removed,
            hadBidiOverride: bidi,
            nfkcChanged: nfkcChanged,
            composedSyllableCount: composed
        )
    }

    // MARK: - 지시문(프롬프트 주입) 탐지

    /// 분석 도구·모델을 겨냥한 지시문 패턴. 대소문자 무시. 정제(불가시 제거·NFKC) 후 적용한다.
    static let injectionPatterns: [String] = [
        // 영어
        #"ignore\s+(all\s+|the\s+|any\s+)?(previous|prior|above|earlier)\s+instructions"#,
        #"disregard\b.{0,40}\binstructions"#,
        #"system\s*prompt"#,
        #"\byou\s+are\s+(now\s+)?(a|an)\s"#,
        #"\bas\s+an\s+ai\b"#,
        #"classify\s+(this|it)\s+as\s+safe"#,
        #"\bmark\b.{0,40}\bsafe\b"#,
        #"\boutput\b.{0,40}\bscore\s*(of\s*|:\s*|=\s*)?0\b"#,
        #"\bqr\s*guard\b"#,
        // 한국어
        #"검증\s*완료"#,
        #"보안\s*인증\s*완료"#,
        #"안전하다고\s*(출력|분류|판정|표시)"#,
        #"안전(한|으로)\s*(사이트|페이지|링크)?\s*(로\s*)?(출력|분류|판정|표시)"#,
        #"안전한\s*(사이트|페이지|링크)\s*(입니다|예요|이에요|임|이다|라고)"#,
        #"지시(를|사항을|사항은|는)?\s*무시"#,
        #"이전\s*(지시|명령|프롬프트)"#,
        #"시스템\s*프롬프트"#,
        #"(너는|당신은|넌)\s*이제"#,
        #"점수(를|는|가)?\s*0(?![0-9.])"#,
    ]

    private static let compiledInjectionPatterns: [(String, NSRegularExpression)] = injectionPatterns.compactMap { p in
        (try? NSRegularExpression(pattern: p, options: [.caseInsensitive])).map { (p, $0) }
    }

    /// 지시문 패턴이 있으면 첫 일치 조각을 돌려준다. 입력은 내부에서 정제한다(불가시 문자로 쪼갠 단어도 잡힌다).
    public static func detectsInjection(in text: String) -> InjectionMatch? {
        guard !text.isEmpty else { return nil }
        let cleaned = sanitize(text).cleaned
        let ns = cleaned as NSString
        let full = NSRange(location: 0, length: ns.length)
        for (pattern, regex) in compiledInjectionPatterns {
            if let m = regex.firstMatch(in: cleaned, options: [], range: full) {
                var snippet = ns.substring(with: m.range).trimmingCharacters(in: .whitespacesAndNewlines)
                if snippet.count > 80 { snippet = String(snippet.prefix(80)) }
                return InjectionMatch(pattern: pattern, snippet: snippet)
            }
        }
        return nil
    }

    // MARK: - HTML 숨김 텍스트

    private static let openTagRegex = try! NSRegularExpression(
        pattern: #"<([a-zA-Z][a-zA-Z0-9:-]*)\b([^<>]*)>"#, options: []
    )
    private static let hiddenAttributeRegexes: [NSRegularExpression] = [
        #"display\s*:\s*none"#,
        #"visibility\s*:\s*hidden"#,
        #"font-size\s*:\s*0+(\.0+)?\s*(px|pt|em|rem|%|vw|vh)?\s*(;|!|"|'|$)"#,
        #"opacity\s*:\s*0+(\.0+)?\s*(;|!|"|'|$)"#,
        #"(?:^|[\s;"'])(left|top|text-indent)\s*:\s*-\d{4,}"#,
        #"aria-hidden\s*=\s*["']?\s*true"#,
        #"(?:^|\s)hidden(?=\s|=|/|$)"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    private static let anyTagRegex = try! NSRegularExpression(pattern: #"<[^>]*>"#, options: [])
    private static let whitespaceRegex = try! NSRegularExpression(pattern: #"\s+"#, options: [])
    /// 닫는 태그가 없는 요소. 숨김 속성이 있어도 내용이 없으므로 건너뛴다.
    private static let voidElements: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]

    static let maxHTMLLength = 256 * 1024
    static let maxSegmentLength = 2_048
    static let maxSegments = 50

    /// `display:none`·`visibility:hidden`·`font-size:0`·`opacity:0`·`aria-hidden="true"`·`hidden` 요소 안의 텍스트.
    /// 중첩은 느슨하게 처리한다(같은 이름의 첫 닫는 태그까지). 자바스크립트는 실행하지 않는다.
    public static func hiddenTextSegments(inHTML html: String) -> [String] {
        guard !html.isEmpty else { return [] }
        let source = html.count > maxHTMLLength ? String(html.prefix(maxHTMLLength)) : html
        let ns = source as NSString
        var segments: [String] = []
        var searchFrom = 0

        while searchFrom < ns.length, segments.count < maxSegments {
            let range = NSRange(location: searchFrom, length: ns.length - searchFrom)
            guard let tag = openTagRegex.firstMatch(in: source, options: [], range: range) else { break }
            let tagEnd = tag.range.location + tag.range.length
            searchFrom = tagEnd
            let name = ns.substring(with: tag.range(at: 1)).lowercased()
            let attributes = ns.substring(with: tag.range(at: 2))
            guard !voidElements.contains(name), !attributes.hasSuffix("/") else { continue }
            guard isHiddenAttributes(attributes) else { continue }

            // 같은 이름의 첫 닫는 태그까지
            let closeRange = ns.range(of: "</\(name)", options: [.caseInsensitive], range: NSRange(location: tagEnd, length: ns.length - tagEnd))
            guard closeRange.location != NSNotFound else { continue }
            let inner = ns.substring(with: NSRange(location: tagEnd, length: closeRange.location - tagEnd))
            let text = visibleText(fromHTMLFragment: inner)
            if !text.isEmpty {
                segments.append(text.count > maxSegmentLength ? String(text.prefix(maxSegmentLength)) : text)
            }
            // 숨김 요소 내부는 이미 수집했으므로 그 뒤부터 계속
            searchFrom = closeRange.location + closeRange.length
        }
        return segments
    }

    /// 숨김 요소 전체 텍스트를 하나로 합친다(규칙 입력용).
    public static func hiddenText(inHTML html: String) -> String {
        hiddenTextSegments(inHTML: html).joined(separator: "\n")
    }

    static func isHiddenAttributes(_ attributes: String) -> Bool {
        let range = NSRange(location: 0, length: (attributes as NSString).length)
        return hiddenAttributeRegexes.contains { $0.firstMatch(in: attributes, options: [], range: range) != nil }
    }

    /// 태그 제거 → 기본 엔티티 해제 → 공백 정리.
    static func visibleText(fromHTMLFragment fragment: String) -> String {
        var text = anyTagRegex.stringByReplacingMatches(in: fragment, options: [], range: NSRange(location: 0, length: (fragment as NSString).length), withTemplate: " ")
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&"),
        ]
        for (from, to) in entities { text = text.replacingOccurrences(of: from, with: to, options: [.caseInsensitive]) }
        text = whitespaceRegex.stringByReplacingMatches(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length), withTemplate: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 호환 자모 재조합

/// 호환 자모(U+3131–U+318E) 나열을 현대 한글 음절로 합친다. 초성+중성(+종성) 조합이 되는 곳만 합치고 나머지는 그대로 둔다.
enum HangulCompatJamo {
    static func isCompatibilityJamo(_ s: Unicode.Scalar) -> Bool { (0x3131...0x318E).contains(s.value) }

    /// 초성 인덱스(0–18)
    static let choseong: [UInt32: Int] = [
        0x3131: 0, 0x3132: 1, 0x3134: 2, 0x3137: 3, 0x3138: 4, 0x3139: 5, 0x3141: 6, 0x3142: 7, 0x3143: 8, 0x3145: 9,
        0x3146: 10, 0x3147: 11, 0x3148: 12, 0x3149: 13, 0x314A: 14, 0x314B: 15, 0x314C: 16, 0x314D: 17, 0x314E: 18,
    ]
    /// 종성 인덱스(1–27)
    static let jongseong: [UInt32: Int] = [
        0x3131: 1, 0x3132: 2, 0x3133: 3, 0x3134: 4, 0x3135: 5, 0x3136: 6, 0x3137: 7, 0x3139: 8, 0x313A: 9, 0x313B: 10,
        0x313C: 11, 0x313D: 12, 0x313E: 13, 0x313F: 14, 0x3140: 15, 0x3141: 16, 0x3142: 17, 0x3144: 18, 0x3145: 19,
        0x3146: 20, 0x3147: 21, 0x3148: 22, 0x314A: 23, 0x314B: 24, 0x314C: 25, 0x314D: 26, 0x314E: 27,
    ]
    /// 중성 인덱스(0–20): U+314F–U+3163 연속
    static func jungseong(_ s: Unicode.Scalar) -> Int? {
        (0x314F...0x3163).contains(s.value) ? Int(s.value - 0x314F) : nil
    }

    /// 반환: (재조합한 텍스트, 만든 음절 수)
    static func compose(_ text: String) -> (String, Int) {
        let s = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var count = 0
        var i = 0
        while i < s.count {
            if let l = choseong[s[i].value], i + 1 < s.count, let v = jungseong(s[i + 1]) {
                var t = 0
                var consumed = 2
                if i + 2 < s.count, let candidate = jongseong[s[i + 2].value] {
                    // 다음 글자가 모음이면 이 자음은 다음 음절의 초성이다 (ㄱㅏㄴㅏ → 가나)
                    let nextIsVowel = i + 3 < s.count && jungseong(s[i + 3]) != nil
                    if !nextIsVowel { t = candidate; consumed = 3 }
                }
                let code = 0xAC00 + (UInt32(l) * 21 + UInt32(v)) * 28 + UInt32(t)
                if let syllable = Unicode.Scalar(code) {
                    out.append(syllable)
                    count += 1
                    i += consumed
                    continue
                }
            }
            out.append(s[i])
            i += 1
        }
        return (String(out), count)
    }
}
