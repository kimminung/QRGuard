import SwiftUI
import AVFoundation
import VisionKit
import QRGuardCore

/// 스캐너 (TASKS T-2.3). 셔터 없음 · 자동 인식 · 겹친 QR 경고 · 플래시 · 사진 · 주소 직접 입력.
struct ScannerView: View {
    let onSelect: (ScanInput) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// 겹친 QR 선택 목록의 번호 원 — 글자와 함께 커진다
    @ScaledMetric(relativeTo: .caption) private var codeBadgeSize: CGFloat = 22

    @State private var permission: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var visiblePayloads: [String] = []
    @State private var paused = false
    @State private var torchOn = false
    @State private var showManualEntry = false
    @State private var showCoachmark = false
    @State private var unavailableReason: String?

    private var canUseDataScanner: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            cameraLayer
            overlay
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .sheet(isPresented: $showManualEntry) {
            PasteEntryView { input in
                showManualEntry = false
                onSelect(input)
            }
            .presentationDetents([.medium, .large])
        }
        .task {
            if permission == .notDetermined {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                permission = granted ? .authorized : .denied
            }
            if !app.settings.scannerCoachmarkShown {
                showCoachmark = true
                app.settings.scannerCoachmarkShown = true
            }
        }
    }

    // MARK: - 카메라

    @ViewBuilder
    private var cameraLayer: some View {
        switch permission {
        case .authorized:
            #if targetEnvironment(simulator)
            SimulatorScannerPlaceholder { payloads in
                handle(payloads: payloads)
            }
            #else
            if canUseDataScanner {
                DataScannerRepresentable(paused: paused, onCodes: handle(payloads:), onUnavailable: { unavailableReason = $0 })
                    .ignoresSafeArea()
            } else {
                AVMetadataScannerView(paused: paused, onCodes: handle(payloads:), onUnavailable: { unavailableReason = $0 })
                    .ignoresSafeArea()
            }
            #endif
        case .denied, .restricted:
            permissionDenied
        default:
            Color.black
        }
    }

    private var permissionDenied: some View {
        VStack(spacing: Spacing.l) {
            Image(systemName: "camera.badge.ellipsis")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.8))
            Text("카메라를 사용할 수 없어요")
                .font(.title3.bold())
                .foregroundStyle(.white)
            Text("설정에서 QR Guard의 카메라 접근을 허용하면 스캔할 수 있어요. 지금은 사진 불러오기와 링크 붙여넣기를 쓸 수 있어요.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
            Button("설정 열기") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.primary(.brand))
            .frame(maxWidth: 220)
        }
        .padding(Spacing.xl)
    }

    // MARK: - 오버레이

    private var overlay: some View {
        VStack(spacing: 0) {
            topBar
            if visiblePayloads.count >= 2 {
                multiCodeBanner
                    .padding(.horizontal, Spacing.l)
                    .padding(.top, Spacing.s)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if showCoachmark {
                coachmark
                    .padding(.horizontal, Spacing.l)
                    .padding(.top, Spacing.s)
                    .transition(.opacity)
            }
            if let unavailableReason {
                Text(unavailableReason)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(Spacing.m)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.row))
                    .padding(.top, Spacing.s)
            }
            Spacer()
            if visiblePayloads.count < 2 {
                #if !targetEnvironment(simulator)
                viewfinder
                #endif
                Spacer()
            } else {
                codeChoices
                    .padding(.horizontal, Spacing.l)
                    .padding(.bottom, Spacing.l)
            }
            bottomBar
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: visiblePayloads.count)
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.15), in: Circle())
            }
            .accessibilityLabel("닫기")
            Spacer()
            Text("QR 코드 스캔")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button { toggleTorch() } label: {
                Image(systemName: torchOn ? "bolt.fill" : "bolt.slash")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.15), in: Circle())
            }
            .accessibilityLabel(torchOn ? "플래시 끄기" : "플래시 켜기")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Spacing.l)
        .padding(.top, Spacing.s)
    }

    private var viewfinder: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(.white.opacity(0.9), style: StrokeStyle(lineWidth: 3, dash: [60, 1000], dashPhase: 30))
            .frame(width: 240, height: 240)
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            )
            .accessibilityHidden(true)
    }

    private var multiCodeBanner: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.caution)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("QR 코드가 \(visiblePayloads.count)개 보여요")
                    .font(.subheadline.weight(.semibold))
                Text("진짜 코드 위에 스티커가 덧붙여졌을 수 있어요. 검사할 코드를 골라 주세요.")
                    .font(.footnote)
            }
        }
        .foregroundStyle(Color(uiColor: UIColor(hex: 0x0F1B33)))
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: UIColor(hex: 0xFFF3DC)), in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        // 화면은 다크 고정이지만 배너 배경은 밝은색이므로 등급색도 Light 값으로 해석되게 한다 (Dark caution은 1.6:1).
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .combine)
    }

    private var coachmark: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: "hand.raised.fingers.spread")
                .accessibilityHidden(true)
            Text("스티커가 덧붙여져 있지 않은지 QR 주변을 확인하세요")
                .font(.footnote)
            Spacer()
            Button { showCoachmark = false } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                .accessibilityLabel("안내 닫기")
        }
        .foregroundStyle(.white)
        .padding(Spacing.m)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
    }

    private var codeChoices: some View {
        VStack(spacing: Spacing.s) {
            ForEach(Array(visiblePayloads.enumerated()), id: \.offset) { index, payload in
                Button {
                    select(payload, count: visiblePayloads.count)
                } label: {
                    HStack(spacing: Spacing.m) {
                        Text("\(index + 1)")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .frame(width: codeBadgeSize, height: codeBadgeSize)
                            .background(index == 0 ? Palette.brandFill : Palette.caution, in: Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(index == 0 ? "먼저 인식된 코드" : "추가로 보이는 코드")
                                .font(.caption)
                                .foregroundStyle(Palette.inkSecondary)
                            Text(displayHost(payload))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Palette.ink)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Palette.inkSecondary)
                            .accessibilityHidden(true)
                    }
                    .padding(Spacing.m)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .environment(\.colorScheme, .light)
    }

    private var bottomBar: some View {
        HStack {
            Button {
                dismiss()
                // 홈의 PhotosPicker를 직접 열 수 없으므로 붙여넣기 시트와 동일하게 처리하지 않고 홈으로 돌아간다.
            } label: {
                Image(systemName: "photo")
                    .font(.body.weight(.semibold))
                    .frame(width: 48, height: 48)
                    .background(.white.opacity(0.15), in: Circle())
            }
            .accessibilityLabel("사진에서 불러오기 (홈으로 이동)")
            Spacer()
            Button {
                showManualEntry = true
            } label: {
                Label("주소 직접 입력", systemImage: "keyboard")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, Spacing.l)
                    .padding(.vertical, Spacing.m)
                    .background(.white.opacity(0.15), in: Capsule())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Spacing.l)
        .padding(.bottom, Spacing.l)
    }

    // MARK: - 동작

    private func handle(payloads: [String]) {
        guard !paused else { return }
        let distinct = payloads.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if distinct.count == 1, visiblePayloads.count < 2 {
            select(distinct[0], count: 1)
        } else {
            visiblePayloads = distinct
        }
    }

    private func select(_ payload: String, count: Int) {
        guard !paused else { return }
        paused = true
        Feedback.impact(settings: app.settings)
        setTorch(false)
        onSelect(ScanInput(raw: payload, source: .camera, distinctCodes: count, vision: VisionSignals(decodedCodeCount: count)))
    }

    private func displayHost(_ payload: String) -> String {
        if let url = URL(string: payload), let host = url.host() {
            let path = url.path()
            return host + (path == "/" ? "" : path)
        }
        return payload
    }

    private func toggleTorch() { setTorch(!torchOn) }

    private func setTorch(_ on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
            torchOn = on
        } catch {
            torchOn = false
        }
    }
}

