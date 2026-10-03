import SwiftUI
import QRGuardCore

/// 설정 화면 값. UserDefaults에 저장하고 다음 분석부터 즉시 반영된다.
@Observable
final class AppSettings {
    enum Theme: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: String(localized: "시스템 설정")
            case .light: String(localized: "라이트")
            case .dark: String(localized: "다크")
            }
        }
        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    /// 기록 보관 기간. `none`이면 디스크에 쓰지 않는다.
    enum Retention: Int, CaseIterable, Identifiable {
        case days7 = 7
        case days30 = 30
        case forever = 0
        case none = -1
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .days7: String(localized: "7일")
            case .days30: String(localized: "30일")
            case .forever: String(localized: "무기한")
            case .none: String(localized: "저장 안 함")
            }
        }
    }

    private let defaults: UserDefaults

    var hasOnboarded: Bool { didSet { defaults.set(hasOnboarded, forKey: "hasOnboarded") } }
    var theme: Theme { didSet { defaults.set(theme.rawValue, forKey: "theme") } }
    var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: "haptics") } }
    var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: "sound") } }
    var retention: Retention { didSet { defaults.set(retention.rawValue, forKey: "retention") } }
    var scannerCoachmarkShown: Bool { didSet { defaults.set(scannerCoachmarkShown, forKey: "coachmark") } }

    // 검사 항목 (TECH_PRD 6.1)
    var followRedirects: Bool { didSet { defaults.set(followRedirects, forKey: "opt.redirects") } }
    var reputationLookup: Bool { didSet { defaults.set(reputationLookup, forKey: "opt.reputation") } }
    var urlhausLookup: Bool { didSet { defaults.set(urlhausLookup, forKey: "opt.urlhaus") } }
    var domainAgeLookup: Bool { didSet { defaults.set(domainAgeLookup, forKey: "opt.domainAge") } }
    var pagePrecheck: Bool { didSet { defaults.set(pagePrecheck, forKey: "opt.page") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasOnboarded = defaults.bool(forKey: "hasOnboarded")
        theme = Theme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system
        hapticsEnabled = defaults.object(forKey: "haptics") as? Bool ?? true
        soundEnabled = defaults.object(forKey: "sound") as? Bool ?? false
        retention = Retention(rawValue: defaults.object(forKey: "retention") as? Int ?? 30) ?? .days30
        scannerCoachmarkShown = defaults.bool(forKey: "coachmark")
        followRedirects = defaults.object(forKey: "opt.redirects") as? Bool ?? true
        reputationLookup = defaults.object(forKey: "opt.reputation") as? Bool ?? true
        urlhausLookup = defaults.object(forKey: "opt.urlhaus") as? Bool ?? false
        domainAgeLookup = defaults.object(forKey: "opt.domainAge") as? Bool ?? true
        pagePrecheck = defaults.object(forKey: "opt.page") as? Bool ?? false
    }

    /// 현재 토글의 스냅샷. 분석 시작 시점에 고정된다.
    var analysisOptions: AnalysisOptions {
        AnalysisOptions(
            followRedirects: followRedirects,
            reputationLookup: reputationLookup,
            urlhausLookup: urlhausLookup,
            domainAgeLookup: domainAgeLookup,
            pagePrecheck: pagePrecheck
        )
    }
}

/// 햅틱·사운드 피드백. 설정에서 끌 수 있다.
enum Feedback {
    static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType, settings: AppSettings) {
        guard settings.hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }

    static func impact(settings: AppSettings) {
        guard settings.hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func resultSound(for tier: RiskTier, settings: AppSettings) {
        guard settings.soundEnabled else { return }
        // 시스템 사운드: 1057(틱), 1053(경고), 1073(오류)
        let id: UInt32 = switch tier {
        case .safe: 1057
        case .caution: 1053
        case .danger: 1073
        }
        AudioServicesPlaySystemSound(id)
    }
}

import AudioToolbox
