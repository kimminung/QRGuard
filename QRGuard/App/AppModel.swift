import SwiftUI
import SwiftData
import QRGuardCore
import QRGuardNetwork

/// 내비게이션 경로 (TECH_PRD 7.2).
enum AppRoute: Hashable {
    case analysis(UUID)
    case result(UUID)
    case detail(UUID)
    case history
    case settings
    case incidentGuide
    case licenses
    case privacyPolicy
    case about
}

/// 앱 전역 상태: 설정, 파이프라인, 경로, 분석 세션, 기록 저장소.
@Observable
final class AppModel {
    let settings: AppSettings
    let history: HistoryStore
    let pipeline: AnalysisPipeline
    let engine: RiskEngine

    var path: [AppRoute] = []
    var showScanner = false
    var showPasteSheet = false
    var showOnboarding = false
    private(set) var sessions: [UUID: AnalysisSession] = [:]
    /// 홈 상단 피해 대응 배너
    var showIncidentBanner = false

    /// Safe Browsing 키가 Info.plist에 주입됐는지 (설정 화면 안내용)
    let hasSafeBrowsingKey: Bool

    init(settings: AppSettings, history: HistoryStore) {
        self.settings = settings
        self.history = history
        let key = (Bundle.main.object(forInfoDictionaryKey: "SafeBrowsingAPIKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = (key?.isEmpty == false && key?.hasPrefix("$(") == false) ? key : nil
        hasSafeBrowsingKey = apiKey != nil
        engine = RiskEngine()
        pipeline = AnalysisPipeline.live(safeBrowsingAPIKey: apiKey, engine: engine)
        showOnboarding = !settings.hasOnboarded
        history.purgeExpired(retention: settings.retention)
        showIncidentBanner = history.hasRecentDangerOpened()
    }

    func session(_ id: UUID) -> AnalysisSession? { sessions[id] }

    /// 분석을 시작하고 분석 중 화면으로 이동한다.
    @discardableResult
    func startAnalysis(_ input: ScanInput) -> AnalysisSession {
        let session = AnalysisSession(input: input, options: settings.analysisOptions, engine: engine)
        sessions[session.id] = session
        session.start(pipeline: pipeline) { [weak self] finished in
            self?.persist(finished)
        }
        path.append(.analysis(session.id))
        return session
    }

    /// 분석 중 화면 → 결과 화면으로 교체(뒤로 가면 홈).
    func showResult(for session: AnalysisSession) {
        if case .analysis(let id)? = path.last, id == session.id {
            path.removeLast()
        }
        path.append(.result(session.id))
    }

    /// 기록 행 → 저장된 보고서로 결과 화면.
    func openRecord(_ record: ScanRecord) {
        guard let report = record.decodedReport() else { return }
        let session = AnalysisSession(record: record, report: report, engine: engine)
        sessions[session.id] = session
        path.append(.result(session.id))
    }

    /// 기록에서 "다시 검사".
    func reanalyze(_ session: AnalysisSession) {
        startAnalysis(ScanInput(raw: session.input.raw, source: session.input.source, distinctCodes: session.input.distinctCodes))
    }

    func markOpened(_ session: AnalysisSession) {
        session.userOpened = true
        if let recordID = session.recordID {
            history.markOpened(id: recordID)
        }
        if session.report?.tier == .danger {
            showIncidentBanner = true
        }
    }

    func goHome() {
        path.removeAll()
    }

    func scanAnother() {
        path.removeAll()
        showScanner = true
    }

    func completeOnboarding() {
        settings.hasOnboarded = true
        showOnboarding = false
    }

    private func persist(_ session: AnalysisSession) {
        guard let report = session.report, session.recordID == nil else { return }
        if let record = history.save(report: report, snapshot: session.snapshot, context: session.context, retention: settings.retention) {
            session.recordID = record.id
        }
    }

    /// 장소 칩 변경이 저장된 기록에도 반영되도록.
    func placeChanged(_ session: AnalysisSession) {
        guard let recordID = session.recordID, let report = session.report,
              let record = history.record(id: recordID) else { return }
        record.updateReport(report, context: session.context)
        try? history.context.save()
    }

    /// 데모·UI 테스트: `-UITestPayload <문자열>` 런치 인자로 분석 화면에 바로 진입.
    func handleLaunchArguments(_ arguments: [String] = CommandLine.arguments) {
        guard let index = arguments.firstIndex(of: "-UITestPayload"), arguments.count > index + 1 else { return }
        showOnboarding = false
        startAnalysis(ScanInput(raw: arguments[index + 1], source: .paste))
    }
}

/// 미리보기용 인메모리 컨테이너.
enum PreviewSupport {
    static let container: ModelContainer = {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try! ModelContainer(for: ScanRecord.self, configurations: config)
    }()

    static func appModel() -> AppModel {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "preview")!)
        settings.hasOnboarded = true
        return AppModel(settings: settings, history: HistoryStore(context: container.mainContext))
    }

    static func sampleReport(score: Int, raw: String = "https://event-gift.example.test/coupon", findings: [RiskFinding] = []) -> RiskReport {
        let url = URL(string: raw)
        return RiskReport(
            score: score,
            tier: RiskTier(score: score),
            blocksOpening: false,
            findings: findings,
            passedChecks: [.U01, .U02, .U03, .U04, .U05, .U06, .U07, .U09, .U10],
            rawPayload: raw,
            payloadKind: .url,
            originalURL: url,
            finalURL: url,
            redirectChain: url.map { [RedirectHop(order: 0, url: $0, statusCode: 200)] } ?? [],
            domain: url?.host().map { DomainInfo(registrableDomain: $0, unicodeHost: $0) },
            coverage: .full
        )
    }
}
