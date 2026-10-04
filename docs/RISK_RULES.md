# QR Guard 위험 판정 규칙 명세 (Risk Rules Spec)

> 문서 버전 1.1 · 2026-10-04 · 대상: QR Guard 구현 담당(Xcode의 Claude 포함)
> 이 문서는 `QRGuardCore` 패키지의 `Rules/`와 `Scoring/` 구현의 **단일 진실 공급원(Single Source of Truth)** 입니다.
> 규칙 ID·가중치·문구를 바꾸면 이 문서와 테스트 픽스처(`Tests/Fixtures/cases.json`)를 함께 수정합니다.

---

## 1. 설계 원칙

1. **절대 자동 접속하지 않는다.** 스캔 결과는 항상 분석 → 결과 화면 → 사용자 결정 순서를 거친다.
2. **"안전"을 단정하지 않는다.** 점수가 낮아도 문구는 "알려진 위험 요소가 발견되지 않았어요"로 표현한다. 피싱 사이트는 수명이 매우 짧아(근거 S8) 어떤 평판 DB도 완벽하지 않기 때문이다.
3. **여러 약한 신호의 합 + 소수의 강한 확정 신호.** 개별 휴리스틱은 가산점, 블록리스트 적중·iOS 위험 페이로드 같은 확정 신호는 **최저 점수(floor)** 로 처리한다.
4. **설명 가능해야 한다.** 모든 점수는 사용자에게 보이는 `RiskFinding`(제목·설명·권장 행동·근거 출처)으로 환원되어야 한다.
5. **오프라인 우선, 온라인은 보강.** 네트워크 없이도 규칙의 대부분(U/B/P/V/C 계열)이 동작하고, 온라인 검사(R/T/D/H 계열)는 설정에서 끌 수 있다.
6. **확인 범위(Coverage)를 함께 보여준다.** 온라인 검사를 건너뛰었거나 시간 초과가 나면 결과 화면에 "확인 범위가 제한적이에요" 배지를 표시한다.

---

## 2. 점수 산정

```
rawScore   = Σ points(triggered findings)          // 같은 규칙은 1회만 가산
floored    = max(rawScore, max(floor(triggered)))  // 확정 신호의 최저 점수
adjusted   = floored + allowlistAdjustment         // B03 공식 도메인 확인 시 -20 (단, T01 적중 시 미적용)
score      = clamp(adjusted, 0, 100)
```

| 등급 | 점수 | 결과 화면 제목 | 기본 행동 |
|---|---|---|---|
| 안전 `safe` | 0–29 | 알려진 위험 요소가 발견되지 않았어요 | 사이트 열기 |
| 주의 `caution` | 30–69 | 접속 전에 확인이 필요해요 | 체크리스트 확인 후 열기 |
| 위험 `danger` | 70–100 | 접속하지 않는 것을 권장해요 | 열지 않고 닫기 (열기는 2단계 확인) |
| 차단 `blocked` | 등급은 위험, `blocksOpening = true` | 이 코드는 열 수 없어요 | 열기 버튼 자체를 숨김 |

- 점수는 **위험 점수**다. 높을수록 위험하다. UI에서 반드시 "위험 점수"라고 라벨링한다.
- 같은 카테고리에서 여러 규칙이 겹칠 때 과대평가를 막기 위해 카테고리 상한을 둔다: `U` 계열 합계 최대 45, `H` 계열 합계 최대 40, `C` 계열 합계 최대 30, `V` 계열 합계 최대 25.

### 2.1 계산 예시 (목업 화면과 동일)

| 사례 | 발동 규칙 | 계산 | 결과 |
|---|---|---|---|
| `https://www.naver.com/` | B03 | 0 − 20 → clamp | **0 · 안전** |
| `https://bit.ly/3gH2kQ` → `event-gift.site/coupon` | U11 +10, U08 +10, D01 +25 (R02는 처음이 단축 URL이라 제외) | 45 | **45 · 주의** |
| `https://t.ly/Ab3dE` → `naver-login.account-check.xyz/verify` (메일로 받음) | T01 floor 90, B01 +30, H01 +15, C02 +15, U08 +10, U10 +10, U11 +10 | max(90, 90) | **90 · 위험** |
| `itms-services://?action=download-manifest&url=…` | P02 floor 95 | 95, 열기 차단 | **95 · 위험(차단)** |

---

## 3. 규칙 카탈로그

