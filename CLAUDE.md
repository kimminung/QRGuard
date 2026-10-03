# CLAUDE.md — QR Guard 작업 규칙

이 파일은 Xcode에서 이 저장소를 다루는 Claude를 위한 안내서입니다. 작업을 시작하기 전에 끝까지 읽어 주세요.

## 프로젝트 한 줄 요약

QR 코드를 스캔하면 바로 열지 않고, 위험 요소를 분석해 **안전 / 주의 / 위험**으로 알려준 뒤 사용자가 접속 여부를 결정하게 하는 iOS 앱(SwiftUI, iOS 18+, Swift 6).

## 현재 상태 (2026-10-04)

- MVP(Phase 0–5) 구현 완료. 저장소는 `~/Desktop/QRGuard`, Xcode 프로젝트 `QRGuard.xcodeproj`, 타깃·스킴 `QRGuard`, 번들 `com.coulson.QRGuard`, iOS 18.0+, Swift 6 + 기본 MainActor 격리.
- 앱 코드는 `QRGuard/`(파일 시스템 동기화 그룹 — 폴더에 파일을 넣으면 자동 포함), 엔진·네트워크는 `Packages/QRGuardKit/`(Swift 6 언어 모드, UIKit 없음).
- 테스트: `cd Packages/QRGuardKit && swift test` (Core 124 · Network 66). 앱 빌드: `xcodebuild -project QRGuard.xcodeproj -scheme QRGuard -destination 'generic/platform=iOS Simulator' build`.
- 폴더 이름을 바꾸면 `INFOPLIST_FILE`(현재 `QRGuard/Info.plist`)도 함께 바꿔야 한다. 2026-10-04 실기기 빌드 실패 원인이 옛 경로 `MyApp/Info.plist`였다.
- 함정: Xcode의 빌드 설정/Info.plist 도구는 `project.pbxproj`를 재저장하면서 외부에서 넣은 패키지 참조(`C05A…` ID)를 지울 수 있다. 설정을 바꾼 뒤에는 `packageReferences`/`baseConfigurationReference`가 남아 있는지 확인한다.
- 시뮬레이터에는 카메라가 없어 스캐너 화면이 샘플 QR 버튼으로 대체된다. 런치 인자 `-UITestPayload <문자열>`로 분석 화면에 바로 진입할 수 있다.
- `UIColor { trait in … }` 같은 동적 공급 클로저는 렌더러가 메인 스레드 밖에서 부르므로 `nonisolated`로 둔다(실제 크래시 사례).

## 읽는 순서

1. `docs/TASKS.md` — 지금 할 일. 체크되지 않은 가장 위의 태스크 하나만 진행
2. `docs/TECH_PRD.md` — 아키텍처, 타입 계약, UI/UX 명세
3. `docs/RISK_RULES.md` — 위험 판정 규칙·가중치·문구 (단일 진실 공급원)
4. `docs/assets/screens/*.png` — 재구성한 화면 목업 (구조 참고용, 픽셀 일치는 요구하지 않음)
5. `docs/assets/reference/ui-draft.png` — 최초 UI 초안 (시각 언어 참고용)

## 반드시 지킬 것

- **스캔한 URL을 자동으로 열지 않는다.** `openURL`은 결과 화면에서 사용자의 명시적 탭(주의·위험은 추가 확인) 이후에만 호출한다.
- **스캔한 URL을 `WKWebView`로 렌더링하지 않는다.** 페이지 사전 검사는 HTML 앞부분을 텍스트로만 파싱한다.
- 규칙 ID·점수·floor를 바꾸려면 `RISK_RULES.md`와 `Tests/Fixtures/cases.json`을 **같은 커밋**에서 수정한다.
- 사용자에게 보이는 문자열은 전부 `Localizable.xcstrings`에. "안전합니다" 같은 단정 표현 금지(`TECH_PRD.md` 7.6).
- `QRGuardCore`는 UIKit/SwiftUI를 import하지 않는다.
- 외부 Swift 패키지를 추가하지 않는다. 꼭 필요하면 작업을 멈추고 이유와 대안을 먼저 제시한다.
- API 키·비밀값을 코드나 커밋에 넣지 않는다. `Config/Secrets.xcconfig`(gitignore)만 사용한다.
- 테스트 URL은 `example.com`, `*.test`, `*.invalid` 등 예약 도메인을 쓴다. 실존 서비스 주소로 공격 시나리오 픽스처를 만들지 않는다.
- 네트워크 요청은 `URLSessionConfiguration.ephemeral`만 사용하고, 설정 토글이 꺼진 검사는 어떤 요청도 보내지 않는다.

## 코드 스타일

- Swift 6 strict concurrency. 공유 상태는 `actor` 또는 `@MainActor`. `@unchecked Sendable` 금지.
- 뷰 모델은 `@Observable` 클래스, 뷰는 작게 쪼개고 `#Preview`를 붙인다(등급 3종 × Light/Dark).
- 규칙은 파일 하나에 하나: `Rules/U03_UserInfoAt.swift`. 타입 이름은 `UserInfoAtRule`.
- 에러는 사용자에게 무엇이 안 됐고 어떻게 하면 되는지 말하는 문구로 변환한다.
- 테스트는 Swift Testing(`@Test`, `#expect`). 규칙 테스트는 픽스처 기반 파라미터화.

## 작업 흐름

1. `TASKS.md`에서 태스크 하나를 고른다.
2. 테스트를 먼저 작성한다(엔진·네트워크 태스크).
3. 구현 → `⌘U` 전체 통과 → 수용 기준 자기 점검.
4. 체크박스를 `[x]`로 바꾸고 하단 "진행 기록"에 한 줄 남긴다.
5. 커밋 메시지: `[T-x.y] 요약` (사용자가 GitHub Desktop에서 커밋·푸시한다)

## 모호할 때

- 명세가 비어 있으면 더 보수적인 쪽(사용자를 덜 위험하게 하는 쪽)을 택하고, 결정 내용을 `TASKS.md` 진행 기록에 남긴다.
- 명세끼리 충돌하면 `RISK_RULES.md` > `TECH_PRD.md` > 목업 순으로 따른다.
