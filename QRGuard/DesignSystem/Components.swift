import SwiftUI
import QRGuardCore

// MARK: - StatusEmblem

/// 등급별 원형 아이콘 + 짧은 라벨.
struct StatusEmblem: View {
    let tier: RiskTier
    var blocked: Bool = false
    var size: CGFloat = 96

    var body: some View {
        VStack(spacing: Spacing.m) {
            ZStack {
                Circle().fill(tier.background)
                Image(systemName: blocked ? "nosign" : tier.symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(tier.color)
            }
            .frame(width: size, height: size)
            Text(blocked ? String(localized: "차단") : tier.label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tier.color)
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, Spacing.xs)
                .background(tier.background, in: Capsule())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("등급 \(blocked ? String(localized: "차단") : tier.label)"))
    }
}

// MARK: - AddressCard

/// 실제 도착 주소 카드. 등록 도메인(eTLD+1)을 굵게 강조하고, 리다이렉트가 있으면 두 줄로 보여준다.
struct AddressCard: View {
    let report: RiskReport
    var onCopy: (() -> Void)?

    private var official: RiskFinding? { report.findings.first { $0.id == .B03 } }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if report.hasRedirect, let original = report.originalURL {
                labeled(String(localized: "스캔한 주소")) {
                    Text(original.absoluteString)
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                HStack {
                    Rectangle().fill(Palette.line).frame(height: 1)
                    Text("\(report.redirectChain.count - 1)번 이동")
                        .font(.caption2)
                        .foregroundStyle(Palette.inkSecondary)
                        .fixedSize()
                    Rectangle().fill(Palette.line).frame(height: 1)
                }
            }
            labeled(String(localized: "실제 도착 주소")) {
                HostText(url: report.finalURL ?? report.originalURL, registrableDomain: report.domain?.registrableDomain, raw: report.rawPayload)
            }
            if let official {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "checkmark.seal.fill")
                        .accessibilityHidden(true)
                    Text(RuleText.title(for: official))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.safe)
                .padding(.horizontal, Spacing.s)
                .padding(.vertical, Spacing.xs)
                .background(Palette.safeBg, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .contextMenu {
            if let onCopy {
                Button(action: onCopy) { Label("주소 복사", systemImage: "doc.on.doc") }
            }
        }
        // 길게 누르기(컨텍스트 메뉴) 대신 VoiceOver 로터 동작으로도 복사할 수 있게 한다.
        .accessibilityAction(named: Text("주소 복사")) { onCopy?() }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Palette.inkSecondary)
            content()
        }
    }
}

/// 호스트를 크게, eTLD+1을 굵게, 전체 URL은 작게.
struct HostText: View {
    let url: URL?
    let registrableDomain: String?
    let raw: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let url {
                hostLine(for: url)
                    .font(.title3)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                Text(url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } else {
                Text(raw)
                    .font(.body)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
        }
    }

    private func hostLine(for url: URL) -> Text {
        let host = (url.host(percentEncoded: false) ?? url.absoluteString).lowercased()
        let path = url.path(percentEncoded: false)
        let pathText = (path.isEmpty || path == "/") ? Text("") : Text(path).foregroundStyle(Palette.inkSecondary)
        guard let rd = registrableDomain?.lowercased(), host.hasSuffix(rd), host != rd else {
            return Text(host).bold() + pathText
        }
        let prefix = String(host.dropLast(rd.count))
        return Text(prefix).foregroundStyle(Palette.inkSecondary) + Text(rd).bold() + pathText
    }
}

// MARK: - FindingRow

/// 위험 요소 한 줄: 점(등급색) + 제목 + 가산점/확정.
struct FindingRow: View {
    let finding: RiskFinding
    var showsChevron: Bool = false

    private var color: Color {
        if finding.points < 0 { return Palette.safe }
        if finding.isDecisive || finding.points >= 25 { return Palette.danger }
        if finding.points == 0 { return Palette.inkSecondary }
        return Palette.caution
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            Circle().fill(color).frame(width: 8, height: 8)
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
            Text(RuleText.title(for: finding))
                .font(.subheadline)
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            pointsBadge
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.inkSecondary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var pointsBadge: some View {
        if finding.isDecisive {
            Text("확정")
                .font(.caption.weight(.bold))
                .foregroundStyle(Palette.danger)
        } else if finding.points > 0 {
            Text("+\(finding.points)")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
        } else if finding.points < 0 {
            Text("\(finding.points)")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Palette.safe)
        } else {
            Text("정보")
                .font(.caption)
                .foregroundStyle(Palette.inkSecondary)
        }
    }
}

