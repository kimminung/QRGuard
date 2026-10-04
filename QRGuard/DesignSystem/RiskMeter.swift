import SwiftUI
import QRGuardCore

/// 시그니처 컴포넌트 (TECH_PRD 7.4). 0–29 / 30–69 / 70–100 세 구간과 현재 점수 마커.
struct RiskMeter: View {
    let score: Int
    var animated: Bool = true
    var showsLabels: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var displayed: Double = 0

    private var tier: RiskTier { RiskTier(score: score) }

    var body: some View {
        // 접근성 글자 크기에서는 구간 라벨 3개가 한 줄에 들어가지 않으므로 세로로 쌓는다.
        let labelLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xs))
            : AnyLayout(HStackLayout())
        VStack(alignment: .leading, spacing: Spacing.s) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    HStack(spacing: 3) {
                        segment(.safe).frame(width: max(0, width * 0.30 - 2))
                        segment(.caution).frame(width: max(0, width * 0.40 - 2))
                        segment(.danger)
                    }
                    .frame(height: 8)
                    // 마커
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Palette.ink)
                        .frame(width: 4, height: 18)
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Palette.card, lineWidth: 1.5))
                        .position(x: max(2, min(width - 2, width * displayed / 100)), y: 4)
                }
            }
            .frame(height: 18)

            if showsLabels {
                labelLayout {
                    Text("안전 0–29")
                    Spacer(minLength: 0)
                    Text("주의 30–69")
                    Spacer(minLength: 0)
                    Text("위험 70–100")
                }
                .font(.caption2)
                .foregroundStyle(Palette.inkSecondary)
            }
        }
        .onAppear {
            if animated && !reduceMotion {
                displayed = 0
                withAnimation(.easeOut(duration: 0.5)) { displayed = Double(score) }
            } else {
                displayed = Double(score)
            }
        }
        .onChange(of: score) { _, newValue in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { displayed = Double(newValue) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("위험 점수 \(score)점, 100점 만점, \(tier.label) 구간"))
    }

    private func segment(_ segmentTier: RiskTier) -> some View {
        Capsule()
            .fill(segmentTier == tier ? segmentTier.color : segmentTier.color.opacity(0.22))
            .frame(maxWidth: .infinity)
    }
}

/// 기록 행용 높이 4pt 미니 버전.
struct MiniRiskMeter: View {
    let score: Int
    private var tier: RiskTier { RiskTier(score: score) }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                HStack(spacing: 2) {
                    Capsule().fill(Palette.safe.opacity(tier == .safe ? 1 : 0.25)).frame(width: width * 0.30 - 1.5)
                    Capsule().fill(Palette.caution.opacity(tier == .caution ? 1 : 0.25)).frame(width: width * 0.40 - 1.5)
                    Capsule().fill(Palette.danger.opacity(tier == .danger ? 1 : 0.25))
                }
                .frame(height: 4)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Palette.ink)
                    .frame(width: 3, height: 10)
                    .position(x: max(1.5, min(width - 1.5, width * CGFloat(score) / 100)), y: 2)
            }
        }
        .frame(height: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("위험 점수 \(score)점, \(tier.label) 구간"))
    }
}

/// 큰 숫자 + "위험 점수" 라벨 + RiskMeter 카드.
struct RiskScoreCard: View {
    let score: Int
    var animated: Bool = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var tier: RiskTier { RiskTier(score: score) }

    var body: some View {
        let headerLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        VStack(alignment: .leading, spacing: Spacing.m) {
            headerLayout {
                Text("위험 점수")
                    .font(.subheadline)
                    .foregroundStyle(Palette.inkSecondary)
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Text("\(score)")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(tier.color)
                    Text("/ 100")
                        .font(.subheadline)
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
            RiskMeter(score: score, animated: animated)
        }
        .card()
        // 자식을 합치면 "위험 점수, 45, / 100, 위험 점수 45점…"처럼 중복되므로 한 문장으로 직접 읽어 준다.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("위험 점수 \(score)점, 100점 만점, \(tier.label) 구간"))
    }
}

#Preview("RiskMeter 3등급") {
    VStack(spacing: 24) {
        RiskScoreCard(score: 0)
        RiskScoreCard(score: 45)
        RiskScoreCard(score: 90)
        MiniRiskMeter(score: 45).frame(width: 60)
    }
    .padding()
    .background(Palette.surface)
}

#Preview("RiskMeter Dark") {
    VStack(spacing: 24) {
        RiskScoreCard(score: 12)
        RiskScoreCard(score: 68)
        RiskScoreCard(score: 95)
    }
    .padding()
    .background(Palette.surface)
    .preferredColorScheme(.dark)
}
