# security-data 도구 (T-6.3 · T-6.4)

QR Guard가 번들로 들고 있는 보안 데이터(brands · shorteners · suspicious_tlds · app_schemes · payment_mobility ·
blocklist · bait_keywords)를 **앱 업데이트 없이** 갱신하기 위한 발행 도구입니다.

- 앱은 `SecurityDataURL`(Info.plist, 빌드 설정 `SECURITY_DATA_URL`)에서 `security-data.json`과 `security-data.json.sig`를
  하루 1회 받습니다. Ed25519 서명이 번들 공개키(`Packages/QRGuardKit/Sources/QRGuardCore/Resources/security_data_pubkey.txt`)로
  검증되지 않으면 **절대 적용하지 않습니다**. 스키마 버전이 다르거나 `sequence`가 이미 적용된 값 이하여도 거부합니다(롤백 방지).
- `confusables_subset.txt`·`public_suffix_list.dat`는 알고리즘과 함께 바뀌어야 하므로 원격 갱신 대상이 아닙니다.
- 검증된 바이트만 `Application Support/SecurityData/security-data.json`에 저장되고, 앱 시작 시
  `DataStore.loadApplyingCachedUpdate()`가 서명을 **다시** 확인한 뒤 `RiskEngine`에 넘깁니다.

## 파일

| 파일 | 역할 |
|---|---|
| `sign.py` | Ed25519 `keygen` / `sign` / `verify` (Python 3 + `cryptography`) |
| `sign.swift` | 같은 기능, 의존성 없는 macOS용 (`swift sign.swift …`) |
| `make_bundle.py` | 리소스 JSON들을 모아 `security-data.json` 생성(`sequence` 증가) |
| `merge_blocklist.py` | 외부 피싱 URL 내보내기(CSV/JSON)를 `blocklist.json` 형태로 정규화·병합 (T-6.4) |
| `TEST_PRIVATE_KEY.txt` | **테스트용** 개인키. 테스트 픽스처 재생성용이며 출시 전 반드시 교체 |

## 발행 절차

```sh
# 0) (최초 1회) 키 생성 — 개인키는 저장소 밖(CI secret·Keychain)에 보관
python3 tools/security-data/sign.py keygen --out-private ~/secrets/qrguard-secdata.key --out-public /tmp/pub.txt
cp /tmp/pub.txt Packages/QRGuardKit/Sources/QRGuardCore/Resources/security_data_pubkey.txt   # 앱 빌드에 포함

# 1) 묶음 생성 (직전 발행본을 넘기면 sequence가 +1 된다)
python3 tools/security-data/make_bundle.py --out dist/security-data.json --previous dist/prev/security-data.json

# 2) 서명 — JSON 바이트를 그대로 서명하므로 서명 후 파일을 다시 포맷하면 안 된다
python3 tools/security-data/sign.py sign --key ~/secrets/qrguard-secdata.key --in dist/security-data.json
python3 tools/security-data/sign.py verify --pub Packages/QRGuardKit/Sources/QRGuardCore/Resources/security_data_pubkey.txt --in dist/security-data.json

# 3) dist/security-data.json 과 dist/security-data.json.sig 를 같은 디렉터리에 정적 호스팅(GitHub Releases 등)
#    SECURITY_DATA_URL 은 security-data.json 의 https URL. .sig 는 같은 URL 뒤에 ".sig"를 붙여 받는다.
```

macOS에서 Python `cryptography`가 없으면 `swift tools/security-data/sign.swift keygen|sign|verify …`를 쓰면 됩니다
(샌드박스에서 `CryptoKit` 모듈을 못 찾으면 `swiftc -module-cache-path /tmp/mc -o /tmp/sign tools/security-data/sign.swift`로 먼저 컴파일).

## 묶음 형식 (`schemaVersion` 1)

```json
{
  "schemaVersion": 1,
  "publishedAt": "2026-10-04T00:00:00Z",
  "sequence": 3,
  "brands": [ { "brand": "…", "keywords": ["…"], "domains": ["…"], "suffixes": ["…"] } ],
  "shorteners": ["bit.ly"],
  "suspiciousTLDs": ["xyz"],
  "appSchemes": [ { "scheme": "kakaotalk", "app": "카카오톡" } ],
  "paymentMobility": ["kakaopay.com"],
  "blocklist": { "domains": [], "hosts": [], "urlPrefixes": [], "source": "…", "updatedAt": "2026-10-04" },
  "baitKeywords": ["login"]
}
```

모든 데이터 항목은 선택입니다. 빠진 항목은 번들 데이터가 유지되고, 들어 있는 항목은 **통째로 교체**됩니다
(병합이 아님 — 번들 목록에 더하려면 `make_bundle.py`처럼 전체 목록을 담아 발행).

## 테스트 키·픽스처

- `TEST_PRIVATE_KEY.txt`의 공개키가 현재 `security_data_pubkey.txt`에 들어 있습니다. **출시 전에 새 키로 교체**하세요.
- `Packages/QRGuardKit/Tests/QRGuardNetworkTests/Fixtures/security-data.json(.sig)`는 이 테스트 키로 서명되어 있고,
  `security-data-tampered.json`은 한 글자를 바꾼 사본(서명 불일치 테스트용)입니다. 키를 바꾸면 픽스처를 다시 서명하세요:

```sh
swift tools/security-data/sign.swift sign --key tools/security-data/TEST_PRIVATE_KEY.txt \
  --in Packages/QRGuardKit/Tests/QRGuardNetworkTests/Fixtures/security-data.json
cp Packages/QRGuardKit/Tests/QRGuardNetworkTests/Fixtures/security-data.json.sig \
   Packages/QRGuardKit/Tests/QRGuardNetworkTests/Fixtures/security-data-tampered.json.sig
```

## T-6.4 국내 피싱 URL 데이터 병합 (`merge_blocklist.py`)

```sh
python3 tools/security-data/merge_blocklist.py --input export.csv --column url --mode host \
  --base Packages/QRGuardKit/Sources/QRGuardCore/Resources/blocklist.json \
  --source "KISA 피싱사이트 URL (공공데이터포털), 2026-10 내보내기" \
  --out /tmp/blocklist.merged.json
```

- 스크립트는 **아무것도 내려받지 않습니다.** 데이터셋은 직접 내려받아 넘기세요.
- 정규화: 소문자, 스킴·사용자정보·포트·경로 제거(host/domain 모드), IDN→punycode, 중복 제거,
  예약·로컬 도메인(`*.test`, `*.example`, `localhost`, 사설 IP 등)은 경고 후 제외.
- 결과는 `blocklist.json`과 같은 형태이며 `source`·`updatedAt` 메타가 기록됩니다(T-6.4 수용 기준).
  검토 후 번들 `blocklist.json`을 교체하거나 `make_bundle.py`로 원격 묶음에 담아 발행합니다.

> **확인 필요:** KISA / 공공데이터포털(data.go.kr)의 피싱 사이트 URL 데이터셋은 제공 형식(CSV·API·컬럼명)과
> 이용 조건(공공누리 유형, 출처 표시, 상업적 이용·재배포 가능 여부)을 이 저장소에서 검증하지 못했습니다.
> 실제 데이터를 병합·배포하기 전에 포털의 데이터 상세 페이지에서 직접 확인하고, 출처 표시 문구를 `--source`와
> 앱의 오픈소스/데이터 고지 화면에 반영하세요.
