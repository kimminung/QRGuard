import Foundation

/// 치환된 값 뒤의 "은(는) · 이(가) · 을(를) · 와(과) · (으)로" 같은 병기 조사를 앞 글자의 받침 유무에 따라 하나로 고른다.
/// 한글은 종성으로, 숫자는 발음으로, 라틴 문자는 끝 자음의 발음 경향(m·n·l·k·p·t·b·d·g → 받침)으로 판단한다.
public enum KoreanParticle {
    enum Final { case absent, rieul, other }

    /// (받침 있을 때, 받침 없을 때) 쌍.
    private static let pairs: [(with: String, without: String)] = [
        ("은", "는"), ("이", "가"), ("을", "를"), ("과", "와"), ("으로", "로"),
    ]

    public static func resolve(in text: String) -> String {
        var result = text
        for pair in pairs {
            // 받침형(무받침형) · 무받침형(받침형)  예: 은(는), 와(과)
            result = replace(result, pattern: "\(pair.with)(\(pair.without))", pair: pair)
            result = replace(result, pattern: "\(pair.without)(\(pair.with))", pair: pair)
            // (으)로 꼴
            if pair.with.count > pair.without.count {
                let prefix = String(pair.with.dropLast(pair.without.count))
                result = replace(result, pattern: "(\(prefix))\(pair.without)", pair: pair)
            }
        }
        return result
    }

    private static func replace(_ text: String, pattern: String, pair: (with: String, without: String)) -> String {
        var output = text
        var searchRange = output.startIndex..<output.endIndex
        while let range = output.range(of: pattern, range: searchRange) {
            let before = output[..<range.lowerBound]
            guard let last = before.last(where: { !$0.isWhitespace && !")\"'”’".contains($0) }),
                  let final = finalConsonant(of: last) else {
                searchRange = range.upperBound..<output.endIndex
                continue
            }
            let replacement: String
            switch final {
            case .absent: replacement = pair.without
            case .rieul: replacement = pair.with == "으로" ? pair.without : pair.with   // ㄹ 받침 뒤에는 "로"
            case .other: replacement = pair.with
            }
            output.replaceSubrange(range, with: replacement)
            let newIndex = output.index(range.lowerBound, offsetBy: replacement.count)
            searchRange = newIndex..<output.endIndex
        }
        return output
    }

    /// 받침 종류. 판단 불가(기호 등)면 nil.
    static func finalConsonant(of character: Character) -> Final? {
        guard let scalar = character.unicodeScalars.first else { return nil }
        let value = scalar.value
        // 한글 음절: 종성 인덱스 0 = 없음, 8 = ㄹ
        if (0xAC00...0xD7A3).contains(value) {
            let jong = (value - 0xAC00) % 28
            return jong == 0 ? .absent : (jong == 8 ? .rieul : .other)
        }
        // 숫자: 영·일·이·삼·사·오·육·칠·팔·구
        if let digit = character.wholeNumberValue, (0...9).contains(digit) {
            switch digit {
            case 1, 7, 8: return .rieul
            case 0, 3, 6: return .other
            default: return .absent
            }
        }
        // 라틴 문자: 끝 자음 발음 경향
        if character.isLetter, character.isASCII {
            let lower = Character(character.lowercased())
            if lower == "l" { return .rieul }
            if "mnkptbdg".contains(lower) { return .other }
            if "aeiouyrwhcfsvxzjq".contains(lower) { return .absent }
        }
        return nil
    }

    /// 받침이 있으면 true, 없으면 false, 판단 불가면 nil.
    static func hasFinalConsonant(_ character: Character) -> Bool? {
        guard let final = finalConsonant(of: character) else { return nil }
        return final != .absent
    }
}