// MARK: - Buttons

enum ActionTone { case brand, neutral, danger, secondary }

struct PrimaryActionButtonStyle: ButtonStyle {
    var tone: ActionTone = .brand
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .padding(.horizontal, Spacing.l)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                    .strokeBorder(tone == .secondary ? Palette.line : .clear, lineWidth: 1)
            )
            // 비활성 버튼은 흐리게 — 입력란이 비었을 때 "분석하기"가 눌러지는 것처럼 보이지 않도록
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch tone {
        case .brand, .danger: .white
        case .neutral: Palette.onInk   // Dark에서 ink는 밝은색이라 흰 글자는 보이지 않는다
        case .secondary: Palette.ink
        }
    }

    private var background: Color {
        switch tone {
        case .brand: Palette.brandFill
        case .neutral: Palette.ink
        case .danger: Palette.dangerFill
        case .secondary: Palette.card
        }
    }
}

extension ButtonStyle where Self == PrimaryActionButtonStyle {
    static func primary(_ tone: ActionTone) -> PrimaryActionButtonStyle { PrimaryActionButtonStyle(tone: tone) }
}

// MARK: - TipCard

struct TipCard: View {
    let title: String
    let message: String
    var symbol: String = "lightbulb.fill"

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(Palette.caution)
                .frame(width: 24, height: 24)
                .background(Palette.cautionBg, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
            }
            Spacer(minLength: 0)
        }
        .card()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - CoverageBadge

/// 확인 범위가 제한적일 때 표시하는 배지.
struct CoverageBadge: View {
    let coverage: AnalysisCoverage

    var body: some View {
        if coverage.isLimited {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "wifi.exclamationmark")
                    .accessibilityHidden(true)
                Text(text)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Palette.caution)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.xs)
            .background(Palette.cautionBg, in: Capsule())
            .accessibilityElement(children: .combine)
        }
    }

    private var text: String {
        switch coverage {
        case .offlineOnly: String(localized: "구조 분석만 했어요")
        case .partial: String(localized: "확인 범위가 제한적이에요")
        case .full: ""
        }
    }
}

extension AnalysisCoverage {
    var summaryText: String {
        switch self {
        case .full: String(localized: "전체 검사 완료")
        case .offlineOnly: String(localized: "구조 분석만 완료")
        case .partial(let ids): String(localized: "일부 확인 못 함 (\(ids.count)개)")
        }
    }
}

extension CheckID {
    var title: String {
        switch self {
        case .structure: String(localized: "주소 구조 분석")
        case .redirect: String(localized: "실제 도착 주소 확인")
        case .domainAge: String(localized: "도메인 생성일 확인")
        case .reputation: String(localized: "악성 사이트 조회")
        case .pagePrecheck: String(localized: "페이지 미리 검사")
        }
    }
}

extension AnalysisStep {
    var title: String { checkID.title }
}

// MARK: - 섹션 헤더

struct SectionHeader: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Palette.ink)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

#Preview("Components") {
    ScrollView {
        VStack(spacing: 20) {
            HStack(spacing: 24) {
                StatusEmblem(tier: .safe, size: 72)
                StatusEmblem(tier: .caution, size: 72)
                StatusEmblem(tier: .danger, size: 72)
                StatusEmblem(tier: .danger, blocked: true, size: 72)
            }
            FindingRow(finding: RiskFinding(id: .T01, points: 0, floor: 90, sources: [.S8]), showsChevron: true)
            FindingRow(finding: RiskFinding(id: .B01, points: 30, evidence: ["brand": "네이버"]))
            FindingRow(finding: RiskFinding(id: .U11, points: 10, evidence: ["service": "bit.ly"]))
            FindingRow(finding: RiskFinding(id: .B03, points: -20))
            Button("사이트 열기") {}.buttonStyle(.primary(.brand))
            Button("확인하고 열기") {}.buttonStyle(.primary(.neutral))
            Button("열지 않고 닫기") {}.buttonStyle(.primary(.danger))
            Button("상세 분석 보기") {}.buttonStyle(.primary(.secondary))
            TipCard(title: "킥보드·주차장 QR은 만져 보세요", message: "진짜 코드 위에 가짜 스티커를 덧붙이는 수법이 알려져 있어요.")
            CoverageBadge(coverage: .partial([.redirect]))
        }
        .padding()
    }
    .background(Palette.surface)
}
