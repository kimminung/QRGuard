import SwiftUI
import QRGuardCore

/// 결과 화면 (TASKS T-3.3). 단일 뷰가 등급별 스타일·문구·행동 버튼(TECH_PRD 7.5)을 전환한다.
struct ResultView: View {
    @Bindable var session: AnalysisSession
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 접근성 글자 크기에서는 나란히 놓인 두 보조 버튼·문구를 세로로 쌓는다.
    private var isAX: Bool { dynamicTypeSize.isAccessibilitySize }
    private var pairLayout: AnyLayout {
        isAX ? AnyLayout(VStackLayout(spacing: Spacing.m)) : AnyLayout(HStackLayout(spacing: Spacing.m))
    }

    @State private var showChecklist = false
    @State private var showDangerConfirm = false
    @State private var showHoldToOpen = false
    @State private var copied = false

    private var report: RiskReport? { session.report }

    var body: some View {
        Group {
            if let report {
                content(report)
            } else {
                ProgressView()
            }
        }
        .background(Palette.surface.ignoresSafeArea())
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { app.goHome() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("닫기")
            }
            ToolbarItem(placement: .primaryAction) {
                if let report {
                    ShareLink(item: shareText(report)) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("결과 공유")
                }
            }
        }
        .sheet(isPresented: $showChecklist) {
            CautionChecklistSheet {
                showChecklist = false
                open()
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showHoldToOpen) {
            HoldToOpenSheet {
                showHoldToOpen = false
                open()
            }
            .presentationDetents([.medium])
        }
        .alert("정말 여시겠어요?", isPresented: $showDangerConfirm) {
            Button("위험을 감수하고 계속", role: .destructive) { showHoldToOpen = true }
            Button("취소", role: .cancel) {}
        } message: {
            Text("접속하지 않는 것을 권장해요. 계속하면 2초간 길게 눌러 한 번 더 확인해요. 열린 뒤 로그인·결제·앱 설치를 요구하면 바로 닫으세요.")
        }
        .overlay(alignment: .bottom) {
            if copied {
                Text("주소를 복사했어요")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, Spacing.l)
                    .padding(.vertical, Spacing.s)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, Spacing.xl)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - 본문

    private func content(_ report: RiskReport) -> some View {
        ScrollView {
            VStack(spacing: Spacing.l) {
                VStack(spacing: Spacing.l) {
                    // VoiceOver 읽기 순서: 등급(11) → 제목(10) → 위험 점수(9) → 실제 주소(8) → 행동 버튼(7) → 나머지
                    StatusEmblem(tier: report.tier, blocked: report.blocksOpening)
                        .accessibilitySortPriority(11)
                    Text(report.blocksOpening ? String(localized: "이 코드는 열 수 없어요") : report.tier.resultTitle)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Palette.ink)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilitySortPriority(10)
                    pairLayout {
                        CoverageBadge(coverage: report.coverage)
                        if session.userOpened {
                            Label("이 코드를 여셨어요", systemImage: "arrow.up.forward.app")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Palette.inkSecondary)
                                .padding(.horizontal, Spacing.m)
                                .padding(.vertical, Spacing.xs)
                                .background(Palette.card, in: Capsule())
                                .overlay(Capsule().strokeBorder(Palette.line))
                        }
                    }
                }
                .padding(.top, Spacing.s)

                RiskScoreCard(score: report.score, animated: !session.isRestored)
                    .accessibilitySortPriority(9)

                if report.originalURL != nil {
                    AddressCard(report: report, onCopy: copyAddress)
                        .accessibilitySortPriority(8)
                } else {
                    PayloadCard(raw: report.rawPayload, kind: report.payloadKind)
                        .accessibilitySortPriority(8)
                }

                findingsSummary(report)

                // 장소 맥락은 URL 계열에만 영향을 주고, 차단 결과는 바뀌지 않으므로 그 외에는 숨긴다.
                if session.snapshot != nil, report.originalURL != nil, !report.blocksOpening {
                    placeSection
                }

                actions(report)
                    .accessibilitySortPriority(7)

                footer(report)
            }
            .padding(Spacing.l)
        }
    }

    private func findingsSummary(_ report: RiskReport) -> some View {
        Button { app.path.append(.detail(session.id)) } label: {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if report.riskFindings.isEmpty {
                    HStack(spacing: Spacing.m) {
                        Circle().fill(Palette.safe).frame(width: 8, height: 8)
                        Text("검사 \(report.passedChecks.count)개 항목 모두 통과")
                            .font(.subheadline)
                            .foregroundStyle(Palette.ink)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Palette.inkSecondary)
                            .accessibilityHidden(true)
                    }
                } else {
                    ForEach(report.topFindings) { finding in
                        FindingRow(finding: finding)
                    }
                    if report.riskFindings.count > 3 {
                        Text("외 \(report.riskFindings.count - 3)개 · 상세 분석에서 모두 보기")
                            .font(.caption)
                            .foregroundStyle(Palette.inkSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
        .buttonStyle(.plain)
        .accessibilityHint("상세 분석 화면으로 이동해요")
    }

    private var placeSection: some View {
        let headerLayout = isAX
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Spacing.s))
        return VStack(alignment: .leading, spacing: Spacing.s) {
            headerLayout {
                Text("어디서 찍은 QR인가요?")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("선택하면 바로 다시 판단해요")
                    .font(.caption)
                    .foregroundStyle(Palette.inkSecondary)
            }
            PlaceChipGrid(selection: session.place) { place in
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    session.setPlace(session.place == place ? nil : place)
                }
                app.placeChanged(session)
            }
        }
    }

    // MARK: - 행동 버튼 (TECH_PRD 7.5)

    @ViewBuilder
    private func actions(_ report: RiskReport) -> some View {
        let openable = session.openTarget != nil && !report.blocksOpening
        VStack(spacing: Spacing.m) {
            if report.blocksOpening {
                Button("닫기") { app.goHome() }
                    .buttonStyle(.primary(.neutral))
                pairLayout {
                    Button("원본 복사") { copyRaw(report.rawPayload) }
                        .buttonStyle(.primary(.secondary))
                    Button("신고하기") { app.path.append(.incidentGuide) }
                        .buttonStyle(.primary(.secondary))
                }
            } else {
                switch report.tier {
                case .safe:
                    if openable {
                        Button(openLabel) { open() }
                            .buttonStyle(.primary(.brand))
                            .accessibilityIdentifier("openButton")
                    }
                    pairLayout {
                        Button("상세 분석 보기") { app.path.append(.detail(session.id)) }
                            .buttonStyle(.primary(.secondary))
                        Button(openable ? "주소 복사" : "내용 복사") { openable ? copyAddress() : copyRaw(report.rawPayload) }
                            .buttonStyle(.primary(.secondary))
                    }
                case .caution:
                    if openable {
                        Button("확인하고 \(openVerb)") { showChecklist = true }
                            .buttonStyle(.primary(.neutral))
                            .accessibilityIdentifier("openWithChecklistButton")
                    }
                    pairLayout {
                        Button("상세 분석 보기") { app.path.append(.detail(session.id)) }
                            .buttonStyle(.primary(.secondary))
                        Button(openable ? "열지 않기" : "닫기") { app.goHome() }
                            .buttonStyle(.primary(.secondary))
                    }
                case .danger:
                    Button(openable ? "열지 않고 닫기" : "닫기") { app.goHome() }
                        .buttonStyle(.primary(.danger))
                        .accessibilityIdentifier("closeDangerButton")
                    pairLayout {
                        Button("상세 분석 보기") { app.path.append(.detail(session.id)) }
                            .buttonStyle(.primary(.secondary))
                        Button("신고하기") { app.path.append(.incidentGuide) }
                            .buttonStyle(.primary(.secondary))
                    }
                }
            }
            if session.isRestored {
                Button {
                    app.reanalyze(session)
                } label: {
                    Label("다시 검사", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.medium))
                }
                .padding(.top, Spacing.xs)
            } else {
                Button {
                    app.scanAnother()
                } label: {
                    Label("다른 코드 스캔", systemImage: "qrcode.viewfinder")
                        .font(.subheadline.weight(.medium))
                }
                .padding(.top, Spacing.xs)
            }
        }
    }

    private func footer(_ report: RiskReport) -> some View {
        VStack(spacing: Spacing.s) {
            if report.tier == .danger, !report.blocksOpening, session.openTarget != nil {
                pairLayout {
                    Button("위험을 감수하고 열기") { showDangerConfirm = true }
                        .accessibilityIdentifier("riskyOpenButton")
                    if !isAX {
                        Text("·").foregroundStyle(Palette.inkSecondary)
                            .accessibilityHidden(true)
                    }
                    Button("이미 열었다면?") { app.path.append(.incidentGuide) }
                }
                .font(.footnote)
                .foregroundStyle(Palette.inkSecondary)
                .underline()
            } else {
                Text(report.tier == .safe
                     ? "열린 뒤 로그인·결제를 요구하면 한 번 더 확인하세요"
                     : "열린 뒤 로그인·결제·앱 설치를 요구하면 즉시 닫으세요")
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
                    .multilineTextAlignment(.center)
                Button("이미 열었다면?") { app.path.append(.incidentGuide) }
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
                    .underline()
            }
        }
        .padding(.top, Spacing.s)
    }

    // MARK: - 동작

    private var openLabel: String {
        switch report?.payloadKind {
        case .appScheme: String(localized: "앱 열기")
        case .url, .text: String(localized: "사이트 열기")
        case .phone: String(localized: "전화 걸기")
        case .sms: String(localized: "메시지 앱 열기")
        case .email: String(localized: "메일 앱 열기")
        default: String(localized: "열기")
        }
    }

    private var openVerb: String {
        switch report?.payloadKind {
        case .phone: String(localized: "전화 걸기")
        default: String(localized: "열기")
        }
    }

    /// 사용자의 명시적 탭(주의·위험은 추가 확인) 이후에만 호출된다 (CLAUDE.md).
    private func open() {
        guard let url = session.openTarget, report?.blocksOpening == false else { return }
        app.markOpened(session)
        openURL(url)
    }

    private func copyAddress() {
        guard let url = report?.openTarget ?? report?.originalURL else { return }
        UIPasteboard.general.string = url.absoluteString
        flashCopied()
    }

    private func copyRaw(_ raw: String) {
        UIPasteboard.general.string = raw
        flashCopied()
    }

    private func flashCopied() {
        let animation: Animation? = reduceMotion ? nil : .default
        withAnimation(animation) { copied = true }
        UIAccessibility.post(notification: .announcement, argument: String(localized: "주소를 복사했어요"))
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(animation) { copied = false }
        }
    }

    private func shareText(_ report: RiskReport) -> String {
        var lines: [String] = []
        lines.append(String(localized: "QR Guard 분석 결과: \(report.tier.label) · 위험 점수 \(report.score)/100"))
        if let url = report.finalURL ?? report.originalURL {
            lines.append(String(localized: "실제 도착 주소: \(url.absoluteString)"))
        } else {
            lines.append(report.rawPayload)
        }
        for finding in report.topFindings {
            lines.append("• " + RuleText.title(for: finding))
        }
        lines.append(String(localized: "※ 알려진 수법과 공개 위협 정보를 바탕으로 한 참고용 결과예요."))
        return lines.joined(separator: "\n")
    }
}

