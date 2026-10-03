import Foundation

/// 모든 규칙의 목록. 규칙은 파일 하나에 하나(`Rules/<ID>_<Name>.swift`). 순서: P → U → B → R → T → D → H → C.
///
/// TODO(release): `brands.json`·`payment_mobility.json`의 공식 도메인과 `shorteners.json`·`suspicious_tlds.json`은
/// 출시 전 각 기관 공식 안내로 재검증한다(TECH_PRD 10장 체크리스트).
public enum RuleCatalog {
    public static var allRules: [any RiskRule] {
        [
            // P — 페이로드
            DangerousSchemeRule(), EnterpriseInstallRule(), ConfigProfileRule(), InstallerDownloadRule(),
            UnknownAppSchemeRule(), KnownAppSchemeRule(), OpenWiFiRule(), SMSWithLinkRule(),
            PremiumRateNumberRule(), PaymentPayloadRule(), TextWithLinkRule(),
            // U — URL 구조
            InsecureHTTPRule(), IPAddressHostRule(), UserInfoAtRule(), NonStandardPortRule(), MixedScriptIDNRule(),
            DeepSubdomainRule(), ObfuscatedURLRule(), SuspiciousTLDRule(), OpenRedirectParamRule(),
            BaitKeywordRule(), URLShortenerRule(),
            // B — 브랜드 사칭
            BrandKeywordMismatchRule(), LookalikeDomainRule(), OfficialDomainRule(),
            // R — 리다이렉트
            ManyRedirectsRule(), DestinationMismatchRule(), HTTPSDowngradeRule(), UnresolvedShortenerRule(), MetaRefreshRule(),
            // T — 평판
            ThreatListHitRule(),
            // D — 도메인 정보
            VeryNewDomainRule(), RecentDomainRule(), DomainAgeUnavailableRule(),
            // H — 페이지 사전 검사
            PasswordInputRule(), CrossSiteFormRule(), BrandLookalikePageRule(), TLSFailureRule(),
            // C — 스캔 상황
            MultipleCodesRule(), MessageDemandsActionRule(), UnknownPaymentDomainRule(),
        ]
    }

    /// 오프라인 단계 규칙만.
    public static var offlineRules: [any RiskRule] { allRules.filter { $0.stage == .offline } }
    /// 온라인 단계 규칙만.
    public static var onlineRules: [any RiskRule] { allRules.filter { $0.stage == .online } }

    public static func rule(for id: RuleID) -> (any RiskRule)? { allRules.first { $0.id == id } }
}
