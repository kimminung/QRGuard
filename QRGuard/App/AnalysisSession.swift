import Foundation
import Observation
import QRGuardCore
import QRGuardNetwork

/// 스캔 입력 1건.
struct ScanInput: Hashable, Sendable {
    var raw: String
    var source: ScanSource
    /// 한 프레임/사진에서 감지된 서로 다른 QR 수 (C01)
    var distinctCodes: Int = 1
    /// 입력 단계에서 계산한 비전 신호 (V 계열: 중첩·분할·문자 QR)
    var vision: VisionSignals? = nil
}

/// 한 번의 분석 세션. 분석 중 화면과 결과 화면이 공유한다.
@Observable
final class AnalysisSession: Identifiable {
    enum StepState: Equatable {
        case pending
        case running
        case finished(StepOutcome)
    }

    let id: UUID
    let input: ScanInput
    let options: AnalysisOptions
    let startedAt: Date
    private(set) var place: PlaceContext?

    private(set) var steps: [AnalysisStep: StepState]
    private(set) var preliminary: RiskReport?
    private(set) var report: RiskReport?
    private(set) var snapshot: AnalysisSnapshot?
    private(set) var isFinished = false
    private(set) var wasCancelled = false
    /// 기록에서 불러온 세션(스냅샷이 없으면 재채점 불가)
    let isRestored: Bool
    var recordID: UUID?
    var userOpened = false

    private var task: Task<Void, Never>?
    private let engine: RiskEngine

    var context: AnalysisContext {
        AnalysisContext(source: input.source, place: place, distinctCodesInFrame: input.distinctCodes, options: options)
    }

    init(input: ScanInput, options: AnalysisOptions, engine: RiskEngine) {
        self.id = UUID()
        self.input = input
        self.options = options
        self.engine = engine
        self.startedAt = .now
        self.isRestored = false
        self.steps = Dictionary(uniqueKeysWithValues: AnalysisStep.allCases.map { ($0, .pending) })
    }

    /// 기록에서 복원.
    init(record: ScanRecord, report: RiskReport, engine: RiskEngine) {
        self.id = UUID()
        self.input = ScanInput(raw: record.rawPayload, source: record.scanSource, distinctCodes: max(1, record.distinctCodes))
        self.options = .default
        self.engine = engine
        self.startedAt = record.scannedAt
        self.isRestored = true
        self.place = record.placeContext
        self.report = report
        self.snapshot = record.decodedSnapshot()
        self.recordID = record.id
        self.userOpened = record.userOpened
        self.isFinished = true
        self.steps = Dictionary(uniqueKeysWithValues: AnalysisStep.allCases.map { ($0, .finished(.passed)) })
    }

    func start(pipeline: AnalysisPipeline, onFinished: @escaping @MainActor (AnalysisSession) -> Void) {
        guard task == nil else { return }
        let stream = pipeline.analyze(input.raw, context: context, vision: input.vision)
        task = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { break }
                self.handle(event)
            }
            guard let self, !self.wasCancelled else { return }
            if !self.isFinished {
                // 스트림이 결과 없이 끝난 경우(비정상) — 오프라인 결과로라도 결과 화면에 도달한다.
                let snapshot = self.engine.offlineSnapshot(for: self.input.raw)
                self.snapshot = snapshot
                self.report = self.engine.report(snapshot: snapshot, context: self.context)
                self.isFinished = true
            }
            onFinished(self)
        }
    }

    func cancel() {
        wasCancelled = true
        task?.cancel()
    }

    /// "어디서 찍었나요?" 선택 → 네트워크 재요청 없이 재채점.
    func setPlace(_ newPlace: PlaceContext?) {
        place = newPlace
        if let snapshot {
            report = engine.report(snapshot: snapshot, context: context)
        } else if preliminary != nil {
            preliminary = engine.report(snapshot: engine.offlineSnapshot(for: input.raw), context: context)
        }
    }

    private func handle(_ event: AnalysisEvent) {
        switch event {
        case .stepStarted(let step):
            steps[step] = .running
        case .stepFinished(let step, let outcome):
            steps[step] = .finished(outcome)
        case .preliminary(let report):
            preliminary = report
        case .finished(let report, let snapshot):
            self.snapshot = snapshot
            self.report = report
            isFinished = true
        }
    }

    // MARK: - 표시용

    var displayReport: RiskReport? { report ?? preliminary }

    /// 결과 화면에서 "열기" 대상. URL 계열이 아니면 tel/sms/mailto 등 원문 URL.
    var openTarget: URL? {
        if let url = report?.openTarget { return url }
        if let url = URL(string: input.raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           let scheme = url.scheme?.lowercased(),
           ["tel", "sms", "smsto", "mailto", "geo", "maps"].contains(scheme) {
            return url
        }
        return nil
    }

    var elapsed: TimeInterval { Date.now.timeIntervalSince(startedAt) }
}