// MARK: - URL이 아닌 페이로드 카드

struct PayloadCard: View {
    let raw: String
    let kind: QRPayload.Kind
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // 접근성 글자 크기에서는 64pt 라벨 열에 "받는 사람" 같은 제목이 들어가지 않으므로 세로로 쌓는다.
        let isAX = dynamicTypeSize.isAccessibilitySize
        let rowLayout = isAX
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(kindTitle)
                .font(.caption)
                .foregroundStyle(Palette.inkSecondary)
            ForEach(details, id: \.0) { item in
                rowLayout {
                    Text(item.0)
                        .font(.subheadline)
                        .foregroundStyle(Palette.inkSecondary)
                        .frame(width: isAX ? nil : 64, alignment: .leading)
                    Text(item.1).font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink).textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }
            if details.isEmpty {
                Text(raw)
                    .font(.body)
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .lineLimit(6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var payload: QRPayload { PayloadParser.parse(raw) }

    private var kindTitle: String {
        switch kind {
        case .wifi: String(localized: "Wi-Fi 설정 QR")
        case .phone: String(localized: "전화번호")
        case .sms: String(localized: "문자 메시지")
        case .email: String(localized: "이메일")
        case .contact: String(localized: "연락처")
        case .geo: String(localized: "위치")
        case .payment: String(localized: "송금·결제 정보")
        case .appScheme: String(localized: "앱 실행 링크")
        case .text: String(localized: "텍스트")
        case .url: String(localized: "주소")
        }
    }

    private var details: [(String, String)] {
        switch payload {
        case .wifi(let config):
            return [
                (String(localized: "이름"), config.ssid),
                (String(localized: "보안"), config.security == .nopass ? String(localized: "없음(개방)") : config.security.rawValue),
                (String(localized: "숨김"), config.isHidden ? String(localized: "예") : String(localized: "아니요")),
            ]
        case .phone(let number):
            return [(String(localized: "번호"), number)]
        case .sms(let number, let body):
            var items = [(String(localized: "받는 번호"), number)]
            if let body { items.append((String(localized: "본문"), body)) }
            return items
        case .email(let address, let subject, _):
            var items = [(String(localized: "받는 사람"), address)]
            if let subject { items.append((String(localized: "제목"), subject)) }
            return items
        case .geo(let lat, let lon):
            return [(String(localized: "좌표"), "\(lat), \(lon)")]
        case .payment(let p):
            var items = [(String(localized: "종류"), p.scheme.rawValue), (String(localized: "주소"), p.address)]
            if let amount = p.amount { items.append((String(localized: "금액"), amount)) }
            return items
        default:
            return []
        }
    }
}

// MARK: - 주의 체크리스트 시트

struct CautionChecklistSheet: View {
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var checks = [false, false, false]

    private let items: [String] = [
        String(localized: "로그인·결제·앱 설치를 요구하면 즉시 닫을게요"),
        String(localized: "주소창의 도메인이 기대한 서비스와 같은지 확인할게요"),
        String(localized: "개인정보·인증번호는 입력하지 않을게요"),
    ]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Text("열기 전에 세 가지만 확인해 주세요")
                    .font(.title3.bold())
                    .foregroundStyle(Palette.ink)
                VStack(spacing: 0) {
                    ForEach(items.indices, id: \.self) { index in
                        Toggle(isOn: $checks[index]) {
                            Text(items[index])
                                .font(.subheadline)
                                .foregroundStyle(Palette.ink)
                        }
                        .toggleStyle(CheckToggleStyle())
                        .padding(.vertical, Spacing.m)
                        if index < items.count - 1 { Divider().overlay(Palette.line) }
                    }
                }
                .padding(.horizontal, Spacing.l)
                .card(padding: 0)
                Spacer()
                Button("열기") { onConfirm() }
                    .buttonStyle(.primary(.neutral))
                    .disabled(!checks.allSatisfy { $0 })
                    .accessibilityIdentifier("checklistOpenButton")
            }
            .padding(Spacing.l)
            .background(Palette.surface.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
            }
        }
    }
}

