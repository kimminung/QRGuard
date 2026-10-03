import Foundation

/// 스캔 입력 경로.
public enum ScanSource: String, Codable, Sendable, CaseIterable, Hashable {
    case camera, photo, paste, shareExtension
}

/// "어디서 찍었나요?" 선택지. 사용자가 고른 경우에만 C02·C03을 평가한다.
public enum PlaceContext: String, Codable, Sendable, CaseIterable, Hashable {
    case parkingOrPayment
    case mobility
    case emailOrMessage
    case storeOrMenu
    case other
}

/// 설정 화면의 검사 항목 토글 스냅샷 (TECH_PRD 6.1). 꺼진 검사는 어떤 요청도 보내지 않는다.
public struct AnalysisOptions: Codable, Sendable, Hashable {
    /// 실제 도착 주소 확인(리다이렉트 추적). 기본 켜짐.
    public var followRedirects: Bool
    /// 악성 사이트 조회(Google Safe Browsing 해시 프리픽스). 기본 켜짐.
    public var reputationLookup: Bool
    /// URLhaus 조회(URL 원문 전송). 기본 꺼짐.
    public var urlhausLookup: Bool
    /// 도메인 생성일 확인(RDAP). 기본 켜짐.
    public var domainAgeLookup: Bool
    /// 페이지 사전 검사(HTML 앞부분 256KB). 기본 꺼짐.
    public var pagePrecheck: Bool

    public init(
        followRedirects: Bool = true,
        reputationLookup: Bool = true,
        urlhausLookup: Bool = false,
        domainAgeLookup: Bool = true,
        pagePrecheck: Bool = false
    ) {
        self.followRedirects = followRedirects
        self.reputationLookup = reputationLookup
        self.urlhausLookup = urlhausLookup
        self.domainAgeLookup = domainAgeLookup
        self.pagePrecheck = pagePrecheck
    }

    public static let `default` = AnalysisOptions()
    /// 모든 온라인 검사 꺼짐 (오프라인 전용).
    public static let offline = AnalysisOptions(
        followRedirects: false, reputationLookup: false, urlhausLookup: false,
        domainAgeLookup: false, pagePrecheck: false
    )

    public var anyOnline: Bool {
        followRedirects || reputationLookup || urlhausLookup || domainAgeLookup || pagePrecheck
    }
}

/// 한 번의 분석에 대한 맥락.
public struct AnalysisContext: Codable, Sendable, Hashable {
    public var source: ScanSource
    /// 사용자가 "어디서 찍었나요?"를 고른 경우만.
    public var place: PlaceContext?
    /// 한 프레임/사진에서 감지된 서로 다른 QR 수 (C01).
    public var distinctCodesInFrame: Int
    public var options: AnalysisOptions

    public init(
        source: ScanSource,
        place: PlaceContext? = nil,
        distinctCodesInFrame: Int = 1,
        options: AnalysisOptions = .default
    ) {
        self.source = source
        self.place = place
        self.distinctCodesInFrame = distinctCodesInFrame
        self.options = options
    }
}
