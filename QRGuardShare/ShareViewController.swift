import UIKit
import SwiftUI
import UniformTypeIdentifiers
import Vision
import QRGuardCore
import QRGuardNetwork

/// 공유 확장 (TASKS T-6.1). 사진·URL·텍스트를 받아 `QRGuardKit`으로 분석하고 요약을 보여준다.
/// 스캔한 URL을 여기서 여는 일은 없다 — "QR Guard에서 열기"만 제공한다(CLAUDE.md 원칙).
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        model.onClose = { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
        model.onOpenApp = { [weak self] url in
            self?.openContainingApp(url)
        }
        let host = UIHostingController(rootView: ShareRootView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        model.start(with: extensionContext?.inputItems as? [NSExtensionItem] ?? [])
    }

    /// `UIApplication.openURL:` 셀렉터와 같은 이름의 더미 — 응답 체인에서 호스트 앱 객체를 찾아 URL을 연다.
    @objc private func openURL(_ url: URL) -> Bool { false }

    /// 1) `NSExtensionContext.open` → 2) 응답 체인의 `openURL:` 순으로 시도한다. 둘 다 막혀도 결과는 App Group 받은편지함에
    /// 이미 저장돼 있어, 앱을 열면 기록에서 바로 볼 수 있다(앱이 포그라운드로 올 때 받은편지함을 읽는다).
    private func openContainingApp(_ url: URL) {
        let fallback: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            let selector = #selector(self.openURL(_:))
            var responder: UIResponder? = self.next
            while let current = responder {
                if current.responds(to: selector), !(current is ShareViewController) {
                    _ = current.perform(selector, with: url)
                    break
                }
                responder = current.next
            }
        }
        if let context = extensionContext {
            context.open(url) { success in
                Task { @MainActor in
                    if !success { fallback() }
                }
            }
        } else {
            fallback()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }
}

// MARK: - 모델

@Observable
final class ShareModel {
    enum Phase: Equatable {
        case loading
        case analyzing
        case noContent(String)
        case finished(RiskReport, inboxID: UUID?)
    }

    private(set) var phase: Phase = .loading
    private(set) var steps: [AnalysisStep: StepOutcome?] = [:]
    private(set) var raw: String?
    var onClose: (() -> Void)?
    var onOpenApp: ((URL) -> Void)?

    func start(with items: [NSExtensionItem]) {
        Task { await load(items) }
    }

    func close() { onClose?() }

    func openInApp() {
        guard case .finished(_, let inboxID) = phase else { return }
        if let inboxID {
            onOpenApp?(QRGuardLinks.openInbox(inboxID))
        } else if let raw {
            onOpenApp?(QRGuardLinks.analyze(payload: raw, source: .shareExtension))
        }
    }

    private func load(_ items: [NSExtensionItem]) async {
        var images: [CGImage] = []
        var urlText: String?
        var plainText: String?

        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier), images.count < 4,
                   let data = await provider.loadData(for: UTType.image.identifier),
                   let image = UIImage(data: data)?.cgImage {
                    images.append(image)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier), urlText == nil,
                          let url = await provider.loadURL(for: UTType.url.identifier) {
                    urlText = url.absoluteString
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), plainText == nil,
                          let text = await provider.loadText(for: UTType.plainText.identifier) {
                    plainText = text
                }
            }
        }

        var payloads: [String] = []
        var vision = VisionSignals()
        if !images.isEmpty {
            let decoded = await ShareQRDecoder.decode(images)
            payloads = decoded.payloads
            vision = decoded.vision
            if payloads.isEmpty {
                phase = .noContent(String(localized: "이 이미지에서는 QR 코드를 찾지 못했어요. QR이 선명하게 보이는 이미지를 공유해 주세요."))
                return
            }
        } else if let urlText {
            payloads = [urlText]
        } else if let plainText, !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payloads = [plainText.trimmingCharacters(in: .whitespacesAndNewlines)]
        } else {
            phase = .noContent(String(localized: "분석할 이미지·링크·텍스트가 없어요."))
            return
        }

        guard let first = payloads.first else { return }
        raw = first
        await analyze(first, distinctCodes: payloads.count, vision: vision)
    }

    private func analyze(_ raw: String, distinctCodes: Int, vision: VisionSignals) async {
        phase = .analyzing
        let engine = RiskEngine(data: DataStore.loadApplyingCachedUpdate())
        let pipeline = AnalysisPipeline.live(safeBrowsingAPIKey: nil, engine: engine)
        let context = AnalysisContext(source: .shareExtension, distinctCodesInFrame: distinctCodes, options: .default)
        var finalReport: RiskReport?
        var finalSnapshot: AnalysisSnapshot?
        for await event in pipeline.analyze(raw, context: context, vision: vision) {
            switch event {
            case .stepStarted(let step): steps[step] = .some(nil)
            case .stepFinished(let step, let outcome): steps[step] = outcome
            case .preliminary: break
            case .finished(let report, let snapshot):
                finalReport = report
                finalSnapshot = snapshot
            }
        }
        let report = finalReport ?? engine.offlineReport(for: raw, context: context)
        var inboxID: UUID?
        if let inbox = SharedInbox() {
            let item = SharedInboxItem(raw: raw, context: context, report: report, snapshot: finalSnapshot)
            if (try? inbox.write(item)) != nil { inboxID = item.id }
        }
        phase = .finished(report, inboxID: inboxID)
    }
}

