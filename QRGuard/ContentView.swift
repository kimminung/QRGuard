import SwiftUI
import SwiftData
import QRGuardCore

/// 루트: NavigationStack + 경로 열거형. 스캐너는 fullScreenCover.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var app = app
        NavigationStack(path: $app.path) {
            HomeView()
                .navigationDestination(for: AppRoute.self) { route in
                    destination(for: route)
                }
        }
        .fullScreenCover(isPresented: $app.showScanner) {
            ScannerView { input in
                app.showScanner = false
                app.startAnalysis(input)
            }
        }
        .sheet(isPresented: $app.showPasteSheet) {
            PasteEntryView { input in
                app.showPasteSheet = false
                app.startAnalysis(input)
            }
            .presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $app.showOnboarding) {
            OnboardingView()
        }
        // 위젯·제어 센터(`qrguard://scan`)와 공유 확장(`qrguard://analyze`) 딥링크
        .onOpenURL { url in
            app.handleDeepLink(url)
        }
        // 공유 확장이 남긴 결과는 앱이 앞으로 올 때 기록으로 가져온다(방금 공유한 것이면 바로 연다).
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                app.importSharedInbox(openRecent: true)
            }
        }
    }

    @ViewBuilder
    private func destination(for route: AppRoute) -> some View {
        switch route {
        case .analysis(let id):
            if let session = app.session(id) {
                AnalysisView(session: session)
            } else {
                missingSession
            }
        case .result(let id):
            if let session = app.session(id) {
                ResultView(session: session)
            } else {
                missingSession
            }
        case .detail(let id):
            if let session = app.session(id), let report = session.report {
                DetailView(report: report, session: session)
            } else {
                missingSession
            }
        case .history:
            HistoryView()
        case .settings:
            SettingsView()
        case .incidentGuide:
            IncidentGuideView()
        case .licenses:
            LicensesView()
        case .privacyPolicy:
            PrivacyPolicyView()
        case .about:
            AboutView()
        }
    }

    private var missingSession: some View {
        ContentUnavailableView("결과를 찾을 수 없어요", systemImage: "questionmark.circle", description: Text("다시 스캔하거나 기록에서 열어 주세요."))
    }
}

#Preview {
    RootView()
        .environment(PreviewSupport.appModel())
        .modelContainer(PreviewSupport.container)
}
