import Foundation
import Testing
@testable import QRGuardCore

@Suite("Punycode (RFC 3492)")
struct PunycodeTests {
    /// RFC 3492 §7.1 샘플 + 자주 쓰는 라벨.
    static let samples: [(unicode: String, punycode: String)] = [
        ("ليهمابتكلموشعربي؟", "egbpdaj6bu4bxfgehfvwxn"),
        ("他们为什么不说中文", "ihqwcrb4cv8a8dqg056pqjye"),
        ("なぜみんな日本語を話してくれないのか", "n8jok5ay5dzabd5bym9f0cm5685rrjetr6pdxa"),
        ("세계의모든사람들이한국어를이해한다면얼마나좋을까", "989aomsvi5e83db1d2a355cv1e0vak1dwrv93d5xbh15a0dt30a5jpsd879ccm6fea98c"),
        ("почемужеонинеговорятпорусски", "b1abfaaepdrnnbgefbadotcwatmq2g4l"),
        ("MajiでKoiする5秒前", "MajiKoi5-783gue6qz075azm5e"),
        ("bücher", "bcher-kva"),
        ("mañana", "maana-pta"),
        ("한국", "3e0b707e"),
        ("аррӏе", "80ak6aa92e"),
        ("nаver", "nver-53d"),
        ("navеr", "navr-x4d"),
    ]

    @Test(arguments: samples)
    func decode(_ sample: (unicode: String, punycode: String)) {
        #expect(Punycode.decode(sample.punycode) == sample.unicode)
    }

    @Test(arguments: samples)
    func encode(_ sample: (unicode: String, punycode: String)) {
        #expect(Punycode.encode(sample.unicode)?.lowercased() == sample.punycode.lowercased())
    }

    @Test func pureASCIIRoundTrip() {
        #expect(Punycode.encode("abc") == "abc-")
        #expect(Punycode.decode("abc-") == "abc")
        #expect(Punycode.decode("-") == "")
    }

    @Test func invalidInputReturnsNil() {
        #expect(Punycode.decode("abc!") == nil)
        #expect(Punycode.decode("한글") == nil)
        #expect(Punycode.decode("99999999999999999999") == nil)
    }

    @Test func hostHelpers() {
        #expect(Punycode.decodeHost("xn--80ak6aa92e.com") == "аррӏе.com")
        #expect(Punycode.decodeHost("www.xn--3e0b707e.test") == "www.한국.test")
        #expect(Punycode.decodeHost("plain.example.com") == "plain.example.com")
        #expect(Punycode.encodeHost("한국.Test") == "xn--3e0b707e.test")
        #expect(Punycode.encodeHost("Example.COM") == "example.com")
        // 깨진 라벨은 원문 유지
        #expect(Punycode.decodeHost("xn--!!!.com") == "xn--!!!.com")
    }
}
