import Testing
@testable import QRGuardCore

@Suite("KoreanParticle") struct KoreanParticleTests {
    @Test func resolvesByFinalConsonant() {
        #expect(KoreanParticle.resolve(in: "네이버을(를) 사칭") == "네이버를 사칭")
        #expect(KoreanParticle.resolve(in: "쿠팡을(를) 사칭") == "쿠팡을 사칭")
        #expect(KoreanParticle.resolve(in: "t.ly은(는) 공식") == "t.ly는 공식")
        #expect(KoreanParticle.resolve(in: "naver.com은(는) 공식") == "naver.com은 공식")
        #expect(KoreanParticle.resolve(in: "3개와(과)") == "3개와")
        #expect(KoreanParticle.resolve(in: "서울(으)로") == "서울로")
        #expect(KoreanParticle.resolve(in: "부산(으)로") == "부산으로")
    }

    @Test func leavesUnknownAlone() {
        #expect(KoreanParticle.resolve(in: "?은(는)") == "?은(는)")
    }
}