열 설명: **단계** = 실행 시점(`offline`/`online`), **점수** = 가산점, **floor** = 최저 점수, **근거** = 7장의 출처 ID.

### 3.1 P — 페이로드 유형 (offline)

QR에는 웹 주소 말고도 다양한 데이터가 들어갈 수 있다. iOS에서 특히 위험한 형태를 먼저 걸러낸다.

| ID | 조건 | 점수 | floor | 근거 | 사용자 문구(제목) |
|---|---|---|---|---|---|
| P01 | 스킴이 `javascript:`, `data:`, `file:`, `blob:` | — | 95 · **열기 차단** | 일반 보안 원칙 | 웹 주소가 아닌 실행 코드가 들어 있어요 |
| P02 | 스킴이 `itms-services:` (기업용 앱 직접 설치) | — | 95 · **열기 차단** | S1, S2, S3 | 앱스토어를 거치지 않는 앱 설치 링크예요 |
| P03 | 경로가 `.mobileconfig`로 끝나거나 응답 Content-Type이 `application/x-apple-aspen-config` | — | 85 | S1, S3 | 기기 설정을 바꾸는 프로파일 설치 파일이에요 |
| P04 | 경로 확장자가 `.apk .ipa .exe .msi .dmg .pkg` 또는 응답이 해당 파일 | — | 75 | S1, S2, S3 | 앱·프로그램 설치 파일을 내려받아요 |
| P05 | 알 수 없는 앱 스킴(`foo://`) | +20 | — | S2 | 다른 앱을 바로 실행하는 링크예요 |
| P05a | 알려진 앱 스킴(`kakaotalk:`, `supertoss:` 등, `data/app_schemes.json`) | +5 | — | — | ○○ 앱을 실행하는 링크예요 |
| P06 | Wi-Fi 설정 QR이 `nopass` 또는 `WEP` | +30 | — | 일반 보안 원칙 | 암호화되지 않은 와이파이에 연결해요 |
| P07 | `sms:`/`smsto:`/`SMSTO:` 본문에 URL 포함 | +25 | — | S5 | 문자 본문에 링크가 미리 들어 있어요 |
| P08 | 수신 번호가 국내 유료 정보서비스 번호(`060` 시작) | +30 | — | 일반 소비자 보호 | 유료 전화번호로 연결돼요 |
| P09 | 송금·결제 페이로드(`bitcoin:`, `ethereum:`, 계좌번호 패턴 등) | — | 40 | S9 | 돈을 보내는 정보가 들어 있어요 |
| P10 | 일반 텍스트 안에 URL 포함 | URL 추출 후 전체 규칙 재적용 | — | — | 글 속에 링크가 들어 있어요 |

> P01/P02는 `blocksOpening = true`. 결과 화면에서 "열기" 계열 버튼을 렌더링하지 않는다. 원문 복사만 허용한다.

### 3.2 U — URL 구조 (offline, 카테고리 상한 45)

| ID | 조건 | 점수 | 근거 | 사용자 문구(제목) |
|---|---|---|---|---|
| U01 | `http://` (HTTPS 아님) | +15 | S4, S5 | 암호화되지 않은 연결이에요 |
| U02 | 호스트가 IP 주소(IPv4/IPv6) | +20 | 일반 피싱 지표 | 도메인 대신 숫자 주소를 써요 |
| U03 | authority에 `@`(userinfo) 포함 — `https://naver.com@evil.example` | +25 | S3 | 주소 앞부분이 진짜 목적지를 가리고 있어요 |
| U04 | 비표준 포트(80/443 외) | +10 | 일반 피싱 지표 | 일반적이지 않은 포트를 써요 |
| U05 | IDN(퓨니코드 `xn--`) + 혼합 문자 체계(예: 라틴+키릴) | +15 | S3, S7 | 비슷하게 보이는 다른 나라 문자가 섞여 있어요 |
| U06 | eTLD+1 앞 서브도메인 4단계 이상 또는 호스트 길이 > 50 | +5 | 일반 피싱 지표 | 주소가 지나치게 길고 복잡해요 |
| U07 | URL 길이 > 200 또는 퍼센트 인코딩 비율 > 15% 또는 이중 인코딩 | +5 | S7 | 주소 일부가 알아보기 어렵게 감춰져 있어요 |
| U08 | 피싱 집중 TLD(`data/suspicious_tlds.json`, 정기 갱신) | +10 | 위협 통계 기반 | 악용이 잦은 도메인 확장자예요 |
| U09 | 쿼리 파라미터(`url, redirect, next, goto, target, dest, r, u, link, return`)에 **다른 eTLD+1** 주소가 들어 있음 | +15 | S7 | 믿을 만한 사이트를 거쳐 다른 곳으로 보내요 |
| U10 | 호스트/경로에 미끼 키워드(`login, signin, verify, account, update, secure, wallet, 인증, 본인확인, 환급, 과태료, 택배, 배송, 대출`) — 1회만 | +10 | S3, S5 | 로그인·인증을 요구하는 주소 형태예요 |
| U11 | 단축 URL·동적 QR 서비스 도메인(`data/shorteners.json`) | +10 | S10 | 실제 주소를 가리는 단축 주소예요 |

