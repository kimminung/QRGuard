import Foundation

// 규칙 구현이 공유하는 보조 도구. 규칙 자체는 파일 하나에 하나(`<ID>_<Name>.swift`).

extension RuleInput {
    /// 이 입력의 PSL 인덱스(번들 규칙이면 공유 인스턴스).
    var psl: PublicSuffixList { RegistrableDomain.list(for: data) }

    /// 체인 홉 등 임의 URL을 같은 데이터로 정규화한다.
    func normalize(_ url: URL) -> NormalizedURL? { URLNormalizer.normalize(url, data: data) }

    /// 스캔한 URL이 웹(http/https) URL인지.
    var hasWebURL: Bool { url?.isWeb ?? false }

    /// 최종 URL(없으면 스캔한 URL)의 eTLD+1. IP면 호스트 문자열.
    var finalSite: String? { finalURL.flatMap { $0.registrableDomain ?? ($0.host.isEmpty ? nil : $0.host) } }
    /// 스캔한 URL의 eTLD+1. IP면 호스트 문자열.
    var scannedSite: String? { url.flatMap { $0.registrableDomain ?? ($0.host.isEmpty ? nil : $0.host) } }

    /// 호스트의 eTLD+1(IP·빈 값이면 호스트 그대로).
    func site(ofHost host: String) -> String {
        let h = host.lowercased()
        return RegistrableDomain.from(host: h, psl: psl) ?? h
    }
}

// MARK: - 브랜드 매칭

/// 브랜드 키워드·공식 도메인 판별 (B01·B02·B03·H03 공용).
struct BrandMatcher: Sendable {
    let brands: [BrandEntry]

    init(_ data: DataStore) { brands = data.brands }

    /// eTLD+1이 공식 도메인인 브랜드들(여러 브랜드가 같은 도메인을 공유할 수 있음).
    func officialBrands(for registrableDomain: String?) -> [BrandEntry] {
        guard let rd = registrableDomain?.lowercased() else { return [] }
        return brands.filter { $0.isOfficial(registrableDomain: rd) }
    }

    func isOfficial(_ registrableDomain: String?) -> Bool {
        !officialBrands(for: registrableDomain).isEmpty
    }

    /// 두 eTLD+1이 같은 브랜드의 공식 도메인인지.
    func sameBrand(_ a: String?, _ b: String?) -> Bool {
        let ba = Set(officialBrands(for: a).map(\.brand))
        let bb = Set(officialBrands(for: b).map(\.brand))
        return !ba.isDisjoint(with: bb)
    }

    /// 텍스트 조각들(호스트 라벨·경로 구성요소)에서 브랜드 키워드를 찾는다. 반환: (브랜드, 키워드).
    /// 키워드가 5자 이상이면 부분 문자열, 그보다 짧으면 `-`·`_`·숫자 경계로 나눈 토큰 일치만 인정한다.
    func brandMentioned(in fragments: [String], allowSubstring: Bool = true) -> (BrandEntry, String)? {
        let lowered = fragments.map { $0.lowercased() }
        for brand in brands {
            for keyword in brand.keywords {
                let kw = keyword.lowercased()
                for fragment in lowered {
                    if fragment == kw { return (brand, kw) }
                    let tokens = fragment.split { !$0.isLetter && !$0.isNumber }.map(String.init)
                    if tokens.contains(kw) { return (brand, kw) }
                    if allowSubstring, kw.count >= 5, fragment.contains(kw) { return (brand, kw) }
                }
            }
        }
        return nil
    }

    /// 자유 텍스트(제목·본문)에서 브랜드 키워드 또는 브랜드 표시명을 찾는다.
    func brandMentioned(inText text: String) -> (BrandEntry, String)? {
        let lowered = text.lowercased()
        for brand in brands {
            // 한글 브랜드명 자체(괄호 안 설명 제외)
            let display = brand.brand.split(separator: "(").first.map(String.init) ?? brand.brand
            for name in display.split(separator: "·").map({ $0.trimmingCharacters(in: .whitespaces) }) where name.count >= 2 {
                if lowered.contains(name.lowercased()) { return (brand, name) }
            }
            for keyword in brand.keywords where keyword.count >= 4 {
                let kw = keyword.lowercased()
                if let range = lowered.range(of: kw) {
                    // 영문 단어 경계 확인(예: "meta" ⊄ "metadata")
                    let before = range.lowerBound == lowered.startIndex ? nil : lowered[lowered.index(before: range.lowerBound)]
                    let after = range.upperBound == lowered.endIndex ? nil : lowered[range.upperBound]
                    let boundary = !(before?.isLetter ?? false) && !(after?.isLetter ?? false)
                    if boundary || kw.count >= 6 { return (brand, kw) }
                }
            }
        }
        return nil
    }

