import Foundation

/// 이미지·텍스트 디코딩 단계에서 결정적으로(AI 없이) 얻은 신호 (AI_ONDEVICE_DEFENSE.md 4.2, T-8.1).
///
/// 앱의 스캐너·공유 확장이 채워서 `AnalysisSnapshot.vision`에 넣는다. V 계열 규칙만 읽는다.
/// 값이 없으면(nil) V01–V03은 평가하지 않는다. 점수를 올릴 수만 있고 내리는 신호는 없다(불변식 1).
public struct VisionSignals: Codable, Sendable, Hashable {
    /// 단독 디코딩 실패 → 인접 이미지 결합 후 성공 (분할 QR, V01)
    public var decodedFromCombinedImages: Bool
    /// 다중 배율·크롭 디코딩에서 발견된 서로 다른 eTLD+1 (중첩 QR, V02). 1개 이하면 해당 없음
    public var nestedDistinctSites: [String]
    /// 문자·CSS로 그린 QR을 렌더링해 디코딩함 (ASCII QR, V03)
    public var decodedFromTextArt: Bool
    /// 파인더 패턴(모서리 사각형) 추정 수. 모르면 nil. 디코딩된 코드 수보다 훨씬 많으면 조각 존재 의심(V01)
    public var finderPatternCount: Int?
    /// 실제로 디코딩에 성공한 코드 수
    public var decodedCodeCount: Int

    public init(
        decodedFromCombinedImages: Bool = false,
        nestedDistinctSites: [String] = [],
        decodedFromTextArt: Bool = false,
        finderPatternCount: Int? = nil,
        decodedCodeCount: Int = 1
    ) {
        self.decodedFromCombinedImages = decodedFromCombinedImages
        self.nestedDistinctSites = nestedDistinctSites
        self.decodedFromTextArt = decodedFromTextArt
        self.finderPatternCount = finderPatternCount
        self.decodedCodeCount = decodedCodeCount
    }

    /// 아무 신호도 없는 기본값(카메라 단일 프레임에서 코드 1개를 그대로 읽은 경우와 같음).
    /// 이름을 `none`으로 두면 `VisionSignals?` 자리에서 `Optional.none`(nil)으로 해석되므로 피한다.
    public static let noSignals = VisionSignals()

    /// V 계열 규칙 중 하나라도 발동할 가능성이 있는지(UI에서 "비전 신호 있음" 표시용).
    public var hasAnySignal: Bool {
        decodedFromCombinedImages || decodedFromTextArt || nestedDistinctSites.count >= 2 || suspectsFragments
    }

    /// 파인더 패턴 수가 디코딩된 코드 수보다 2개 넘게 많으면 디코딩되지 않은 조각이 있다고 본다.
    public var suspectsFragments: Bool {
        guard let finders = finderPatternCount else { return false }
        return finders > decodedCodeCount + 2
    }

    // 옛 기록은 키가 없을 수 있으므로 모두 관대하게 읽는다.
    private enum CodingKeys: String, CodingKey {
        case decodedFromCombinedImages, nestedDistinctSites, decodedFromTextArt, finderPatternCount, decodedCodeCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        decodedFromCombinedImages = try c.decodeIfPresent(Bool.self, forKey: .decodedFromCombinedImages) ?? false
        nestedDistinctSites = try c.decodeIfPresent([String].self, forKey: .nestedDistinctSites) ?? []
        decodedFromTextArt = try c.decodeIfPresent(Bool.self, forKey: .decodedFromTextArt) ?? false
        finderPatternCount = try c.decodeIfPresent(Int.self, forKey: .finderPatternCount)
        decodedCodeCount = try c.decodeIfPresent(Int.self, forKey: .decodedCodeCount) ?? 1
    }
}