### 3.3 B — 브랜드 사칭 (offline)

`data/brands.json`에 브랜드별 공식 등록 도메인(eTLD+1)과 키워드를 둔다. 예시(출시 전 각 기관 공식 도메인 재검증 필수):

```json
[
  { "brand": "네이버", "keywords": ["naver"], "domains": ["naver.com"] },
  { "brand": "카카오", "keywords": ["kakao"], "domains": ["kakao.com", "kakaocorp.com"] },
  { "brand": "토스", "keywords": ["toss"], "domains": ["toss.im"] },
  { "brand": "쿠팡", "keywords": ["coupang"], "domains": ["coupang.com"] },
  { "brand": "KB국민은행", "keywords": ["kbstar", "kbbank"], "domains": ["kbstar.com"] },
  { "brand": "정부·공공기관", "keywords": ["gov", "hometax", "epost", "police"], "suffixes": ["go.kr", "gov.kr"] },
  { "brand": "서울자전거 따릉이", "keywords": ["bikeseoul", "ddareungi"], "domains": ["bikeseoul.com"] }
]
```

| ID | 조건 | 점수 | 근거 | 사용자 문구(제목) |
|---|---|---|---|---|
| B01 | 호스트 라벨 또는 경로에 브랜드 키워드가 있지만 eTLD+1이 그 브랜드의 공식 도메인이 아님 — `naver-login.account-check.xyz` | +30 | S1, S3 | ○○을(를) 사칭하는 주소일 수 있어요 |
| B02 | eTLD+1이 공식 도메인과 **비슷하지만 다름**: 편집 거리 ≤ 2, 또는 UTS #39 confusable skeleton 일치 — `naverr.com`, `navеr.com`(키릴 е) | +35 | S3, S5 | 공식 주소와 한두 글자만 달라요 |
| B03 | 최종 eTLD+1이 공식 도메인 목록에 있고, HTTPS이며, 리다이렉트가 공식 도메인 밖으로 나가지 않음 | **−20** | — | 공식 도메인으로 확인됐어요 (통과 항목) |

> B03은 T01(블록리스트 적중)과 함께 발생하면 적용하지 않는다. 공식 도메인 안의 오픈 리다이렉트(S7)가 악용될 수 있으므로 **U09가 함께 발생하면 B03을 적용하지 않는다.**

### 3.4 R — 리다이렉트 (online · `RedirectResolver`)

| ID | 조건 | 점수 | 근거 | 사용자 문구(제목) |
|---|---|---|---|---|
| R01 | 리다이렉트 3–5회 (+10), 6회 이상 (+20) | +10 / +20 | S7 | 여러 번 다른 주소를 거쳐 가요 |
| R02 | 최종 eTLD+1 ≠ 처음 eTLD+1 (처음이 단축 URL이면 제외) | +10 | S7 | 처음 보인 주소와 실제 도착 주소가 달라요 |
| R03 | 체인 중 HTTPS → HTTP 다운그레이드 | +15 | S4 | 중간에 암호화되지 않은 연결로 바뀌어요 |
| R04 | 단축 URL인데 최종 목적지를 확인하지 못함(시간 초과·오류) | +15 | S10 | 단축 주소의 실제 목적지를 확인하지 못했어요 |
| R05 | HTML의 `<meta http-equiv="refresh">` 또는 단순 `location` 할당 발견 → 대상 1단계 추가 추적 | +10 | S7 | 페이지가 열리자마자 다른 곳으로 보내요 |

### 3.5 T — 평판·위협 정보 (online)

