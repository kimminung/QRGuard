import Foundation
import os

private let logger = Logger(subsystem: "QRGuardCore", category: "DataStore.Overlay")

/// 검증된 원격 보안 데이터를 번들 데이터 위에 덮어쓰기 (TASKS T-6.3).
///
/// 이 확장은 **검증을 하지 않는다**. `SecurityDataBundle`은 반드시 `SecurityDataVerifier`를 통과한 것이어야 하며,
/// 디스크 캐시에서 읽을 때는 `loadApplyingCachedUpdate`가 서명을 다시 확인한다.
extension DataStore {
    /// 묶음에 들어 있는 항목만 교체한 새 `DataStore`. 없는 항목(nil)은 그대로 둔다.
    /// `confusables`·`publicSuffixRules`는 원격 갱신 대상이 아니므로 항상 유지된다.
    public func applying(_ overlay: SecurityDataBundle) -> DataStore {
        var copy = self
        if let brands = overlay.brands { copy.brands = brands }
        if let shorteners = overlay.shorteners { copy.shorteners = Self.normalizeDomains(shorteners) }
        if let tlds = overlay.suspiciousTLDs { copy.suspiciousTLDs = Self.normalizeTLDs(tlds) }
        if let schemes = overlay.appSchemes { copy.appSchemes = schemes }
        if let payment = overlay.paymentMobility { copy.paymentMobilityDomains = Self.normalizeDomains(payment) }
        if let blocklist = overlay.blocklist { copy.blocklist = blocklist }
        if let bait = overlay.baitKeywords, !bait.isEmpty { copy.baitKeywords = bait }
        copy.sourceDescription = "remote #\(overlay.sequence) \(overlay.publishedAt)"
        copy.updatedAt = overlay.publishedDate
        copy.remoteSequence = overlay.sequence
        return copy
    }

    /// 번들에서 읽은 뒤 `overlay`가 있으면 덮어쓴다. nil이면 `load(from:)`과 같다.
    public static func load(from bundle: Bundle, overlay: SecurityDataBundle?) -> DataStore {
        let base = load(from: bundle)
        guard let overlay else { return base }
        return base.applying(overlay)
    }

    /// 캐시 디렉터리의 검증된 원격 데이터를 적용한 데이터. 앱 시작 시 `RiskEngine(data:)`에 넘길 값을 만든다.
    ///
    /// 캐시 파일(`security-data.json` + `.sig`)이 없거나, 서명·스키마가 맞지 않거나, 공개키 리소스가 없으면
    /// 번들 데이터를 돌려준다(절대 실패하지 않는다). 디스크의 파일은 신뢰하지 않고 **매번 서명을 다시 확인**한다.
    ///
    /// - Parameters:
    ///   - bundle: 번들 데이터 위치. nil이면 Core 리소스 번들(`DataStore.bundled`와 같은 원천).
    ///   - cacheDirectory: `SecurityDataUpdater`가 쓰는 디렉터리. 기본 `SecurityDataFiles.defaultCacheDirectory`.
    ///   - verifier: 검증기. 기본은 번들 공개키. nil(공개키 없음)이면 캐시를 무시한다.
    public static func loadApplyingCachedUpdate(
        bundle: Bundle? = nil,
        cacheDirectory: URL = SecurityDataFiles.defaultCacheDirectory,
        verifier: SecurityDataVerifier? = SecurityDataVerifier.bundled
    ) -> DataStore {
        let base = bundle.map(load(from:)) ?? .bundled
        guard let overlay = cachedBundle(in: cacheDirectory, verifier: verifier) else { return base }
        logger.info("원격 보안 데이터 적용: #\(overlay.sequence) \(overlay.publishedAt) [\(overlay.includedFields.joined(separator: ","))]")
        return base.applying(overlay)
    }

    /// 캐시 디렉터리의 데이터를 다시 검증해 돌려준다. 파일이 없거나 검증에 실패하면 nil(실패 사유는 로그).
    public static func cachedBundle(in cacheDirectory: URL, verifier: SecurityDataVerifier?) -> SecurityDataBundle? {
        guard let verifier else { return nil }
        let dataURL = SecurityDataFiles.dataURL(in: cacheDirectory)
        let sigURL = SecurityDataFiles.signatureURL(in: cacheDirectory)
        guard FileManager.default.fileExists(atPath: dataURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: dataURL)
            let signature = try String(contentsOf: sigURL, encoding: .utf8)
            return try verifier.verify(data: data, base64Signature: signature, appliedSequence: nil).bundle
        } catch {
            logger.error("캐시된 보안 데이터를 무시합니다(검증 실패): \(String(describing: error))")
            return nil
        }
    }
}