struct CheckToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .top, spacing: Spacing.m) {
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(configuration.isOn ? Palette.brand : Palette.inkSecondary)
                    .accessibilityHidden(true)
                configuration.label
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
        .accessibilityValue(configuration.isOn ? Text("확인함") : Text("확인 안 함"))
    }
}

// MARK: - 위험 등급 2초 길게 누르기

struct HoldToOpenSheet: View {
    let onComplete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0
    @State private var holding = false
    @State private var completed = false

    private let duration: TimeInterval = 2

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.xl) {
                VStack(spacing: Spacing.s) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Palette.danger)
                        .accessibilityHidden(true)
                    Text("2초간 길게 눌러 열기")
                        .font(.title3.bold())
                        .foregroundStyle(Palette.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text("접속하지 않는 것을 권장해요. 열리더라도 어떤 정보도 입력하지 마세요.")
                        .font(.subheadline)
                        .foregroundStyle(Palette.inkSecondary)
                        .multilineTextAlignment(.center)
                }
                // 글자가 커져도 잘리지 않도록 텍스트가 높이를 정하고(최소 56pt), 진행 막대는 배경으로 깐다.
                Text(completed ? "열고 있어요…" : "길게 눌러 열기")
                    .font(.body.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(progress > 0.5 ? .white : Palette.danger)
                    .padding(.horizontal, Spacing.l)
                    .padding(.vertical, Spacing.m)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background {
                        ZStack(alignment: .leading) {
                            Palette.dangerBg
                            GeometryReader { geo in
                                Palette.dangerFill.frame(width: geo.size.width * progress)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                    .onLongPressGesture(minimumDuration: duration, maximumDistance: 40) {
                        complete()
                    } onPressingChanged: { pressing in
                        holding = pressing
                        if pressing {
                            // 채워지는 진행 표시는 "2초를 채우고 있다"는 필수 피드백이라 Reduce Motion에서도 유지한다
                            // (즉시 100%로 채우면 완료된 것처럼 오해할 수 있다).
                            withAnimation(.linear(duration: duration)) { progress = 1 }
                        } else if !completed {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { progress = 0 }
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("위험을 감수하고 열기"))
                    .accessibilityHint(Text("터치로는 2초간 길게 누르세요. VoiceOver·스위치 제어에서는 '열기' 동작을 사용하세요"))
                    .accessibilityAddTraits(.isButton)
                    // 2초 길게 누르기를 할 수 없는 보조 기술 사용자를 위한 대체 동작 (CLAUDE.md: 명시적 사용자 동작 이후에만 열기).
                    .accessibilityAction(named: Text("열기")) { complete() }
                    .accessibilityIdentifier("holdToOpenButton")
                Button("취소") { dismiss() }
                    .buttonStyle(.primary(.secondary))
            }
            .padding(Spacing.l)
            .background(Palette.surface.ignoresSafeArea())
        }
    }

    private func complete() {
        guard !completed else { return }
        completed = true
        progress = 1
        onComplete()
    }
}

#Preview("안전") {
    let app = PreviewSupport.appModel()
    let session = app.startAnalysis(ScanInput(raw: "https://www.naver.com/", source: .camera))
    return NavigationStack { ResultView(session: session) }.environment(app)
}

#Preview("위험") {
    let app = PreviewSupport.appModel()
    let session = app.startAnalysis(ScanInput(raw: "https://naver-login.account-check.xyz/verify", source: .camera))
    return NavigationStack { ResultView(session: session) }.environment(app)
}

#Preview("차단") {
    let app = PreviewSupport.appModel()
    let session = app.startAnalysis(ScanInput(raw: "itms-services://?action=download-manifest&url=https://example.test/a.plist", source: .camera))
    return NavigationStack { ResultView(session: session) }.environment(app)
}