| ID | 조건 | 점수 | floor | 근거 | 사용자 문구(제목) |
|---|---|---|---|---|---|
| T01 | 처음/중간/최종 URL 중 하나라도 위협 DB 적중: Google Safe Browsing v5, URLhaus(선택), 로컬 블록리스트(번들·업데이트) | — | 90 | S8 | 악성 사이트 데이터베이스에서 발견됐어요 |

### 3.6 D — 도메인 정보 (online · RDAP)

| ID | 조건 | 점수 | 근거 | 사용자 문구(제목) |
|---|---|---|---|---|
| D01 | 등록일로부터 30일 미만 | +25 | S8 | 생긴 지 한 달도 안 된 도메인이에요 |
| D02 | 30–180일 | +10 | S8 | 비교적 최근에 만들어진 도메인이에요 |
| D03 | RDAP 조회 불가(예: 일부 ccTLD) | 0 · coverage=`partial` | — | 도메인 생성일을 확인하지 못했어요 (정보) |

### 3.7 H — 페이지 사전 검사 (online · 선택 기능, 카테고리 상한 40)

최종 URL의 HTML **앞부분 최대 256KB만** 쿠키 없이 내려받아 정적으로 파싱한다. 자바스크립트는 실행하지 않는다.

| ID | 조건 | 점수 | 근거 | 사용자 문구(제목) |
|---|---|---|---|---|
| H01 | `<input type="password">` 존재 (B03 통과 도메인 제외) | +15 | S6, S1 | 비밀번호를 입력받는 페이지예요 |
| H02 | `<form action>`이 다른 eTLD+1로 전송 | +20 | S6 | 입력한 정보가 다른 사이트로 전송돼요 |
| H03 | `<title>`·로고 alt·본문 상단에 브랜드명이 있는데 공식 도메인이 아님 | +20 | S1, S3 | 페이지가 ○○처럼 꾸며져 있어요 |
| H05 | TLS 인증서 검증 실패 | +30 | 일반 보안 원칙 | 사이트 보안 인증서에 문제가 있어요 |

### 3.8 C — 스캔 상황(맥락) (offline, 카테고리 상한 30)

사용자가 분석 중 화면에서 선택한 "어디서 찍었나요?" 칩과 스캔 메타데이터를 쓴다. 선택하지 않으면 C02·C03은 평가하지 않는다.

| ID | 조건 | 점수 | 근거 | 사용자 문구(제목) |
|---|---|---|---|---|
| C01 | 한 프레임/사진에서 **서로 다른 내용의 QR 2개 이상** 감지 | +20 | S2, S5, S6 | QR 코드가 겹쳐 붙어 있을 수 있어요 |
| C02 | 출처=이메일·문자·메신저 **그리고** (U10 또는 P04 또는 H01) | +15 | S1, S4, S5 | 메일·문자로 받은 QR이 로그인·설치를 요구해요 |
| C03 | 출처=주차·결제 또는 킥보드·자전거 **그리고** eTLD+1이 `data/payment_mobility.json`에 없음 | +15 | S2, S5, S9 | 결제·대여용 QR치고 낯선 주소예요 |

### 3.9 V — 비전·입력 정제 (offline, 카테고리 상한 25)

`docs/AI_ONDEVICE_DEFENSE.md` 4.2(T-8.1)에서 옮겨 온 **결정적** 신호다. AI 모델 없이 모든 기기에서 동작한다.
입력은 스캐너·공유 확장이 채우는 `AnalysisSnapshot.vision`(`VisionSignals`)과 페이지 사전 검사의 `hiddenText`·`invisibleCharacterCount`, QR 원문이다.
V 계열은 **floor가 없고 점수를 올릴 수만 있다**(불변식: 단방향 래칫·확정 판정 금지). V01–V03은 `vision`이 nil이면 평가하지 않는다. V09는 URL 또는 페이지 데이터가 있을 때만 평가한다.

