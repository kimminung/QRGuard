import SwiftUI
import AVFoundation

/// 첫 실행 1화면: 앱이 하는 일 3줄 + 카메라 권한 프라이밍 (TASKS T-2.1).
struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @State private var requesting = false

    var body: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()
            BrandMark(size: 96)
            VStack(spacing: Spacing.s) {
                Text("QR Guard")
                    .font(.largeTitle.bold())
                    .foregroundStyle(Palette.ink)
                Text("QR 코드, 열기 전에 먼저 확인하세요")
                    .font(.title3)
                    .foregroundStyle(Palette.inkSecondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: Spacing.l) {
                point("camera.viewfinder", "스캔해도 바로 열지 않아요", "주소 구조, 브랜드 사칭, 실제 도착 주소를 먼저 살펴봐요.")
                point("shield.lefthalf.filled", "안전 · 주의 · 위험으로 알려드려요", "위험 점수와 함께 무엇이 왜 위험한지 설명해요.")
                point("hand.tap", "접속 여부는 직접 결정해요", "주의·위험 등급은 확인 단계를 거친 뒤에만 열 수 있어요.")
            }
            .padding(.horizontal, Spacing.l)
            Spacer()
            VStack(spacing: Spacing.m) {
                Button {
                    requestCamera()
                } label: {
                    Label("카메라 허용", systemImage: "camera")
                }
                .buttonStyle(.primary(.brand))
                .disabled(requesting)
                Button("나중에") { app.completeOnboarding() }
                    .font(.subheadline)
                    .foregroundStyle(Palette.inkSecondary)
            }
            .padding(.horizontal, Spacing.l)
            Text("카메라는 QR 코드를 스캔해 연결된 주소의 위험 요소를 확인하는 데만 사용해요.")
                .font(.caption)
                .foregroundStyle(Palette.inkSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.l)
        }
        .background(Palette.surface.ignoresSafeArea())
        .interactiveDismissDisabled()
    }

    private func point(_ symbol: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Palette.brand)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(Palette.ink)
                Text(body).font(.subheadline).foregroundStyle(Palette.inkSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func requestCamera() {
        requesting = true
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            requesting = false
            app.completeOnboarding()
        }
    }
}

#Preview {
    OnboardingView().environment(PreviewSupport.appModel())
}
