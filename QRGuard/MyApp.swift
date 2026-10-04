import SwiftUI
import SwiftData
import QRGuardCore

/// QR Guard — QR 코드를 스캔하면 바로 열지 않고 위험 요소를 먼저 분석하는 앱.
@main
struct QRGuardApp: App {
    private let container: ModelContainer
    @State private var appModel: AppModel

    init() {
        container = Self.makeContainer()
        let settings = AppSettings()
        let model = AppModel(settings: settings, history: HistoryStore(context: container.mainContext))
        model.handleLaunchArguments()
        _appModel = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .preferredColorScheme(appModel.settings.theme.colorScheme)
                .tint(Palette.brand)
        }
        .modelContainer(container)
    }

    /// 기록 저장소. App Group 컨테이너가 있으면 거기에 두어 공유 확장과 같은 저장소를 쓴다.
    /// 열 수 없으면 기본 위치 → 메모리 전용 순으로 폴백해 앱은 계속 동작하게 한다.
    private static func makeContainer() -> ModelContainer {
        let schema = Schema([ScanRecord.self])
        if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: QRGuardLinks.appGroup) != nil {
            let grouped = ModelConfiguration("QRGuard", schema: schema, groupContainer: .identifier(QRGuardLinks.appGroup))
            if let container = try? ModelContainer(for: schema, configurations: grouped) {
                return container
            }
        }
        if let container = try? ModelContainer(for: schema) {
            return container
        }
        let memory = ModelConfiguration(isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: memory)
    }
}
