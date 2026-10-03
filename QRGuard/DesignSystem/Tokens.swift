import SwiftUI
import QRGuardCore

/// 디자인 토큰 (TECH_PRD 7.3). 색은 Light/Dark 쌍으로 정의하고 등급 상태 표시에만 등급색을 쓴다.
/// `nonisolated`: UIColor 동적 공급 클로저는 SwiftUI 렌더러가 메인 스레드 밖에서 호출할 수 있다.
nonisolated enum Palette {
    static let brand = dynamic(light: 0x1D5BD8, dark: 0x5B8CFF)
    static let ink = dynamic(light: 0x0F1B33, dark: 0xEEF2FA)
    static let inkSecondary = dynamic(light: 0x5B6478, dark: 0xA3ACBF)
    static let surface = dynamic(light: 0xF3F5F9, dark: 0x0E1320)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x182033)
    static let line = dynamic(light: 0xE3E7EF, dark: 0x273049)

    static let safe = dynamic(light: 0x12925A, dark: 0x3DD68C)
    static let safeBg = dynamic(light: 0xE7F6EE, dark: 0x0F2A1F)
    static let caution = dynamic(light: 0xB76A00, dark: 0xFFB547)
    static let cautionBg = dynamic(light: 0xFFF3DC, dark: 0x2E2410)
    static let danger = dynamic(light: 0xD92D20, dark: 0xFF6B5E)
    static let dangerBg = dynamic(light: 0xFDECEA, dark: 0x33161A)

    /// 히어로 카드 등 브랜드 배경 위의 반투명 흰색
    static let onBrandSecondary = Color.white.opacity(0.82)

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        let lightColor = UIColor(hex: light)
        let darkColor = UIColor(hex: dark)
        return Color(uiColor: UIColor { @Sendable trait in
            trait.userInterfaceStyle == .dark ? darkColor : lightColor
        })
    }
}

nonisolated extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

enum Spacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum Radius {
    static let hero: CGFloat = 22
    static let card: CGFloat = 16
    static let button: CGFloat = 14
    static let row: CGFloat = 12
}

// MARK: - 등급 표현 (색 + 아이콘 모양 + 텍스트 3중 표현)

extension RiskTier {
    var color: Color {
        switch self {
        case .safe: Palette.safe
        case .caution: Palette.caution
        case .danger: Palette.danger
        }
    }

    var background: Color {
        switch self {
        case .safe: Palette.safeBg
        case .caution: Palette.cautionBg
        case .danger: Palette.dangerBg
        }
    }

    /// 방패 체크 / 삼각형 느낌표 / 팔각형 X — 색만으로 구분하지 않는다.
    var symbol: String {
        switch self {
        case .safe: "checkmark.shield.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .danger: "xmark.octagon.fill"
        }
    }

    var label: String {
        switch self {
        case .safe: String(localized: "안전")
        case .caution: String(localized: "주의")
        case .danger: String(localized: "위험")
        }
    }

    /// 결과 화면 제목 (RISK_RULES.md 2장). "안전합니다" 같은 단정 표현 금지.
    var resultTitle: String {
        switch self {
        case .safe: String(localized: "알려진 위험 요소가\n발견되지 않았어요")
        case .caution: String(localized: "접속 전에 확인이 필요해요")
        case .danger: String(localized: "접속하지 않는 것을 권장해요")
        }
    }

    var haptic: UINotificationFeedbackGenerator.FeedbackType {
        switch self {
        case .safe: .success
        case .caution: .warning
        case .danger: .error
        }
    }
}

// MARK: - 공통 수정자

struct CardBackground: ViewModifier {
    var radius: CGFloat = Radius.card
    var padding: CGFloat = Spacing.l

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Palette.line, lineWidth: 1)
            )
    }
}

extension View {
    func card(radius: CGFloat = Radius.card, padding: CGFloat = Spacing.l) -> some View {
        modifier(CardBackground(radius: radius, padding: padding))
    }
}

/// 앱 전반에서 쓰는 방패 + QR 마크.
struct BrandMark: View {
    var size: CGFloat = 28
    var tint: Color = Palette.brand

    var body: some View {
        ZStack {
            Image(systemName: "shield.fill")
                .font(.system(size: size))
                .foregroundStyle(tint)
            Image(systemName: "qrcode")
                .font(.system(size: size * 0.46, weight: .bold))
                .foregroundStyle(.white)
                .offset(y: -size * 0.03)
        }
        .accessibilityHidden(true)
    }
}
