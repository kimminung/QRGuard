import SwiftUI
import SwiftData
import PhotosUI
import QRGuardCore

/// 홈 (TASKS T-2.2): 큰 스캔 버튼, 사진 불러오기, 링크 붙여넣기, 최근 기록 3건, 예방 팁.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \ScanRecord.scannedAt, order: .reverse) private var records: [ScanRecord]

    @State private var photoItem: PhotosPickerItem?
    @State private var photoError: String?
    @State private var importing = false
    @State private var tipIndex = Int.random(in: 0..<PreventionTip.all.count)

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.l) {
                if app.showIncidentBanner {
                    incidentBanner
                }
                heroCard
                HStack(spacing: Spacing.m) {
                    PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                        QuickActionLabel(symbol: "photo", title: "사진에서 불러오기")
                    }
                    .buttonStyle(.plain)
                    .disabled(importing)
                    .accessibilityLabel("사진에서 불러오기")
                    Button {
                        app.showPasteSheet = true
                    } label: {
                        QuickActionLabel(symbol: "link", title: "링크 붙여넣기")
                    }
                    .buttonStyle(.plain)
                }
                recentSection
                TipCard(title: PreventionTip.all[tipIndex].title, message: PreventionTip.all[tipIndex].body)
                    .onTapGesture { withAnimation { tipIndex = (tipIndex + 1) % PreventionTip.all.count } }
                    .accessibilityHint("탭하면 다음 팁을 보여줘요")
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.xl)
        }
        .background(Palette.surface.ignoresSafeArea())
        .navigationTitle("QR Guard")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                BrandMark(size: 24)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    app.path.append(.settings)
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("설정")
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            importPhoto(item)
        }
        .alert("QR 코드를 찾지 못했어요", isPresented: Binding(get: { photoError != nil }, set: { if !$0 { photoError = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(photoError ?? "")
        }
        .overlay {
            if importing {
                ProgressView("사진에서 QR을 찾는 중…")
                    .padding(Spacing.xl)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.card))
            }
        }
    }

    // MARK: - 섹션

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("QR 코드, 열기 전에\n먼저 확인하세요")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text("스캔해도 바로 열지 않아요.\n위험 요소부터 살펴본 뒤 알려드려요.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.onBrandSecondary)
            }
            Button {
                app.showScanner = true
            } label: {
                Label("QR 코드 스캔하기", systemImage: "camera")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .foregroundStyle(Palette.brand)
                    .background(.white, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("scanButton")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.xl)
        .background(Palette.brand, in: RoundedRectangle(cornerRadius: Radius.hero, style: .continuous))
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack {
                SectionHeader(title: String(localized: "최근 기록"))
                Button("전체 보기") { app.path.append(.history) }
                    .font(.subheadline)
            }
            if records.isEmpty {
                VStack(spacing: Spacing.s) {
                    Image(systemName: "clock")
                        .font(.title2)
                        .foregroundStyle(Palette.inkSecondary)
                    Text("아직 검사한 QR이 없어요")
                        .font(.subheadline)
                        .foregroundStyle(Palette.inkSecondary)
                }
                .frame(maxWidth: .infinity)
                .card()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(records.prefix(3).enumerated()), id: \.element.id) { index, record in
                        Button { app.openRecord(record) } label: {
                            RecordRow(record: record)
                        }
                        .buttonStyle(.plain)
                        if index < min(records.count, 3) - 1 {
                            Divider().overlay(Palette.line)
                        }
                    }
                }
                .card(padding: 0)
            }
        }
    }

    private var incidentBanner: some View {
        Button { app.path.append(.incidentGuide) } label: {
            HStack(spacing: Spacing.m) {
                Image(systemName: "cross.case.fill")
                    .foregroundStyle(Palette.danger)
                VStack(alignment: .leading, spacing: 2) {
                    Text("위험 등급 코드를 여셨나요?")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                    Text("피해 대응 가이드를 확인하세요")
                        .font(.caption)
                        .foregroundStyle(Palette.inkSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.inkSecondary)
            }
            .padding(Spacing.m)
            .background(Palette.dangerBg, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 사진 불러오기

    private func importPhoto(_ item: PhotosPickerItem) {
        importing = true
        Task {
            defer { importing = false; photoItem = nil }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    photoError = String(localized: "사진을 읽지 못했어요. 다른 사진을 골라 주세요.")
                    return
                }
                let payloads = try await QRImageDecoder.decode(imageData: data)
                guard let first = payloads.first else {
                    photoError = String(localized: "이 사진에서는 QR 코드를 찾지 못했어요. QR이 선명하게 보이는 사진을 골라 주세요.")
                    return
                }
                app.startAnalysis(ScanInput(raw: first, source: .photo, distinctCodes: payloads.count))
            } catch {
                photoError = String(localized: "사진을 분석하지 못했어요. 다시 시도해 주세요.")
            }
        }
    }
}

/// 홈의 빠른 동작 카드 라벨.
struct QuickActionLabel: View {
    let symbol: String
    let title: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Palette.brand)
                .frame(width: 36, height: 36)
                .background(Palette.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .contentShape(Rectangle())
    }
}

