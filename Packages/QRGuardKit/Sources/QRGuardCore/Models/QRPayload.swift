import Foundation

/// QR 코드 내용의 분류 결과 (TECH_PRD 5.4).
public enum QRPayload: Sendable, Hashable, Codable {
    case url(URL)
    case wifi(WiFiConfig)                       // WIFI:T:WPA;S:ssid;P:pass;H:false;;
    case sms(number: String, body: String?)     // SMSTO:번호:본문 / sms:번호?body=
    case phone(String)                          // tel:
    case email(address: String, subject: String?, body: String?) // mailto: / MATMSG:
    case contact(raw: String)                   // vCard / MECARD
    case geo(latitude: Double, longitude: Double)
    case appScheme(URL)                         // kakaotalk://, itms-services:// …
    case payment(PaymentPayload)                // bitcoin:, ethereum:, 계좌 패턴
    case text(String, embeddedURLs: [URL])

    /// 저장·필터용 종류 식별자.
    public enum Kind: String, Codable, Sendable, CaseIterable, Hashable {
        case url, wifi, sms, phone, email, contact, geo, appScheme, payment, text
    }

    public var kind: Kind {
        switch self {
        case .url: return .url
        case .wifi: return .wifi
        case .sms: return .sms
        case .phone: return .phone
        case .email: return .email
        case .contact: return .contact
        case .geo: return .geo
        case .appScheme: return .appScheme
        case .payment: return .payment
        case .text: return .text
        }
    }

    /// 규칙 평가의 대상이 되는 대표 URL. 텍스트면 첫 번째 내장 URL.
    public var primaryURL: URL? {
        switch self {
        case .url(let url), .appScheme(let url): return url
        case .text(_, let urls): return urls.first
        case .payment(let p): return p.url
        case .sms(_, let body):
            return body.flatMap { PayloadParser.firstURL(in: $0) }
        default: return nil
        }
    }

    /// 결과·상세 화면에서 "열기" 대상이 되는지(URL 계열만).
    public var isOpenable: Bool {
        switch self {
        case .url, .appScheme: return true
        case .text(_, let urls): return !urls.isEmpty
        default: return false
        }
    }
}

public struct WiFiConfig: Sendable, Hashable, Codable {
    public enum Security: String, Sendable, Codable, Hashable {
        case wpa = "WPA"
        case wep = "WEP"
        case nopass = "nopass"
        case other
    }
    public var ssid: String
    public var security: Security
    public var password: String?
    public var isHidden: Bool

    public init(ssid: String, security: Security, password: String?, isHidden: Bool) {
        self.ssid = ssid
        self.security = security
        self.password = password
        self.isHidden = isHidden
    }
}

public struct PaymentPayload: Sendable, Hashable, Codable {
    public enum Scheme: String, Sendable, Codable, Hashable {
        case bitcoin, ethereum, litecoin, bankAccount, other
    }
    public var scheme: Scheme
    public var address: String
    public var amount: String?
    /// 원본이 URL 형태면 보존 (예: `bitcoin:addr?amount=1`)
    public var url: URL?

    public init(scheme: Scheme, address: String, amount: String?, url: URL?) {
        self.scheme = scheme
        self.address = address
        self.amount = amount
        self.url = url
    }
}