// MARK: - 시뮬레이터 대체 화면

#if targetEnvironment(simulator)
/// 시뮬레이터에는 카메라가 없어 샘플 코드로 흐름을 확인한다.
struct SimulatorScannerPlaceholder: View {
    let onCodes: ([String]) -> Void

    private let samples: [(String, [String])] = [
        ("공식 도메인", ["https://www.naver.com/"]),
        ("단축 URL", ["https://bit.ly/3gH2kQ"]),
        ("브랜드 사칭", ["https://naver-login.account-check.xyz/verify?next=https%3A%2F%2Fevil.example.test%2F"]),
        ("앱 직접 설치", ["itms-services://?action=download-manifest&url=https://example.test/app.plist"]),
        ("겹친 QR 2개", ["https://bikeshare.example.test/rent?station=12", "https://t.ly/Ab3dE"]),
        ("Wi-Fi(암호 없음)", ["WIFI:T:nopass;S:FreeCafe;;"]),
    ]

    var body: some View {
        VStack(spacing: Spacing.m) {
            Spacer()
            Text("시뮬레이터에는 카메라가 없어요")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
            ForEach(samples, id: \.0) { sample in
                Button(sample.0) { onCodes(sample.1) }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.l)
                    .padding(.vertical, Spacing.s)
                    .background(.white.opacity(0.15), in: Capsule())
            }
            Spacer()
            Spacer()
        }
    }
}
#endif

#Preview {
    ScannerView { _ in }
        .environment(PreviewSupport.appModel())
}
