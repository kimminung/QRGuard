import SwiftUI

/// 피해 대응 가이드 (TASKS T-5.4, TECH_PRD 7.7). 이미 열었거나 정보를 입력했을 때의 조치 + 신고 전화.
struct IncidentGuideView: View {
    @Environment(\.openURL) private var openURL

    private struct Step: Identifiable {
        let id: Int
        let title: LocalizedStringKey
        let body: LocalizedStringKey
    }

    private let steps: [Step] = [
        Step(id: 1, title: "페이지를 닫고 비밀번호 변경", body: "입력한 계정이 있다면 공식 앱에서 바로 비밀번호를 바꾸세요. 같은 비밀번호를 쓰는 다른 서비스도 함께 바꿔요."),
        Step(id: 2, title: "설치한 앱·프로파일 삭제", body: "설정 → 일반 → VPN 및 기기 관리에서 모르는 프로파일을 지우세요. 앱을 설치했다면 삭제하고, 백신 앱으로 점검하세요."),
        Step(id: 3, title: "금융 정보 확인", body: "카드사·은행에 연락해 결제 내역을 확인하고 필요하면 카드를 정지하세요. 공동·금융인증서는 재발급받으세요."),
        Step(id: 4, title: "신고·상담", body: "의심 QR은 보호나라 카카오톡 채널의 큐싱 확인 서비스로도 확인·신고할 수 있어요. 아래 번호로 바로 상담하세요."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Text("당황하지 말고 아래 순서대로 확인하세요.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.inkSecondary)
                ForEach(steps) { step in
                    HStack(alignment: .top, spacing: Spacing.m) {
                        Text("\(step.id)")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Palette.brand, in: Circle())
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text(step.title).font(.headline).foregroundStyle(Palette.ink)
                            Text(step.body).font(.subheadline).foregroundStyle(Palette.inkSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                    .accessibilityElement(children: .combine)
                }
                HStack(spacing: Spacing.m) {
                    phoneButton("112", String(localized: "경찰청"))
                    phoneButton("1332", String(localized: "금융감독원"))
                    phoneButton("118", String(localized: "인터넷진흥원"))
                }
                Text("전화 버튼은 실제 기기에서 바로 연결돼요.")
                    .font(.caption2)
                    .foregroundStyle(Palette.inkSecondary)
                    .frame(maxWidth: .infinity)
            }
            .padding(Spacing.l)
        }
        .background(Palette.surface.ignoresSafeArea())
        .navigationTitle("이미 열었다면")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func phoneButton(_ number: String, _ name: String) -> some View {
        Button {
            if let url = URL(string: "tel:\(number)") { openURL(url) }
        } label: {
            VStack(spacing: Spacing.xs) {
                Text(number)
                    .font(.title3.bold())
                    .foregroundStyle(Palette.brand)
                Text(name)
                    .font(.caption)
                    .foregroundStyle(Palette.inkSecondary)
            }
            .frame(maxWidth: .infinity)
            .card(padding: Spacing.m)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(name) \(number) 전화 걸기"))
    }
}

#Preview {
    NavigationStack { IncidentGuideView() }
}