/// 기록 행 (홈·기록 화면 공용).
struct RecordRow: View {
    let record: ScanRecord
    var showsSource: Bool = false

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: record.blocksOpening ? "nosign" : record.riskTier.symbol)
                .font(.body)
                .foregroundStyle(record.riskTier.color)
                .frame(width: 36, height: 36)
                .background(record.riskTier.background, in: Circle())
                .accessibilityLabel(record.riskTier.label)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                HStack(spacing: Spacing.xs) {
                    Text(subtitle)
                    if record.userOpened {
                        Text("열었음")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Palette.danger)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Palette.dangerBg, in: Capsule())
                    }
                }
                .font(.caption)
                .foregroundStyle(Palette.inkSecondary)
                .lineLimit(1)
            }
            Spacer()
            MiniRiskMeter(score: record.score).frame(width: 52)
            Text("\(record.score)")
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(record.riskTier.color)
                .frame(minWidth: 28, alignment: .trailing)
        }
        .padding(Spacing.m)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts: [String] = []
        if showsSource {
            parts.append(record.scannedAt.formatted(date: .omitted, time: .shortened))
            parts.append(record.scanSource.title)
            if let place = record.placeContext { parts.append(place.title) }
        } else {
            parts.append(record.riskTier.label)
            parts.append(record.scannedAt.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }
}

extension ScanSource {
    var title: String {
        switch self {
        case .camera: String(localized: "카메라")
        case .photo: String(localized: "사진")
        case .paste: String(localized: "붙여넣기")
        case .shareExtension: String(localized: "공유")
        }
    }
}

extension PlaceContext {
    var title: String {
        switch self {
        case .parkingOrPayment: String(localized: "주차·결제")
        case .mobility: String(localized: "킥보드·자전거")
        case .emailOrMessage: String(localized: "이메일·문자")
        case .storeOrMenu: String(localized: "가게·메뉴")
        case .other: String(localized: "기타")
        }
    }
}

/// 근거 기반 예방 팁 5종 (RISK_RULES.md 7장 출처).
struct PreventionTip {
    let title: String
    let body: String

    static let all: [PreventionTip] = [
        PreventionTip(title: String(localized: "킥보드·주차장 QR은 만져 보세요"), body: String(localized: "진짜 코드 위에 가짜 스티커를 덧붙이는 수법이 알려져 있어요. 테두리가 들뜨거나 겹쳐 있으면 의심하세요.")),
        PreventionTip(title: String(localized: "메일·문자로 온 QR 인증은 의심하세요"), body: String(localized: "정상적인 기관은 이메일·문자로 QR 인증을 요구하지 않아요.")),
        PreventionTip(title: String(localized: "접속 후 앱 설치를 요구하면 닫으세요"), body: String(localized: "'보안 앱', '안전거래 앱' 설치 파일로 악성 앱을 심는 사례가 반복되고 있어요.")),
        PreventionTip(title: String(localized: "주소를 한 글자씩 확인하세요"), body: String(localized: "naver → navcr 처럼 한 글자만 바꾼 주소로 로그인 정보를 노려요. 공식 앱이나 검색으로 직접 들어가세요.")),
        PreventionTip(title: String(localized: "단축 주소는 실제 도착지를 확인하세요"), body: String(localized: "bit.ly 같은 단축 주소는 어디로 가는지 숨겨요. QR Guard가 쿠키 없이 끝까지 따라가 보여드려요.")),
    ]
}

#Preview {
    NavigationStack {
        HomeView()
    }
    .environment(PreviewSupport.appModel())
    .modelContainer(PreviewSupport.container)
}
