import SwiftUI
import QRGuardCore

/// 상세 분석 (TASKS T-3.4): 위험 요소(펼침) / 통과한 검사(접힘) / 이동 경로 / 도메인 정보 / 확인 범위 / 원본 데이터.
struct DetailView: View {
    let report: RiskReport
    let session: AnalysisSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// 이동 경로 단계 번호 원 — 글자와 함께 커진다
    @ScaledMetric(relativeTo: .caption2) private var hopBadgeSize: CGFloat = 20

    @State private var expanded: Set<RuleID> = []
    @State private var showPassed = false
    @State private var copied = false

    private var isAX: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                header
                findingsSection
                passedSection
                if report.originalURL != nil {
                    redirectSection
                    domainSection
                }
                coverageSection
                rawSection
            }
            .padding(Spacing.l)
        }
        .background(Palette.surface.ignoresSafeArea())
        .navigationTitle("상세 분석")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if copied {
                Text("복사했어요")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, Spacing.l)
                    .padding(.vertical, Spacing.s)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, Spacing.xl)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - 헤더

    private var header: some View {
        let layout = isAX
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.m))
            : AnyLayout(HStackLayout(spacing: Spacing.m))
        return layout {
            HStack(spacing: Spacing.m) {
                Image(systemName: report.blocksOpening ? "nosign" : report.tier.symbol)
                    .font(.title3)
                    .foregroundStyle(report.tier.color)
                    .frame(width: 44, height: 44)
                    .background(report.tier.background, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.blocksOpening ? String(localized: "차단") : report.tier.label)
                        .font(.headline)
                        .foregroundStyle(report.tier.color)
                    Text("확인 범위: \(report.coverage.summaryText)")
                        .font(.caption)
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
            if !isAX { Spacer() }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(report.score)")
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(report.tier.color)
                Text("/ 100")
                    .font(.caption)
                    .foregroundStyle(Palette.inkSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("위험 점수 \(report.score)점, 100점 만점"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityElement(children: .combine)
    }

    // MARK: - 위험 요소

    private var findingsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader(title: String(localized: "발견된 위험 요소"), trailing: String(localized: "\(report.riskFindings.count)개"))
            if report.riskFindings.isEmpty {
                Text("알려진 위험 요소가 발견되지 않았어요. 그래도 접속 후 로그인·결제를 요구하면 다시 확인하세요.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(report.riskFindings.enumerated()), id: \.element.id) { index, finding in
                        findingDisclosure(finding)
                        if index < report.riskFindings.count - 1 {
                            Divider().overlay(Palette.line)
                        }
                    }
                }
                .card(padding: Spacing.xs)
            }
            if !report.positiveFindings.isEmpty {
                VStack(spacing: 0) {
                    ForEach(report.positiveFindings) { finding in
                        findingDisclosure(finding)
                    }
                }
                .card(padding: Spacing.xs)
            }
        }
    }

    private func findingDisclosure(_ finding: RiskFinding) -> some View {
        let isOpen = expanded.contains(finding.id)
        return VStack(alignment: .leading, spacing: Spacing.m) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    if isOpen { expanded.remove(finding.id) } else { expanded.insert(finding.id) }
                }
            } label: {
                HStack(spacing: Spacing.s) {
                    FindingRow(finding: finding)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.inkSecondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isOpen ? Text("펼침") : Text("접힘"))
            .accessibilityHint(isOpen ? "접기" : "이유와 권장 행동 보기")

            if isOpen {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    explanation(String(localized: "왜 위험한가요"), RuleText.detail(for: finding))
                    explanation(String(localized: "어떻게 할까요"), RuleText.advice(for: finding))
                    if !finding.sources.isEmpty {
                        Text("근거 · " + finding.sources.map { RuleText.organization($0) }.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(Palette.inkSecondary)
                    }
                    // 70% 불투명 inkSecondary는 Light 카드 위 3.1:1 → 불투명 그대로 사용 (5.9:1)
                    Text(finding.id.rawValue)
                        .font(.caption2.monospaced())
                        .foregroundStyle(Palette.inkSecondary)
                        .accessibilityLabel(Text("규칙 번호 \(finding.id.rawValue)"))
                }
                .padding(Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(Spacing.m)
    }

    private func explanation(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Palette.ink)
            Text(body).font(.footnote).foregroundStyle(Palette.inkSecondary)
        }
    }

    // MARK: - 통과한 검사

    private var passedSection: some View {
        DisclosureGroup(isExpanded: $showPassed) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                ForEach(report.passedChecks, id: \.self) { id in
                    HStack(spacing: Spacing.m) {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Palette.safe)
                            .accessibilityHidden(true)
                        Text(RuleText.passed(id))
                            .font(.footnote)
                            .foregroundStyle(Palette.ink)
                        Spacer()
                        Text(id.rawValue)
                            .font(.caption2.monospaced())
                            .foregroundStyle(Palette.inkSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, Spacing.s)
        } label: {
            SectionHeader(title: String(localized: "통과한 검사"), trailing: String(localized: "\(report.passedChecks.count)개"))
        }
        .tint(Palette.inkSecondary)
        .card()
    }

    // MARK: - 이동 경로

    private var redirectSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader(title: String(localized: "이동 경로"), trailing: String(localized: "\(report.redirectChain.count)단계"))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(report.redirectChain.enumerated()), id: \.element.id) { index, hop in
                    HStack(alignment: .top, spacing: Spacing.m) {
                        VStack(spacing: 0) {
                            // Dark에서 ink는 밝은색이라 흰 글자는 보이지 않는다 → onInk.
                            Text("\(index + 1)")
                                .font(.caption2.bold())
                                .foregroundStyle(index == report.redirectChain.count - 1 ? Palette.onInk : Palette.ink)
                                .frame(width: hopBadgeSize, height: hopBadgeSize)
                                .background(index == report.redirectChain.count - 1 ? Palette.ink : Palette.line, in: Circle())
                            if index < report.redirectChain.count - 1 {
                                Rectangle().fill(Palette.line).frame(width: 2).frame(minHeight: 20)
                            }
                        }
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hop.url.absoluteString)
                                .font(.footnote)
                                .foregroundStyle(Palette.ink)
                                .lineLimit(3)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Text(hopDescription(hop, index: index))
                                .font(.caption2)
                                .foregroundStyle(Palette.inkSecondary)
                        }
                        .padding(.bottom, Spacing.m)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(Text("\(index + 1)단계, \(hopDescription(hop, index: index)), \(hop.url.absoluteString)"))
                    }
                }
            }
            if let chain = session.snapshot?.chain, chain.outcome != .completed {
                Text(outcomeDescription(chain.outcome))
                    .font(.caption)
                    .foregroundStyle(Palette.caution)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func hopDescription(_ hop: RedirectHop, index: Int) -> String {
        var parts: [String] = []
        parts.append(index == 0 ? String(localized: "스캔한 주소") : (index == report.redirectChain.count - 1 ? String(localized: "실제 도착") : String(localized: "경유")))
        if hop.viaMetaRefresh { parts.append(String(localized: "페이지 자동 이동")) }
        if let status = hop.statusCode {
            parts.append((300..<400).contains(status) ? String(localized: "\(status) 이동") : "\(status)")
        } else if index > 0 || report.redirectChain.count == 1 {
            parts.append(String(localized: "요청 안 함"))
        }
        return parts.joined(separator: " · ")
    }

    private func outcomeDescription(_ outcome: RedirectChain.Outcome) -> String {
        switch outcome {
        case .completed: ""
        case .timedOut: String(localized: "응답이 늦어 끝까지 확인하지 못했어요.")
        case .tooManyHops: String(localized: "이동이 너무 많아 10번까지만 따라갔어요.")
        case .loopDetected: String(localized: "같은 주소를 반복해서 가리켜 중단했어요.")
        case .stoppedAtInsecureHop: String(localized: "암호화되지 않은(http) 구간부터는 접속하지 않았어요.")
        case .blockedPrivateAddress: String(localized: "내부 네트워크 주소를 가리켜 접속하지 않았어요.")
        case .tlsFailure: String(localized: "사이트 보안 인증서에 문제가 있어 중단했어요.")
        case .failed(let message): String(localized: "확인하지 못했어요: \(message)")
        }
    }

    // MARK: - 도메인 정보

    private var domainSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader(title: String(localized: "도메인 정보"))
            if let domain = report.domain {
                infoRow(String(localized: "등록 도메인"), domain.registrableDomain)
                if domain.unicodeHost != domain.registrableDomain {
                    infoRow(String(localized: "표시 호스트"), domain.unicodeHost)
                }
                if let puny = domain.punycodeHost {
                    infoRow(String(localized: "퓨니코드"), puny)
                }
                if let date = domain.registrationDate {
                    let days = domain.ageInDays() ?? 0
                    infoRow(String(localized: "생성일"), date.formatted(date: .long, time: .omitted) + String(localized: " (\(days)일 전)"))
                } else if domain.lookupFailed {
                    infoRow(String(localized: "생성일"), String(localized: "확인하지 못했어요"))
                } else {
                    infoRow(String(localized: "생성일"), String(localized: "조회하지 않음"))
                }
            } else {
                Text("도메인 정보를 확인할 수 없어요(IP 주소이거나 등록 도메인이 아님).")
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        let layout = isAX
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        return layout {
            Text(title).font(.footnote).foregroundStyle(Palette.inkSecondary)
            if !isAX { Spacer() }
            Text(value)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(isAX ? .leading : .trailing)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - 확인 범위

    private var coverageSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader(title: String(localized: "확인 범위"), trailing: report.coverage.summaryText)
            ForEach(CheckID.allCases, id: \.self) { check in
                let status = coverageStatus(check)
                let layout = isAX
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                    : AnyLayout(HStackLayout())
                layout {
                    Text(check.title).font(.footnote).foregroundStyle(Palette.ink)
                    if !isAX { Spacer() }
                    Label(status.0, systemImage: status.1)
                        .font(.caption)
                        .foregroundStyle(status.2)
                }
                .accessibilityElement(children: .combine)
            }
            Text("클로킹(검사 도구에게만 정상 페이지를 보여주는 수법)은 탐지에 한계가 있어요.")
                .font(.caption2)
                .foregroundStyle(Palette.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func coverageStatus(_ check: CheckID) -> (String, String, Color) {
        if check == .structure { return (String(localized: "완료"), "checkmark.circle.fill", Palette.safe) }
        let enabled: Bool = switch check {
        case .structure: true
        case .redirect: session.options.followRedirects
        case .domainAge: session.options.domainAgeLookup
        case .reputation: session.options.reputationLookup || session.options.urlhausLookup
        case .pagePrecheck: session.options.pagePrecheck
        }
        if report.originalURL == nil { return (String(localized: "해당 없음"), "minus.circle", Palette.inkSecondary) }
        if case .offlineOnly = report.coverage { return (String(localized: "꺼짐"), "minus.circle", Palette.inkSecondary) }
        if !enabled { return (String(localized: "꺼짐"), "minus.circle", Palette.inkSecondary) }
        if report.coverage.missingChecks.contains(check) { return (String(localized: "확인 못 함"), "exclamationmark.circle", Palette.caution) }
        return (String(localized: "완료"), "checkmark.circle.fill", Palette.safe)
    }

    // MARK: - 원본 데이터

    private var rawSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack {
                SectionHeader(title: String(localized: "원본 데이터"))
                Button {
                    UIPasteboard.general.string = report.rawPayload
                    let animation: Animation? = reduceMotion ? nil : .default
                    withAnimation(animation) { copied = true }
                    UIAccessibility.post(notification: .announcement, argument: String(localized: "복사했어요"))
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        withAnimation(animation) { copied = false }
                    }
                } label: {
                    Label("복사", systemImage: "doc.on.doc").font(.footnote)
                }
                .accessibilityLabel("원본 데이터 복사")
            }
            Text(report.rawPayload)
                .font(.footnote.monospaced())
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.m)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            Text("분석 시각 \(report.analyzedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(Palette.inkSecondary)
        }
        .card()
    }
}

#Preview {
    let app = PreviewSupport.appModel()
    let session = app.startAnalysis(ScanInput(raw: "https://naver-login.account-check.xyz/verify", source: .photo, distinctCodes: 2))
    return NavigationStack {
        if let report = session.report ?? session.preliminary {
            DetailView(report: report, session: session)
        } else {
            ProgressView()
        }
    }
    .environment(app)
}