extension NSItemProvider {
    func loadData(for typeIdentifier: String) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    /// URL 항목. 클로저 안에서 Sendable 타입으로 바꾼 뒤 넘긴다(NSSecureCoding은 Sendable이 아님).
    func loadURL(for typeIdentifier: String) async -> URL? {
        await withCheckedContinuation { continuation in
            loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                continuation.resume(returning: url)
            }
        }
    }

    func loadText(for typeIdentifier: String) async -> String? {
        await withCheckedContinuation { continuation in
            loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                let text = (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
                continuation.resume(returning: text)
            }
        }
    }
}

// MARK: - 이미지 디코딩 (앱의 QRImageDecoder 축약판)

enum ShareQRDecoder {
    struct Decoded {
        var payloads: [String]
        var vision: VisionSignals
    }

    static func decode(_ images: [CGImage]) async -> Decoded {
        var ordered: [String] = []
        var seen = Set<String>()
        func collect(_ payloads: [String]) {
            for p in payloads where seen.insert(p).inserted { ordered.append(p) }
        }
        for image in images {
            collect((try? await payloads(in: image)) ?? [])
            for crop in crops(of: image) {
                collect((try? await payloads(in: crop)) ?? [])
            }
        }
        var combined = false
        if ordered.isEmpty, images.count >= 2 {
            // 분할 QR(V01): 두 장을 이어 붙여 다시 시도
            for (a, b) in [(images[0], images[1]), (images[1], images[0])] {
                for horizontal in [true, false] {
                    if let stitched = stitch(a, b, horizontal: horizontal),
                       let found = try? await payloads(in: stitched), !found.isEmpty {
                        collect(found)
                        combined = true
                        break
                    }
                }
                if combined { break }
            }
        }
        let sites = distinctSites(in: ordered)
        return Decoded(payloads: ordered, vision: VisionSignals(
            decodedFromCombinedImages: combined,
            nestedDistinctSites: sites.count >= 2 ? sites : [],
            decodedCodeCount: ordered.count
        ))
    }

    /// Vision 우선, 실패하거나 비어 있으면 Core Image `CIDetector`로 보완(시뮬레이터 호환).
    private static func payloads(in image: CGImage) async throws -> [String] {
        var request = DetectBarcodesRequest()
        request.symbologies = [.qr]
        var found: [String] = []
        if let observations = try? await request.perform(on: image) {
            found = observations.compactMap(\.payloadString).filter { !$0.isEmpty }
        }
        if found.isEmpty, let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) {
            found = detector.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.filter { !$0.isEmpty }
        }
        return found
    }

    private static func crops(of image: CGImage) -> [CGImage] {
        let w = image.width, h = image.height
        guard min(w, h) >= 128 else { return [] }
        return [
            CGRect(x: 0, y: 0, width: w / 2, height: h / 2),
            CGRect(x: w / 2, y: 0, width: w / 2, height: h / 2),
            CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2),
            CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2),
            CGRect(x: w / 4, y: h / 4, width: w / 2, height: h / 2),
        ].compactMap { image.cropping(to: $0) }
    }

    private static func stitch(_ a: CGImage, _ b: CGImage, horizontal: Bool) -> CGImage? {
        let w = horizontal ? a.width + b.width : max(a.width, b.width)
        let h = horizontal ? max(a.height, b.height) : a.height + b.height
        guard w <= 4096, h <= 4096,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if horizontal {
            ctx.draw(a, in: CGRect(x: 0, y: h - a.height, width: a.width, height: a.height))
            ctx.draw(b, in: CGRect(x: a.width, y: h - b.height, width: b.width, height: b.height))
        } else {
            ctx.draw(b, in: CGRect(x: 0, y: 0, width: b.width, height: b.height))
            ctx.draw(a, in: CGRect(x: 0, y: b.height, width: a.width, height: a.height))
        }
        return ctx.makeImage()
    }

    private static func distinctSites(in payloads: [String]) -> [String] {
        var sites: [String] = []
        for raw in payloads {
            guard let url = URL(string: raw), let normalized = URLNormalizer.normalize(url),
                  let site = normalized.registrableDomain ?? (normalized.host.isEmpty ? nil : normalized.host),
                  !sites.contains(site) else { continue }
            sites.append(site)
        }
        return sites
    }
}

// MARK: - 뷰