| ID | 조건 | 점수 | 근거 | 사용자 문구(제목) |
|---|---|---|---|---|
| V01 | 단독 디코딩 실패 → 인접 이미지 결합 후 디코딩 성공(`decodedFromCombinedImages`), **또는** 파인더 패턴 추정 수 > 디코딩된 코드 수 + 2(조각 존재 의심) — 근거 `{finders}`·`{decoded}` | +15 | S11 | 둘로 나뉜 QR 코드일 수 있어요 |
| V02 | 원본·0.5배·2배 배율, 사분면·중앙 크롭 디코딩 결과 **서로 다른 eTLD+1 ≥ 2**(`nestedDistinctSites`, 대소문자·공백 정리 후 중복 제거) — 근거 `{sites}`·`{count}` | +20 | S11 | 한 이미지에 서로 다른 곳으로 가는 QR이 겹쳐 있어요 |
| V03 | 문자·CSS로 그린 QR(블록 문자 격자)을 렌더링한 뒤 디코딩함(`decodedFromTextArt`) | +10 | S11 | 문자로 그린 QR 코드예요 |
| V09 | 셋 중 가장 높은 것 하나: ① 페이지 숨김 텍스트(`display:none`·`visibility:hidden`·`font-size:0`·`opacity:0`·`aria-hidden`·`hidden`·화면 밖 배치)에 분석 도구를 겨냥한 지시문 패턴(`InputSanitizer.detectsInjection`, 영어·한국어) **+15** ② 페이지 HTML의 불가시 문자(`Cf`·BOM·U+202E 등) ≥ 3 **+10** ③ QR 원문의 불가시 문자 ≥ 3 **+10** — 근거 `{count}`·`{snippet}` | +10 / +15 | 일반 보안 원칙 (AI_ONDEVICE_DEFENSE 5장) | 탐지를 피하려는 숨김 문자·문구가 있어요 |

> V01+V02+V03이 모두 발동해도 합계는 25로 묶인다(45 → 25). V 계열만으로는 "주의"(30)에 도달하지 못하며, 다른 계열 점수에 더해져서만 등급을 올린다.
> `InputSanitizer`(`Text/InputSanitizer.swift`)는 불가시 문자 제거·양방향 제어 문자 플래그·NFKC·호환 자모 재조합(`ㅂㅏㄴ` → `반`)을 수행한다. 지시문 탐지는 정제 후 적용하므로 불가시 문자로 쪼개거나 전각으로 쓴 지시문도 잡는다.

---

## 4. 결과 객체 계약

```swift
public struct RiskReport: Codable, Sendable, Hashable {
    public let score: Int                 // 0...100, 위험 점수
    public let tier: RiskTier             // .safe / .caution / .danger
    public let blocksOpening: Bool        // P01, P02
    public let findings: [RiskFinding]    // 점수 내림차순
    public let passedChecks: [CheckID]    // "통과한 검사" 목록
    public let originalURL: URL?
    public let finalURL: URL?
    public let redirectChain: [RedirectHop]
    public let domain: DomainInfo?        // eTLD+1, IDN 원문/퓨니코드, 등록일
    public let coverage: AnalysisCoverage // .full / .offlineOnly / .partial([CheckID])
    public let analyzedAt: Date
}

public struct RiskFinding: Codable, Sendable, Hashable, Identifiable {
    public let id: RuleID                 // "U03"
    public let points: Int
    public let floor: Int?
    public let titleKey: String           // Localizable.xcstrings 키 "rule.U03.title"
    public let detailKey: String          // "rule.U03.detail"
    public let adviceKey: String          // "rule.U03.advice"
    public let evidence: [String: String] // 화면 표시용 근거값 예: ["hidden_host": "evil.example"]
    public let sources: [SourceID]        // ["S3"]
}
```

## 5. 사용자 문구 예시 (`rule.<ID>.detail` / `.advice`)

| ID | 설명(detail) | 권장 행동(advice) |
|---|---|---|
| U03 | 주소의 `@` 앞부분은 무시되고, 실제로는 `@` 뒤의 {hidden_host}로 접속해요. | 보이는 이름이 아니라 {hidden_host}가 맞는지 확인하세요. |
| B02 | {domain}은(는) 공식 주소 {official}과(와) 한두 글자만 달라요. | 공식 앱이나 검색으로 직접 찾아 들어가세요. |
| C01 | 한 화면에서 서로 다른 QR 코드가 {count}개 보였어요. 진짜 코드 위에 스티커를 덧붙이는 수법이 알려져 있어요. | QR 코드 주변을 손으로 만져 덧붙인 흔적이 없는지 확인하세요. |
| P02 | 앱스토어 심사를 거치지 않은 앱을 설치하게 하는 링크예요. | 설치하지 마세요. 필요한 앱은 App Store에서 직접 검색하세요. |
| H01 | 이 페이지는 비밀번호를 입력받아요. QR로 연결된 로그인 요구는 대표적인 피싱 신호예요. | 로그인이 꼭 필요하면 공식 앱이나 즐겨찾기로 접속하세요. |

## 6. 테스트 픽스처 규약