    /// 공식 도메인의 등록 라벨(eTLD+1에서 공개 접미사를 뺀 부분). 예: "naver.com" → "naver", "lottecard.co.kr" → "lottecard".
    static func secondLevelLabel(of registrableDomain: String, psl: PublicSuffixList) -> String {
        let rd = registrableDomain.lowercased()
        if let suffix = psl.publicSuffix(forHost: rd), rd.hasSuffix("." + suffix) {
            return String(rd.dropLast(suffix.count + 1))
        }
        return rd.split(separator: ".").first.map(String.init) ?? rd
    }
}

// MARK: - 편집 거리

enum DamerauLevenshtein {
    /// 제한된(OSA) Damerau–Levenshtein 거리.
    static func distance(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var prev2 = [Int](repeating: 0, count: t.count + 1)
        var prev = Array(0...t.count)
        var curr = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            curr[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                curr[j] = Swift.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, s[i - 1] == t[j - 2], s[i - 2] == t[j - 1] {
                    curr[j] = Swift.min(curr[j], prev2[j - 2] + 1)
                }
            }
            (prev2, prev, curr) = (prev, curr, prev2)
        }
        return prev[t.count]
    }
}

// MARK: - 혼동 문자 스켈레톤

enum ConfusableSkeleton {
    /// 타이포스쿼팅에 흔한 숫자·조합 치환(UTS #39에 없는 보조 표).
    static let typoMap: [String: String] = ["0": "o", "1": "l", "5": "s", "3": "e", "rn": "m", "vv": "w", "cl": "d"]

    /// 소문자화 → confusables 매핑 → 보조 표 치환. 비교 양쪽에 같은 변환을 적용해야 한다.
    static func skeleton(of text: String, confusables: [Character: String]) -> String {
        var mapped = ""
        for ch in text.lowercased() {
            if let repl = confusables[ch] { mapped += repl.lowercased() } else { mapped.append(ch) }
        }
        // 합성 스켈레톤은 다중 문자 치환을 먼저 적용한다.
        for (from, to) in typoMap.sorted(by: { $0.key.count > $1.key.count }) {
            mapped = mapped.replacingOccurrences(of: from, with: to)
        }
        return mapped
    }
}

// MARK: - 전화번호

enum PhoneNumberHeuristics {
    /// 국내 유료 정보서비스 번호(060)인지. `+82-60-…`, `0082 60 …`, `060-123-4567` 모두 인식한다.
    static func isPremiumRate060(_ number: String) -> Bool {
        var digits = number.filter { $0.isNumber || $0 == "+" }
        if digits.hasPrefix("+82") { digits = "0" + digits.dropFirst(3) }
        else if digits.hasPrefix("0082") { digits = "0" + digits.dropFirst(4) }
        else if digits.hasPrefix("82"), digits.count >= 11 { digits = "0" + digits.dropFirst(2) }
        digits = digits.filter(\.isNumber)
        return digits.hasPrefix("060")
    }
}

// MARK: - 설치 파일 판별

enum InstallerFileHeuristics {
    static let extensions: Set<String> = ["apk", "ipa", "exe", "msi", "dmg", "pkg", "xapk", "apks", "bat", "cmd", "scr"]

    /// Content-Type → 대표 확장자. 모르면 nil.
    static func extensionForContentType(_ contentType: String?) -> String? {
        guard let ct = contentType?.lowercased() else { return nil }
        if ct.contains("application/vnd.android.package-archive") { return "apk" }
        if ct.contains("application/x-apple-diskimage") { return "dmg" }
        if ct.contains("application/x-msdownload") || ct.contains("application/x-ms-dos-executable") || ct.contains("application/x-dosexec") { return "exe" }
        if ct.contains("application/x-msi") || ct.contains("application/x-ms-installer") || ct.contains("application/x-windows-installer") { return "msi" }
        if ct.contains("application/x-newton-compatible-pkg") || ct.contains("application/x-xar") || ct.contains("application/vnd.apple.installer+xml") { return "pkg" }
        // application/octet-stream · application/zip 은 경로 확장자가 있을 때만(위 단계에서) 설치 파일로 본다.
        return nil
    }

    /// 이 입력이 설치 파일을 가리키면 확장자를 돌려준다(스캔 URL·최종 URL 경로, 응답 Content-Type 순).
    static func detectedExtension(in input: RuleInput) -> String? {
        for u in [input.finalURL, input.url].compactMap({ $0 }) {
            if let ext = u.pathExtension, extensions.contains(ext) { return ext }
        }
        let contentTypes = [input.chain?.finalContentType, input.page?.contentType].compactMap { $0 }
        for ct in contentTypes {
            if let ext = extensionForContentType(ct) { return ext }
        }
        return nil
    }
}
