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

/// 보안 데이터 상태 (설정 화면 표시용).
struct SecurityDataStatus: Equatable {
    var sourceDescription: String = DataStore.bundledSourceDescription
    var appliedSequence: Int?
    var updatedAt: Date?
    var lastCheckedAt: Date?
    var isChecking = false
    var lastMessage: String?
    var isConfigured = false
}

/// 앱 전역 상태: 설정, 파이프라인, 경로, 분석 세션, 기록 저장소, 보안 데이터 갱신.
@Observable
final class AppModel {
    let settings: AppSettings
    let history: HistoryStore
    private(set) var pipeline: AnalysisPipeline
    private(set) var engine: RiskEngine

    var path: [AppRoute] = []
    var showScanner = false
    var showPasteSheet = false
    var showOnboarding = false
    private(set) var sessions: [UUID: AnalysisSession] = [:]
    /// 홈 상단 피해 대응 배너
    var showIncidentBanner = false
    private(set) var securityData = SecurityDataStatus()

    /// Safe Browsing 키가 Info.plist에 주입됐는지 (설정 화면 안내용)
    let hasSafeBrowsingKey: Bool
    private let safeBrowsingAPIKey: String?
    private let securityUpdater: SecurityDataUpdater?

    init(settings: AppSettings, history: HistoryStore) {
        self.settings = settings
        self.history = history
        let key = (Bundle.main.object(forInfoDictionaryKey: "SafeBrowsingAPIKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = (key?.isEmpty == false && key?.hasPrefix("$(") == false) ? key : nil
        hasSafeBrowsingKey = apiKey != nil
        safeBrowsingAPIKey = apiKey

        // 검증된 원격 보안 데이터가 캐시에 있으면 번들 데이터 위에 덮어쓴다(서명 재검증, 실패 시 번들).
        let data = DataStore.loadApplyingCachedUpdate()
        let initialEngine = RiskEngine(data: data)
        engine = initialEngine
        pipeline = AnalysisPipeline.live(safeBrowsingAPIKey: apiKey, engine: initialEngine)
        securityUpdater = SecurityDataConfiguration.makeUpdater(bundle: .main)
        securityData = SecurityDataStatus(
            sourceDescription: data.sourceDescription,
            appliedSequence: data.remoteSequence,
            updatedAt: data.updatedAt,
            isConfigured: securityUpdater != nil
        )

        showOnboarding = !settings.hasOnboarded
        history.purgeExpired(retention: settings.retention)
        showIncidentBanner = history.hasRecentDangerOpened()
        importSharedInbox()
        Task { [weak self] in
            await self?.loadSecurityState()
            if settings.securityAutoUpdate {
                await self?.refreshSecurityData(force: false)
            }
        }
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
        startAnalysis(ScanInput(raw: session.input.raw, source: session.input.source, distinctCodes: session.input.distinctCodes, vision: session.snapshot?.vision))
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

    // MARK: - 딥링크 (위젯 · 제어 센터 · 공유 확장)

    /// `qrguard://scan`, `qrguard://analyze?inbox=…`, `qrguard://analyze?p=…`
    func handleDeepLink(_ url: URL) {
        guard let route = QRGuardLinks.route(for: url) else { return }
        showOnboarding = false
        showPasteSheet = false
        switch route {
        case .scan:
            path.removeAll()
            showScanner = true
        case .inbox(let id):
            showScanner = false
            let imported = importSharedInbox()
            if let record = imported.first(where: { $0.0 == id })?.1 ?? history.record(id: id) {
                path.removeAll()
                openRecord(record)
            }
        case .analyze(let payload, let source):
            showScanner = false
            path.removeAll()
            startAnalysis(ScanInput(raw: payload, source: source))
        }
    }

    /// 공유 확장이 App Group 받은편지함에 남긴 결과를 기록으로 옮긴다. (받은편지함 항목 ID, 저장된 기록) 쌍을 돌려준다.
    /// - Parameter openRecent: 방금(2분 안에) 공유된 항목이 있으면 그 결과 화면을 바로 연다(포그라운드 복귀 시).
    @discardableResult
    func importSharedInbox(openRecent: Bool = false) -> [(UUID, ScanRecord)] {
        guard let inbox = SharedInbox() else { return [] }
        var imported: [(UUID, ScanRecord)] = []
        var latest: (Date, ScanRecord)?
        for item in inbox.drain() {
            if let record = history.save(report: item.report, snapshot: item.snapshot, context: item.context, retention: settings.retention, id: item.id) {
                imported.append((item.id, record))
                if latest == nil || item.createdAt > latest!.0 { latest = (item.createdAt, record) }
            }
        }
        if !imported.isEmpty {
            showIncidentBanner = history.hasRecentDangerOpened()
        }
        if openRecent, let latest, Date.now.timeIntervalSince(latest.0) < 120 {
            showScanner = false
            path.removeAll()
            openRecord(latest.1)
        }
        return imported
    }

    // MARK: - 보안 데이터 원격 업데이트 (T-6.3)

    private func loadSecurityState() async {
        guard let securityUpdater else { return }
        let state = await securityUpdater.currentState()
        securityData.lastCheckedAt = state.lastCheckedAt
        if securityData.appliedSequence == nil { securityData.appliedSequence = state.appliedSequence }
    }

    /// 서명 검증을 통과한 데이터만 적용하고, 적용되면 엔진·파이프라인을 다시 만든다.
    func refreshSecurityData(force: Bool) async {
        guard let securityUpdater, !securityData.isChecking else { return }
        securityData.isChecking = true
        defer { securityData.isChecking = false }
        let outcome = await securityUpdater.updateIfNeeded(minimumInterval: force ? .zero : .seconds(86_400))
        let state = await securityUpdater.currentState()
        securityData.lastCheckedAt = state.lastCheckedAt ?? securityData.lastCheckedAt
        switch outcome {
        case .applied(let sequence):
            let data = DataStore.loadApplyingCachedUpdate()
            engine = RiskEngine(data: data)
            pipeline = AnalysisPipeline.live(safeBrowsingAPIKey: safeBrowsingAPIKey, engine: engine)
            securityData.sourceDescription = data.sourceDescription
            securityData.appliedSequence = sequence
            securityData.updatedAt = data.updatedAt
            securityData.lastMessage = String(localized: "새 보안 데이터(#\(sequence))를 적용했어요.")
        case .upToDate:
            securityData.lastMessage = String(localized: "이미 최신 데이터예요.")
        case .skippedRecently:
            securityData.lastMessage = nil
        case .rejected(let error):
            securityData.lastMessage = String(localized: "서명 검증에 실패해 적용하지 않았어요. (\(error.code))")
        case .failed:
            securityData.lastMessage = String(localized: "서버에 연결하지 못했어요. 앱에 포함된 데이터로 계속 검사해요.")
        }
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
        settings.securityAutoUpdate = false
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