- 테스트 URL은 **실존 서비스를 공격 대상으로 만들지 않도록** RFC 2606/6761 예약 도메인(`example.com`, `*.test`, `*.invalid`)과 가상의 TLD 조합을 우선 사용한다. 브랜드 사칭 규칙 테스트에 한해 `naver-login.account-check.test` 같은 가상 호스트를 쓴다.
- `Tests/Fixtures/cases.json` 형식:

```json
{ "input": "https://naver.com@login.example.test/verify",
  "context": { "source": "camera", "place": "emailOrMessage" },
  "expect": { "rules": ["U03", "U10", "C02"], "tierAtLeast": "caution" } }
```

- 최소 60개 케이스: 규칙별 양성 2개 + 음성 1개, 등급 경계(29/30, 69/70) 케이스, 공식 도메인 + 오픈 리다이렉트 조합 케이스 포함.

---

## 7. 근거 출처 (Evidence)

수법과 예방수칙은 아래 공개 자료에서 확인한 내용을 규칙으로 옮겼다. 앱 내 "근거" 표시는 출처 ID와 기관명만 노출한다.

| ID | 출처 | 규칙에 반영한 내용(요약) |
|---|---|---|
| S1 | 한국인터넷진흥원(KISA) 큐싱 공격 경고, 뉴시스 2026-01-13 | 기관·싱크탱크 사칭 후 QR 촬영 유도 → 악성 앱 설치 또는 정상 사이트를 흉내 낸 SNS 로그인 페이지. 의심 시 보호나라 카카오톡 채널의 큐싱 확인 서비스 이용, 감염 의심 시 백신 점검·인증서 재발급·결제 내역 확인 권고 |
| S2 | 관계부처 합동 큐싱 주의 당부, 뉴시스 2024-10-23 | 공유 킥보드 정상 QR 위 스티커 덧붙이기, 광고·메일 속 QR로 "안전거래 앱" 설치 유도 |
| S3 | SBS Biz 2024-02-19 (신용보증재단중앙회 사례, 경찰청 절차) | 저금리 대출 안내 메일 QR → 악성 앱 설치 → 1천만 원대 피해. 철자 한 글자를 바꾼 주소, 접속 후 개인정보 입력·앱 설치 금지 |
| S4 | 보안뉴스, KISA 큐싱 예방수칙 기반 정리 | 정상 기관은 이메일·문자로 QR 인증을 요구하지 않음, 연결 URL 확인, 덧붙인 코드 확인 |
| S5 | 미국 FTC 소비자 경보(언론 보도 다수) | 주차 미터기 QR 덮어씌우기, 계정 문제·택배 재배송을 핑계로 한 문자·메일 QR, URL 오타·글자 바꿔치기 확인 |
| S6 | 미국 FBI 권고(언론·금융사 보안 안내 인용) | QR 스캔 후 로그인 정보를 요구하면 의심, 조작된 흔적이 있는 코드 스캔 금지 |
| S7 | Perception Point, Cyber Defense Magazine 2024-02 | 정상 클라우드 서비스의 오픈 리다이렉트를 연쇄로 거쳐 가짜 Microsoft 365 로그인 페이지로 보내는 큐싱 캠페인 |
| S8 | Google Safe Browsing v5 개발자 문서 | 로컬 DB 갱신 지연이 보호 누락의 주원인, 공격 사이트 상당수가 10분 미만 운영 → 실시간 조회 필요. API는 비상업적 용도 한정 |
| S9 | KB Think 해외결제 사기 안내 | 가짜 QR로 가게가 아닌 다른 계좌 송금 유도, 가짜 주차 위반 딱지 QR |
| S10 | CaptainDNS, URL 단축기와 피싱(2025) | 단축 URL은 302 리다이렉트로 실제 목적지를 숨김, 피싱 캠페인에서 단축기 악용 빈번 |
| S11 | Barracuda Threat Spotlight 2025-08, *Split and nested QR codes in quishing attacks* ([링크](https://blog.barracuda.com/2025/08/20/threat-spotlight-split-nested-qr-codes-quishing-attacks)) | 피싱 키트가 QR을 두 이미지로 나눠 첨부(분할 QR), 정상 QR 둘레를 악성 QR로 감쌈(중첩 QR), 문자·CSS로 QR을 그림(ASCII QR) → V01–V03 |

> 출처 링크는 `README.md`의 "참고 자료" 절에 모아 둔다. 정책·통계는 바뀔 수 있으므로 릴리스마다 재확인한다.
