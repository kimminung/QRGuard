import SwiftUI
import QRGuardCore

/// 분석 중 화면 (TASKS T-3.2). 단계 목록은 파이프라인 이벤트로만 갱신한다.
struct AnalysisView: View {
    @Bindable var session: AnalysisSession
    @Environment(AppModel.self) private var app
    @State private var minimumElapsed = false
    @State private var moved = false

    private let steps: [AnalysisStep] = [.structure, .redirect, .domainAge, .reputation, .pagePrecheck]

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                progressHeader
                stepList
                placeChips
            }
            .padding(Spacing.l)
        }
        .background(Palette.surface.ignoresSafeArea())
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("취소") {
                    session.cancel()
                    app.goHome()
                }
            }
        }
        .task {
            // 0.6초 미만으로 끝나도 화면 깜빡임을 막기 위해 최소 표시 시간을 둔다.
            try? await Task.sleep(for: .milliseconds(600))
            minimumElapsed = true
            proceedIfReady()
        }
        .onChange(of: session.isFinished) { _, _ in proceedIfReady() }
    }

    private func proceedIfReady() {
        guard !moved, minimumElapsed, session.isFinished, !session.wasCancelled else { return }
        moved = true
        if let tier = session.report?.tier {
            Feedback.notify(tier.haptic, settings: app.settings)
            Feedback.resultSound(for: tier, settings: app.settings)
        }
        app.showResult(for: session)
    }

    // MARK: - 헤더

    private var progressHeader: some View {
        VStack(spacing: Spacing.l) {
            ZStack {
                Circle()
                    .stroke(Palette.brand.opacity(0.15), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: progressFraction)
                    .stroke(Palette.brand, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.35), value: progressFraction)
                BrandMark(size: 40)
            }
            .frame(width: 112, height: 112)
            .accessibilityHidden(true)
            VStack(spacing: Spacing.xs) {
                Text("위험 요소를 살펴보는 중")
                    .font(.title2.bold())
                    .foregroundStyle(Palette.ink)
                Text("아직 사이트에 접속하지 않았어요.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
        .padding(.top, Spacing.l)
    }

    private var progressFraction: CGFloat {
        let active = steps.filter { step in
            if case .finished(.skipped) = session.steps[step] { return false }
            return true
        }
        guard !active.isEmpty else { return 1 }
        let done = active.filter { if case .finished = session.steps[$0] { return true } else { return false } }.count
        return CGFloat(done) / CGFloat(active.count)
    }

    // MARK: - 단계 목록

    private var stepList: some View {
        VStack(spacing: 0) {
            ForEach(Array(visibleSteps.enumerated()), id: \.element) { index, step in
                StepRow(step: step, state: session.steps[step] ?? .pending, report: session.displayReport)
                if index < visibleSteps.count - 1 {
                    Divider().overlay(Palette.line).padding(.leading, 44)
                }
            }
        }
        .card(padding: Spacing.xs)
    }

    /// 꺼둔 검사(페이지 미리 검사 등)는 목록에서 뺀다.
    private var visibleSteps: [AnalysisStep] {
        steps.filter { step in
            switch step {
            case .structure: return true
            case .redirect: return session.options.followRedirects
            case .domainAge: return session.options.domainAgeLookup
            case .reputation: return session.options.reputationLookup || session.options.urlhausLookup
            case .pagePrecheck: return session.options.pagePrecheck
            }
        }
    }

    // MARK: - 장소 칩

    private var placeChips: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text("어디서 찍은 QR인가요?")
                    .font(.headline)
                    .foregroundStyle(Palette.ink)
                Text("선택")
                    .font(.caption)
                    .foregroundStyle(Palette.inkSecondary)
            }
            PlaceChipGrid(selection: session.place) { place in
                session.setPlace(session.place == place ? nil : place)
            }
            Text("알려 주시면 상황에 맞춰 더 정확하게 판단해요.\n정상적인 기관은 메일·문자로 QR 인증을 요구하지 않아요.")
                .font(.caption)
                .foregroundStyle(Palette.inkSecondary)
        }
    }
}

/// 장소 선택 칩. 결과 화면에서도 재사용한다.
struct PlaceChipGrid: View {
    let selection: PlaceContext?
    let onSelect: (PlaceContext) -> Void

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: Spacing.s, alignment: .leading)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.s) {
            ForEach(PlaceContext.allCases, id: \.self) { place in
                let selected = selection == place
                Button { onSelect(place) } label: {
                    Text(place.title)
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.white : Palette.ink)
                        .padding(.horizontal, Spacing.m)
                        .padding(.vertical, Spacing.s)
                        .frame(maxWidth: .infinity)
                        .background(selected ? Palette.ink : Palette.card, in: Capsule())
                        .overlay(Capsule().strokeBorder(selected ? .clear : Palette.line))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

private struct StepRow: View {
    let step: AnalysisStep
    let state: AnalysisSession.StepState
    let report: RiskReport?

    var body: some View {
        HStack(spacing: Spacing.m) {
            icon
                .frame(width: 28, height: 28)
            Text(step.title)
                .font(.subheadline)
                .foregroundStyle(isPending ? Palette.inkSecondary : Palette.ink)
            Spacer()
            Text(trailingText)
                .font(.caption)
                .foregroundStyle(trailingColor)
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.m)
        .accessibilityElement(children: .combine)
    }

    private var isPending: Bool { if case .pending = state { return true } else { return false } }

    @ViewBuilder private var icon: some View {
        switch state {
        case .pending:
            Circle().strokeBorder(Palette.line, lineWidth: 2)
        case .running:
            ProgressView().controlSize(.small)
        case .finished(let outcome):
            switch outcome {
            case .passed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.brand)
            case .flagged:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.caution)
            case .skipped:
                Image(systemName: "minus.circle").foregroundStyle(Palette.inkSecondary)
            case .timedOut, .failed:
                Image(systemName: "clock.badge.exclamationmark").foregroundStyle(Palette.inkSecondary)
            }
        }
    }

    private var trailingText: String {
        switch state {
        case .pending: return ""
        case .running: return String(localized: "확인 중")
        case .finished(let outcome):
            switch outcome {
            case .passed: return String(localized: "통과")
            case .flagged(let n):
                switch step {
                case .redirect: return String(localized: "\(n)번 이동")
                case .domainAge: return String(localized: "최근 생성")
                default: return String(localized: "\(n)개 발견")
                }
            case .skipped: return String(localized: "건너뜀")
            case .timedOut: return String(localized: "시간 초과")
            case .failed: return String(localized: "확인 못 함")
            }
        }
    }

    private var trailingColor: Color {
        if case .finished(.flagged) = state { return Palette.caution }
        return Palette.inkSecondary
    }
}

#Preview {
    let app = PreviewSupport.appModel()
    let session = app.startAnalysis(ScanInput(raw: "https://bit.ly/3gH2kQ", source: .camera))
    return NavigationStack { AnalysisView(session: session) }.environment(app)
}
