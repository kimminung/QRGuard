import SwiftUI
import SwiftData

/// QR Guard — QR 코드를 스캔하면 바로 열지 않고 위험 요소를 먼저 분석하는 앱.
@main
struct QRGuardApp: App {
    private let container: ModelContainer
    @State private var appModel: AppModel

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: ScanRecord.self)
        } catch {
            // 스키마 문제 등으로 열 수 없으면 메모리 전용으로 폴백해 앱은 계속 동작하게 한다.
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            container = try! ModelContainer(for: ScanRecord.self, configurations: config)
        }
        self.container = container
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
}
