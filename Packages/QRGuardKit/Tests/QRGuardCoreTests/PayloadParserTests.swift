import Foundation
import Testing
@testable import QRGuardCore

@Suite("PayloadParser (T-1.1)")
struct PayloadParserTests {
    @Test(arguments: ["https://example.com/path?q=1", "  HTTP://Example.COM/  ", "https://한국.test/경로"])
    func urlPayloads(_ raw: String) {
        let payload = PayloadParser.parse(raw)
        guard case .url(let url) = payload else { Issue.record("expected .url for \(raw), got \(payload)"); return }
        #expect(["http", "https"].contains(url.scheme?.lowercased()))
    }

    @Test func wifiWPA() {
        let payload = PayloadParser.parse("WIFI:T:WPA;S:MyCafe;P:secret123;H:true;;")
        guard case .wifi(let cfg) = payload else { Issue.record("expected .wifi"); return }
        #expect(cfg.ssid == "MyCafe")
        #expect(cfg.security == .wpa)
        #expect(cfg.password == "secret123")
        #expect(cfg.isHidden)
    }

    @Test func wifiEscapesAndNoPass() {
        let payload = PayloadParser.parse(#"WIFI:S:Cafe\;Free\:Wi\\Fi;T:nopass;;"#)
        guard case .wifi(let cfg) = payload else { Issue.record("expected .wifi"); return }
        #expect(cfg.ssid == #"Cafe;Free:Wi\Fi"#)
        #expect(cfg.security == .nopass)
        #expect(cfg.password == nil)
        #expect(!cfg.isHidden)
    }

    @Test func wifiEmptyTypeIsNoPassAndWEP() {
        if case .wifi(let a) = PayloadParser.parse("WIFI:S:Open;;") { #expect(a.security == .nopass) } else { Issue.record("expected .wifi") }
        if case .wifi(let b) = PayloadParser.parse("wifi:T:WEP;S:Old;P:abc;;") { #expect(b.security == .wep) } else { Issue.record("expected .wifi") }
        if case .wifi(let c) = PayloadParser.parse("WIFI:T:WPA2;S:Home;P:pw;;") { #expect(c.security == .wpa) } else { Issue.record("expected .wifi") }
    }

    @Test func smsFormats() {
        if case .sms(let n, let b) = PayloadParser.parse("SMSTO:01012345678:안녕하세요") {
            #expect(n == "01012345678"); #expect(b == "안녕하세요")
        } else { Issue.record("SMSTO") }
        if case .sms(let n, let b) = PayloadParser.parse("sms:+821012345678?body=hello%20world") {
            #expect(n == "+821012345678"); #expect(b == "hello world")
        } else { Issue.record("sms:?body") }
        if case .sms(let n, let b) = PayloadParser.parse("smsto:0601234567") {
            #expect(n == "0601234567"); #expect(b == nil)
        } else { Issue.record("smsto:") }
    }

    @Test func smsBodyURLBecomesPrimaryURL() {
        let payload = PayloadParser.parse("SMSTO:01000000000:확인 https://example.test/login")
        #expect(payload.kind == .sms)
        #expect(payload.primaryURL?.host() == "example.test")
    }

    @Test func phone() {
        if case .phone(let n) = PayloadParser.parse("tel:+82-2-1234-5678") { #expect(n == "+82-2-1234-5678") } else { Issue.record("tel") }
        if case .phone(let n) = PayloadParser.parse("TEL:0601234567") { #expect(n == "0601234567") } else { Issue.record("TEL") }
    }

    @Test func email() {
        if case .email(let a, let s, let b) = PayloadParser.parse("mailto:help@example.test?subject=Hi%20there&body=Hello") {
            #expect(a == "help@example.test"); #expect(s == "Hi there"); #expect(b == "Hello")
        } else { Issue.record("mailto") }
        if case .email(let a, let s, let b) = PayloadParser.parse("MATMSG:TO:a@example.test;SUB:제목;BODY:본문;;") {
            #expect(a == "a@example.test"); #expect(s == "제목"); #expect(b == "본문")
        } else { Issue.record("MATMSG") }
        if case .email(let a, _, _) = PayloadParser.parse("mailto:plain@example.test") { #expect(a == "plain@example.test") } else { Issue.record("mailto plain") }
    }

    @Test func contact() {
        #expect(PayloadParser.parse("BEGIN:VCARD\nVERSION:3.0\nFN:홍길동\nEND:VCARD").kind == .contact)
        #expect(PayloadParser.parse("MECARD:N:홍길동;TEL:01012345678;;").kind == .contact)
        #expect(PayloadParser.parse("begin:vcard\nend:vcard").kind == .contact)
    }

    @Test func geo() {
        if case .geo(let lat, let lon) = PayloadParser.parse("geo:37.5665,126.9780") { #expect(lat == 37.5665); #expect(lon == 126.978) } else { Issue.record("geo") }
        if case .geo(let lat, let lon) = PayloadParser.parse("GEO:-33.86,151.21,100?q=Sydney") { #expect(lat == -33.86); #expect(lon == 151.21) } else { Issue.record("geo alt") }
        #expect(PayloadParser.parse("geo:abc,def").kind == .text)
    }

    @Test func cryptoPayments() {
        if case .payment(let p) = PayloadParser.parse("bitcoin:1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa?amount=0.01&label=Shop") {
            #expect(p.scheme == .bitcoin); #expect(p.address == "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"); #expect(p.amount == "0.01"); #expect(p.url != nil)
        } else { Issue.record("bitcoin") }
        if case .payment(let p) = PayloadParser.parse("ethereum:0xAbC0000000000000000000000000000000000001@1?value=2e18") {
            #expect(p.scheme == .ethereum); #expect(p.address == "0xAbC0000000000000000000000000000000000001"); #expect(p.amount == "2e18")
        } else { Issue.record("ethereum") }
        if case .payment(let p) = PayloadParser.parse("litecoin:LTCaddress") { #expect(p.scheme == .litecoin) } else { Issue.record("litecoin") }
    }

    @Test func bankAccounts() {
        if case .payment(let p) = PayloadParser.parse("국민 123456-78-901234 홍길동") {
            #expect(p.scheme == .bankAccount); #expect(p.address == "123456-78-901234")
        } else { Issue.record("bank account") }
        if case .payment(let p) = PayloadParser.parse("계좌: 110-123-456789 (신한) 50,000원 입금") {
            #expect(p.scheme == .bankAccount); #expect(p.amount == "50,000")
        } else { Issue.record("계좌") }
        // 휴대전화 번호만 있는 텍스트는 계좌가 아니다.
        #expect(PayloadParser.parse("연락처 010-1234-5678").kind == .text)
    }

    @Test func appSchemes() {
        if case .appScheme(let u) = PayloadParser.parse("kakaotalk://open") { #expect(u.scheme == "kakaotalk") } else { Issue.record("kakaotalk") }
        if case .appScheme(let u) = PayloadParser.parse("foo://bar/baz") { #expect(u.scheme == "foo") } else { Issue.record("foo://") }
        if case .appScheme(let u) = PayloadParser.parse("itms-services://?action=download-manifest&url=https://example.test/a.plist") { #expect(u.scheme == "itms-services") } else { Issue.record("itms-services") }
        if case .appScheme(let u) = PayloadParser.parse("javascript:alert(1)") { #expect(u.scheme == "javascript") } else { Issue.record("javascript") }
        if case .appScheme(let u) = PayloadParser.parse("supertoss:") { #expect(u.scheme == "supertoss") } else { Issue.record("known scheme without //") }
    }

    @Test func textWithEmbeddedURLs() {
        let payload = PayloadParser.parse("행사 안내: example.com/event 와 https://b.example.test/x 를 확인하세요")
        guard case .text(_, let urls) = payload else { Issue.record("expected .text"); return }
        #expect(urls.count == 2)
        #expect(urls.first?.host() == "example.com")
        #expect(payload.primaryURL?.host() == "example.com")
    }

    @Test func plainTextWithoutURL() {
        if case .text(let t, let urls) = PayloadParser.parse("  Price:100 원  ") { #expect(t == "Price:100 원"); #expect(urls.isEmpty) } else { Issue.record("plain text") }
        if case .text(_, let urls) = PayloadParser.parse("문의 foo@bar.test") { #expect(urls.isEmpty) } else { Issue.record("email-only text") }
        #expect(PayloadParser.parse("").kind == .text)
    }
}
