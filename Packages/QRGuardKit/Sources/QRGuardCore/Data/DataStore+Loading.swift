import Foundation
import os

private let logger = Logger(subsystem: "QRGuardCore", category: "DataStore")

extension DataStore {
    /// 번들에서 데이터 파일을 읽는다. 파일이 없거나 깨져 있으면 해당 항목만 비우고 로그를 남긴다.
    public static func load(from bundle: Bundle) -> DataStore {
        func decode<T: Decodable>(_ type: T.Type, _ name: String, fallback: T) -> T {
            guard let url = bundle.url(forResource: name, withExtension: "json") else {
                logger.error("데이터 파일 없음: \(name).json")
                return fallback
            }
            do {
                return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
            } catch {
                logger.error("데이터 파일 디코딩 실패: \(name).json — \(error.localizedDescription)")
                return fallback
            }
        }

        let brands = decode([BrandEntry].self, "brands", fallback: [])
        let shorteners = normalizeDomains(decode([String].self, "shorteners", fallback: []))
        let tlds = normalizeTLDs(decode([String].self, "suspicious_tlds", fallback: []))
        let schemes = decode([AppSchemeEntry].self, "app_schemes", fallback: [])
        let payment = normalizeDomains(decode([String].self, "payment_mobility", fallback: []))
        let blocklist = decode(Blocklist.self, "blocklist", fallback: .empty)
        let bait = decode([String].self, "bait_keywords", fallback: DataStore.defaultBaitKeywords)

        var psl: [String] = []
        if let url = bundle.url(forResource: "public_suffix_list", withExtension: "dat"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            psl = text.split(whereSeparator: \.isNewline).map { String($0) }
        } else {
            logger.error("public_suffix_list.dat 없음 — eTLD+1 계산이 2단계 폴백으로 동작합니다")
        }

        var confusables: [Character: String] = [:]
        if let url = bundle.url(forResource: "confusables_subset", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            confusables = parseConfusables(text)
        } else {
            logger.error("confusables_subset.txt 없음 — 유사 문자 탐지가 제한됩니다")
        }

        return DataStore(
            brands: brands,
            shorteners: shorteners,
            suspiciousTLDs: tlds,
            appSchemes: schemes,
            paymentMobilityDomains: payment,
            blocklist: blocklist,
            confusables: confusables,
            publicSuffixRules: psl,
            baitKeywords: bait
        )
    }

    /// 도메인 목록 정규화: 소문자, 앞뒤 공백·점 제거, 빈 항목 제외. 번들·원격 데이터에 같은 규칙을 적용한다.
    static func normalizeDomains(_ list: [String]) -> Set<String> {
        Set(list.compactMap { raw in
            let d = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return d.isEmpty ? nil : d
        })
    }

    /// TLD 목록 정규화: 소문자, 점 제거(".xyz" → "xyz").
    static func normalizeTLDs(_ list: [String]) -> Set<String> {
        normalizeDomains(list)
    }

    /// `confusables_subset.txt` 형식: UTS #39와 같은 `XXXX ; YYYY [YYYY…] ; MA # comment` (16진 코드포인트),
    /// 또는 간단한 `원문자 → 스켈레톤` 한 줄 형식(`а=a`). `#`으로 시작하는 줄은 주석.
    static func parseConfusables(_ text: String) -> [Character: String] {
        var map: [Character: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let body = trimmed.split(separator: "#", maxSplits: 1).first.map(String.init) ?? trimmed
            if body.contains(";") {
                let parts = body.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count >= 2,
                      let srcScalar = UInt32(parts[0], radix: 16),
                      let src = Unicode.Scalar(srcScalar) else { continue }
                let target = parts[1].split(separator: " ").compactMap { UInt32($0, radix: 16) }.compactMap(Unicode.Scalar.init)
                guard !target.isEmpty else { continue }
                map[Character(src)] = String(String.UnicodeScalarView(target))
            } else if body.contains("=") {
                let parts = body.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, let src = parts[0].first else { continue }
                map[src] = parts[1]
            }
        }
        return map
    }
}
