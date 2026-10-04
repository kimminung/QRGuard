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

    // 등급 텍스트 색은 Light에서 작은 글자(caption·footnote) 기준 WCAG 4.5:1을 넘도록 조정했다 (T-7.1).
    // safe: 0x12925A→0x0E7A4B (safeBg 3.56→4.82), caution: 0xB76A00→0x9A5600 (cautionBg 3.76→5.16),
    // danger: 0xD92D20→0xC9281C (dangerBg 4.22→4.83). Dark 값은 모두 5.9:1 이상이라 그대로 둔다.
    static let safe = dynamic(light: 0x0E7A4B, dark: 0x3DD68C)
    static let safeBg = dynamic(light: 0xE7F6EE, dark: 0x0F2A1F)
    static let caution = dynamic(light: 0x9A5600, dark: 0xFFB547)
    static let cautionBg = dynamic(light: 0xFFF3DC, dark: 0x2E2410)
    static let danger = dynamic(light: 0xC9281C, dark: 0xFF6B5E)
    static let dangerBg = dynamic(light: 0xFDECEA, dark: 0x33161A)

    /// 흰 글자를 올리는 **채움** 배경용 브랜드색. Dark의 `brand`(0x5B8CFF)는 글자색으로는 충분하지만
    /// 흰 글자 배경으로는 3.16:1이라 더 진한 값을 쓴다 (흰색 6.07:1, 82% 흰색 4.64:1).
    static let brandFill = dynamic(light: 0x1D5BD8, dark: 0x2A5BCB)
    /// 흰 글자를 올리는 채움 배경용 위험색. Dark `danger`는 흰 글자와 2.79:1이라 별도 값 (4.64:1).
    static let dangerFill = dynamic(light: 0xC9281C, dark: 0xD63B2E)
    /// `ink` 배경(중립 버튼·선택된 칩) 위의 글자색. Dark에서 `ink`는 거의 흰색이므로 흰 글자를 쓰면 보이지 않는다.
    static let onInk = dynamic(light: 0xFFFFFF, dark: 0x0E1320)

    /// 히어로 카드 등 브랜드 채움 배경 위의 반투명 흰색 (brandFill 기준 Light 4.52:1 · Dark 4.64:1)
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
