import SwiftUI
import SwiftData
import QRGuardCore

/// 설정 (TASKS T-5.3). 검사 항목 토글마다 "무엇이 어디로 전송되는지"를 함께 적는다 (TECH_PRD 6.1).
struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                checkToggle("실제 도착 주소 확인", isOn: $settings.followRedirects,
                            footer: "단축 주소를 끝까지 따라가요. 상대 서버는 누군가 접속했다는 사실을 알 수 있어요.")
                checkToggle("악성 사이트 조회", isOn: $settings.reputationLookup,
                            footer: app.hasSafeBrowsingKey
                            ? "Google Safe Browsing에 주소 원문이 아닌 짧은 암호화 조각(해시 앞 4바이트)만 보내 악성 여부를 확인해요."
                            : "지금은 앱에 포함된 블록리스트만 확인해요. Google Safe Browsing 실시간 조회는 이 빌드에 아직 연결되지 않았어요.")
                checkToggle("도메인 생성일 확인", isOn: $settings.domainAgeLookup,
                            footer: "RDAP(rdap.org)에 도메인 이름을 보내 언제 만들어졌는지 확인해요.")
                checkToggle("페이지 미리 검사", isOn: $settings.pagePrecheck,
                            footer: "최종 주소의 페이지 앞부분(최대 256KB)만 받아 로그인 입력란 등을 미리 확인해요. 자바스크립트는 실행하지 않아요.")
                checkToggle("URLhaus 조회", isOn: $settings.urlhausLookup,
                            footer: "abuse.ch URLhaus에 주소 원문을 보내 악성 파일 배포지인지 확인해요. 기본 꺼짐.")
            } header: {
                Text("검사 항목")
            } footer: {
                Text("꺼진 검사는 어떤 요청도 보내지 않아요. 변경은 다음 분석부터 반영돼요.")
            }

            Section("기록") {
                Picker("기록 보관 기간", selection: $settings.retention) {
                    ForEach(AppSettings.Retention.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .onChange(of: settings.retention) { _, newValue in
                    app.history.purgeExpired(retention: newValue)
                }
                NavigationLink("기록 보기") { HistoryView() }
            }

            Section("일반") {
                Picker("테마", selection: $settings.theme) {
                    ForEach(AppSettings.Theme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                Toggle("진동", isOn: $settings.hapticsEnabled)
                Toggle("사운드", isOn: $settings.soundEnabled)
            }

            Section("도움이 필요할 때") {
                Button { app.path.append(.incidentGuide) } label: {
                    row("이미 열었다면?", systemImage: "cross.case", detail: "피해 대응 가이드")
                }
                Link(destination: URL(string: "tel:118")!) {
                    row("KISA 118 상담", systemImage: "phone", detail: nil)
                }
            }

            Section {
                LabeledContent("블록리스트 업데이트", value: DataStore.bundled.blocklist.updatedAt ?? "—")
                LabeledContent("브랜드 공식 도메인", value: "\(DataStore.bundled.brands.count)개")
                LabeledContent("단축 URL 서비스", value: "\(DataStore.bundled.shorteners.count)개")
            } header: {
                Text("보안 데이터")
            } footer: {
                Text("앱에 포함된 데이터예요. 자동 업데이트는 추후 지원 예정이에요.")
            }

            Section("정보") {
                Button { app.path.append(.about) } label: { row("앱 정보", systemImage: "info.circle", detail: nil) }
                Button { app.path.append(.privacyPolicy) } label: { row("개인정보 처리방침", systemImage: "hand.raised", detail: nil) }
                Button { app.path.append(.licenses) } label: { row("오픈소스 라이선스", systemImage: "doc.text", detail: nil) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.surface.ignoresSafeArea())
        .navigationTitle("설정")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func checkToggle(_ title: LocalizedStringKey, isOn: Binding<Bool>, footer: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Toggle(title, isOn: isOn)
            Text(footer)
                .font(.caption)
                .foregroundStyle(Palette.inkSecondary)
        }
        .padding(.vertical, 2)
    }

    private func row(_ title: LocalizedStringKey, systemImage: String, detail: LocalizedStringKey?) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .foregroundStyle(Palette.ink)
            Spacer()
            if let detail {
                Text(detail).font(.footnote).foregroundStyle(Palette.inkSecondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.inkSecondary)
        }
    }
}

// MARK: - 정보 화면

struct AboutView: View {
    @Environment(AppModel.self) private var app

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: Spacing.m) {
                    BrandMark(size: 64)
                    Text("QR Guard").font(.title2.bold())
                    Text("버전 \(version)").font(.footnote).foregroundStyle(Palette.inkSecondary)
                    Text("QR 코드를 스캔하면 바로 열지 않고, 위험 요소부터 분석해 안전 · 주의 · 위험으로 알려주는 앱이에요. 접속할지 말지는 결과와 근거를 본 사용자가 직접 결정해요.")
                        .font(.subheadline)
                        .foregroundStyle(Palette.inkSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.m)
                .listRowBackground(Color.clear)
            }
            Section("외부 서비스") {
                LabeledContent("Google Safe Browsing", value: app.hasSafeBrowsingKey ? "사용 중" : "키 없음")
                Text("이 앱은 악성 사이트 조회에 Google Safe Browsing을 사용해요. Safe Browsing API는 비상업적 용도로만 제공돼요.")
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
                LabeledContent("도메인 정보", value: "RDAP (rdap.org)")
            }
            Section("면책") {
                Text("QR Guard는 알려진 수법과 공개 위협 정보를 바탕으로 위험 가능성을 알려주는 보조 도구예요. 모든 악성 사이트를 탐지할 수는 없으며, \"안전\" 등급도 위험이 없음을 보장하지 않아요. 접속 후 로그인·결제·앱 설치를 요구하면 다시 한 번 확인하세요.")
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.surface.ignoresSafeArea())
        .navigationTitle("앱 정보")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                policy("계정과 서버가 없어요", "QR Guard는 로그인이 없고 자체 서버도 운영하지 않아요. 스캔 기록은 이 기기 안에만 저장되며, 설정에서 보관 기간을 고르거나 저장을 끌 수 있어요.")
                policy("무엇이 어디로 전송되나요", "• 실제 도착 주소 확인: 스캔한 주소의 서버에 쿠키·캐시 없이 HEAD/GET 요청을 보내요. 상대 서버는 접속 사실을 알 수 있어요.\n• 악성 사이트 조회: Google Safe Browsing에 주소 원문이 아닌 해시의 앞 4바이트만 보내요.\n• 도메인 생성일: RDAP(rdap.org)에 도메인 이름을 보내요.\n• 페이지 미리 검사(기본 꺼짐): 최종 주소에서 HTML 앞부분 최대 256KB를 받아요. 자바스크립트는 실행하지 않아요.\n• URLhaus 조회(기본 꺼짐): abuse.ch에 주소 원문을 보내요.")
                policy("앱이 하지 않는 일", "스캔한 주소를 자동으로 열거나 웹뷰로 렌더링하지 않아요. 사용자가 결과 화면에서 직접 열기를 선택했을 때만 Safari 등 외부 앱으로 넘겨요.")
                policy("카메라", "카메라는 QR 코드를 인식하는 데만 사용하고, 영상은 저장하거나 전송하지 않아요.")
                policy("수집하는 데이터", "앱은 사용자 데이터를 수집하지 않아요. 분석·광고 SDK도 없어요. 설정값은 기기의 UserDefaults에 저장돼요.")
            }
            .padding(Spacing.l)
        }
        .background(Palette.surface.ignoresSafeArea())
        .navigationTitle("개인정보 처리방침")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func policy(_ title: LocalizedStringKey, _ body: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(title).font(.headline).foregroundStyle(Palette.ink)
            Text(body).font(.subheadline).foregroundStyle(Palette.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct LicensesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                license("QR Guard", "Apache License 2.0", "Copyright 2026 QR Guard contributors. 소스 코드와 문서는 Apache-2.0 라이선스로 배포돼요.")
                license("Public Suffix List", "Mozilla Public License 2.0", "https://publicsuffix.org/ — 등록 가능 도메인(eTLD+1) 계산에 사용해요.")
                license("Unicode Confusables (UTS #39)", "Unicode License v3", "유사 문자(호모글리프) 도메인 탐지에 Unicode 혼동 문자 데이터의 부분집합을 사용해요.")
                license("Google Safe Browsing", "서비스 약관", "런타임에 조회만 하며 데이터는 번들하지 않아요. 비상업적 용도 한정.")
                license("abuse.ch URLhaus", "CC0 / 서비스 약관", "사용자가 켠 경우에만 조회해요.")
            }
            .padding(Spacing.l)
        }
        .background(Palette.surface.ignoresSafeArea())
        .navigationTitle("오픈소스 라이선스")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func license(_ name: String, _ licenseName: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(name).font(.headline).foregroundStyle(Palette.ink)
            Text(licenseName).font(.caption.weight(.semibold)).foregroundStyle(Palette.brand)
            Text(note).font(.footnote).foregroundStyle(Palette.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

#Preview {
    NavigationStack { SettingsView() }
        .environment(PreviewSupport.appModel())
        .modelContainer(PreviewSupport.container)
}