struct ShareRootView: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    switch model.phase {
                    case .loading:
                        ProgressView("내용을 읽는 중…")
                            .padding(.top, 40)
                    case .analyzing:
                        analyzing
                    case .noContent(let message):
                        VStack(spacing: 12) {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(message)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 40)
                    case .finished(let report, _):
                        summary(report)
                    }
                }
                .padding(20)
            }
            .navigationTitle("QR Guard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { model.close() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if case .finished = model.phase {
                    Button {
                        model.openInApp()
                    } label: {
                        Label("QR Guard에서 열기", systemImage: "arrow.up.forward.app")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(20)
                    .background(.bar)
                }
            }
        }
    }

    private var analyzing: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("위험 요소를 살펴보는 중")
                .font(.headline)
            Text("아직 사이트에 접속하지 않았어요.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach([AnalysisStep.structure, .redirect, .domainAge, .reputation], id: \.self) { step in
                    HStack {
                        Text(stepTitle(step))
                        Spacer()
                        Text(stepText(model.steps[step] ?? nil, started: model.steps[step] != nil))
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
            .padding(16)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(.top, 24)
    }

    private func summary(_ report: RiskReport) -> some View {
        let tier = TierStyle(report: report)
        return VStack(spacing: 20) {
            VStack(spacing: 10) {
                ZStack {
                    Circle().fill(tier.color.opacity(0.14))
                    Image(systemName: tier.symbol)
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(tier.color)
                }
                .frame(width: 84, height: 84)
                .accessibilityHidden(true)
                Text(tier.label)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tier.color)
                Text(tier.title)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)

            HStack(alignment: .firstTextBaseline) {
                Text("위험 점수")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(report.score)")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(tier.color)
                Text("/ 100").foregroundStyle(.secondary)
            }
            .padding(16)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("위험 점수 \(report.score)점, 100점 만점"))

            VStack(alignment: .leading, spacing: 6) {
                Text(report.hasRedirect ? "실제 도착 주소" : "주소")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text((report.finalURL ?? report.originalURL)?.absoluteString ?? report.rawPayload)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))

            if !report.topFindings.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(report.topFindings) { finding in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Circle().fill(tier.color).frame(width: 8, height: 8).accessibilityHidden(true)
                            Text(RuleText.title(for: finding))
                                .font(.subheadline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(finding.isDecisive ? String(localized: "확정") : "+\(finding.points)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(tier.color)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(16)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            } else {
                Text("검사 \(report.passedChecks.count)개 항목 모두 통과")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            }

            Text(report.coverage.isLimited
                 ? "확인 범위가 제한적이에요. 자세한 근거와 열기 여부는 QR Guard 앱에서 결정하세요."
                 : "자세한 근거와 열기 여부는 QR Guard 앱에서 결정하세요. 여기서는 주소를 열지 않아요.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func stepTitle(_ step: AnalysisStep) -> String {
        switch step {
        case .structure: String(localized: "주소 구조 분석")
        case .redirect: String(localized: "실제 도착 주소 확인")
        case .domainAge: String(localized: "도메인 생성일 확인")
        case .reputation: String(localized: "악성 사이트 조회")
        case .pagePrecheck: String(localized: "페이지 미리 검사")
        }
    }

    private func stepText(_ outcome: StepOutcome?, started: Bool) -> String {
        guard let outcome else { return started ? String(localized: "확인 중") : "" }
        switch outcome {
        case .passed: return String(localized: "통과")
        case .flagged(let n): return String(localized: "\(n)개 발견")
        case .skipped: return String(localized: "건너뜀")
        case .timedOut: return String(localized: "시간 초과")
        case .failed: return String(localized: "확인 못 함")
        }
    }
}

/// 등급 표현(앱 디자인 시스템의 축약판 — 확장은 앱 소스를 공유하지 않는다).
struct TierStyle {
    let color: Color
    let symbol: String
    let label: String
    let title: String

    init(report: RiskReport) {
        if report.blocksOpening {
            color = Color(red: 0.79, green: 0.16, blue: 0.11)
            symbol = "nosign"
            label = String(localized: "차단")
            title = String(localized: "이 코드는 열 수 없어요")
            return
        }
        switch report.tier {
        case .safe:
            color = Color(red: 0.05, green: 0.48, blue: 0.29)
            symbol = "checkmark.shield.fill"
            label = String(localized: "안전")
            title = String(localized: "알려진 위험 요소가 발견되지 않았어요")
        case .caution:
            color = Color(red: 0.60, green: 0.34, blue: 0.0)
            symbol = "exclamationmark.triangle.fill"
            label = String(localized: "주의")
            title = String(localized: "접속 전에 확인이 필요해요")
        case .danger:
            color = Color(red: 0.79, green: 0.16, blue: 0.11)
            symbol = "xmark.octagon.fill"
            label = String(localized: "위험")
            title = String(localized: "접속하지 않는 것을 권장해요")
        }
    }
}
