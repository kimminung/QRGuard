import Foundation
import SwiftData
import QRGuardCore

/// 스캔 기록 (TECH_PRD 5.5). 위험 요소·리다이렉트 홉은 `RiskReport` JSON 안에 함께 저장하고,
/// 검색·필터에 필요한 값만 컬럼으로 뺀다.
@Model
final class ScanRecord {
    @Attribute(.unique) var id: UUID
    var scannedAt: Date
    var rawPayload: String
    var payloadKind: String
    var originalURL: String?
    var finalURL: String?
    var registrableDomain: String?
    var score: Int
    var tier: String
    var source: String
    var place: String?
    /// 한 프레임에서 감지된 서로 다른 QR 수 (C01 재채점용)
    var distinctCodes: Int = 1
    var coverage: String
    var blocksOpening: Bool
    var userOpened: Bool
    /// 발동한 규칙 ID (검색용)
    var findingIDs: [String]
    /// `RiskReport` JSON
    var reportData: Data
    /// `AnalysisSnapshot` JSON — 장소 재채점·다시 보기용 (없을 수 있음)
    var snapshotData: Data?

    init(report: RiskReport, snapshot: AnalysisSnapshot?, context: AnalysisContext, id: UUID = UUID()) {
        let encoder = JSONEncoder()
        self.id = id
        scannedAt = report.analyzedAt
        rawPayload = report.rawPayload
        payloadKind = report.payloadKind.rawValue
        originalURL = report.originalURL?.absoluteString
        finalURL = report.finalURL?.absoluteString
        registrableDomain = report.domain?.registrableDomain
        score = report.score
        tier = report.tier.rawValue
        source = context.source.rawValue
        place = context.place?.rawValue
        distinctCodes = context.distinctCodesInFrame
        coverage = switch report.coverage {
        case .full: "full"
        case .offlineOnly: "offlineOnly"
        case .partial: "partial"
        }
        blocksOpening = report.blocksOpening
        userOpened = false
        findingIDs = report.findings.map(\.id.rawValue)
        reportData = (try? encoder.encode(report)) ?? Data()
        snapshotData = snapshot.flatMap { try? encoder.encode($0) }
    }

    var riskTier: RiskTier { RiskTier(rawValue: tier) ?? RiskTier(score: score) }
    var scanSource: ScanSource { ScanSource(rawValue: source) ?? .camera }
    var placeContext: PlaceContext? { place.flatMap(PlaceContext.init(rawValue:)) }

    func decodedReport() -> RiskReport? {
        try? JSONDecoder().decode(RiskReport.self, from: reportData)
    }

    func decodedSnapshot() -> AnalysisSnapshot? {
        guard let snapshotData else { return nil }
        return try? JSONDecoder().decode(AnalysisSnapshot.self, from: snapshotData)
    }

    /// 목록에 보여줄 짧은 이름: 등록 도메인 → 호스트 → 페이로드 종류.
    var displayName: String {
        if let registrableDomain, !registrableDomain.isEmpty { return registrableDomain }
        if let finalURL, let host = URL(string: finalURL)?.host() { return host }
        if let originalURL, let host = URL(string: originalURL)?.host() { return host }
        switch QRPayload.Kind(rawValue: payloadKind) ?? .text {
        case .wifi: return String(localized: "Wi-Fi 설정")
        case .phone: return String(localized: "전화번호")
        case .sms: return String(localized: "문자 메시지")
        case .email: return String(localized: "이메일")
        case .contact: return String(localized: "연락처")
        case .geo: return String(localized: "위치")
        case .payment: return String(localized: "송금·결제 정보")
        case .appScheme: return (URL(string: rawPayload)?.scheme).map { "\($0): 링크" } ?? String(localized: "앱 링크")
        default: return String(rawPayload.prefix(40))
        }
    }

    func updateReport(_ report: RiskReport, context: AnalysisContext) {
        score = report.score
        tier = report.tier.rawValue
        place = context.place?.rawValue
        findingIDs = report.findings.map(\.id.rawValue)
        reportData = (try? JSONEncoder().encode(report)) ?? reportData
    }
}

/// 기록 저장·조회·삭제·보관 기간 정리.
@MainActor
final class HistoryStore {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// "저장 안 함"이면 디스크에 쓰지 않고 nil을 돌려준다.
    @discardableResult
    func save(report: RiskReport, snapshot: AnalysisSnapshot?, context analysisContext: AnalysisContext, retention: AppSettings.Retention, id: UUID = UUID()) -> ScanRecord? {
        guard retention != .none else { return nil }
        if let existing = record(id: id) { return existing }
        let record = ScanRecord(report: report, snapshot: snapshot, context: analysisContext, id: id)
        context.insert(record)
        try? context.save()
        return record
    }

    func record(id: UUID) -> ScanRecord? {
        let predicate = #Predicate<ScanRecord> { $0.id == id }
        var descriptor = FetchDescriptor(predicate: predicate)
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func markOpened(id: UUID) {
        guard let record = record(id: id) else { return }
        record.userOpened = true
        try? context.save()
    }

    func delete(_ record: ScanRecord) {
        context.delete(record)
        try? context.save()
    }

    func deleteAll() {
        try? context.delete(model: ScanRecord.self)
        try? context.save()
    }

    /// 앱 시작 시 만료 레코드 삭제.
    func purgeExpired(retention: AppSettings.Retention, now: Date = .now) {
        switch retention {
        case .forever: return
        case .none:
            deleteAll()
        case .days7, .days30:
            guard let cutoff = Calendar.current.date(byAdding: .day, value: -retention.rawValue, to: now) else { return }
            let predicate = #Predicate<ScanRecord> { $0.scannedAt < cutoff }
            try? context.delete(model: ScanRecord.self, where: predicate)
            try? context.save()
        }
    }

    /// 최근 N일 안에 위험 등급 코드를 실제로 연 기록이 있으면 피해 대응 가이드 배너를 띄운다.
    func hasRecentDangerOpened(withinDays days: Int = 7, now: Date = .now) -> Bool {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) else { return false }
        let dangerRaw = RiskTier.danger.rawValue
        let predicate = #Predicate<ScanRecord> { $0.userOpened && $0.tier == dangerRaw && $0.scannedAt >= cutoff }
        var descriptor = FetchDescriptor(predicate: predicate)
        descriptor.fetchLimit = 1
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }
}
