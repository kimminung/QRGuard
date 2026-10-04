import WidgetKit
import SwiftUI
import AppIntents

/// 앱과 같은 딥링크 (`QRGuardLinks.scan`). 위젯 타깃은 패키지를 링크하지 않아 문자열을 직접 둔다.
nonisolated enum WidgetLinks {
    static let scan = URL(string: "qrguard://scan")!
}

// MARK: - App Intent

/// "QR Guard로 스캔" — 제어 센터·단축어에서 한 번에 스캐너로 진입한다.
/// 확장 프로세스에서 실행되므로 앱 상태를 직접 건드리지 않고 URL 열기 인텐트를 돌려준다.
struct OpenScannerIntent: AppIntent {
    static let title: LocalizedStringResource = "QR Guard로 스캔"
    static let description = IntentDescription("QR 코드를 열기 전에 QR Guard로 먼저 검사해요.")

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(WidgetLinks.scan))
    }
}

// MARK: - 제어 센터 컨트롤

struct QRGuardScanControl: ControlWidget {
    static let kind = "com.coulson.QRGuard.scanControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenScannerIntent()) {
                Label("QR Guard로 스캔", systemImage: "qrcode.viewfinder")
            }
        }
        .displayName("QR Guard로 스캔")
        .description("QR 코드를 열기 전에 먼저 검사해요.")
    }
}

// MARK: - 잠금화면 위젯

struct ScanEntry: TimelineEntry {
    let date: Date
}

struct ScanProvider: TimelineProvider {
    func placeholder(in context: Context) -> ScanEntry { ScanEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (ScanEntry) -> Void) {
        completion(ScanEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ScanEntry>) -> Void) {
        // 정적 위젯: 내용이 바뀌지 않으므로 갱신하지 않는다.
        completion(Timeline(entries: [ScanEntry(date: .now)], policy: .never))
    }
}

struct QRGuardLockScreenWidget: Widget {
    let kind = "com.coulson.QRGuard.lockScreen"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ScanProvider()) { _ in
            LockScreenScanView()
                .widgetURL(WidgetLinks.scan)
        }
        .configurationDisplayName("QR Guard 스캔")
        .description("탭하면 QR Guard 스캐너가 바로 열려요.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

struct LockScreenScanView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular:
                HStack(spacing: 8) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("QR Guard")
                            .font(.headline)
                        Text("열기 전에 먼저 검사")
                            .font(.caption)
                    }
                }
            default:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "qrcode.viewfinder")
                        .font(.title2.weight(.semibold))
                }
            }
        }
        .containerBackground(for: .widget) { Color.clear }
        .accessibilityLabel("QR Guard로 스캔")
    }
}

#Preview(as: .accessoryCircular) {
    QRGuardLockScreenWidget()
} timeline: {
    ScanEntry(date: .now)
}
