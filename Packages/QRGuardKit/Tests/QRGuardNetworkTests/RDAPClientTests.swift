import Foundation
import Testing
@testable import QRGuardNetwork

@Suite("RDAPClient (T-4.5)")
struct RDAPClientTests {
    private func client(_ host: MockHost) -> RDAPClient {
        RDAPClient(session: mockSession(), baseURL: host.url("/domain/"), timeout: .seconds(2))
    }

    @Test("registration 이벤트의 날짜를 파싱한다(소수점 초 포함)")
    func parsesRegistrationDate() async throws {
        let api = MockHost("rdap-ok")
        api.stub("/domain/fresh.test", .json("""
        {"objectClassName":"domain","ldhName":"fresh.test","events":[
          {"eventAction":"last changed","eventDate":"2025-01-02T03:04:05Z"},
          {"eventAction":"registration","eventDate":"2019-03-14T10:11:12.345Z"},
          {"eventAction":"expiration","eventDate":"2027-03-14T10:11:12Z"}
        ]}
        """))

        let date = try await client(api).registrationDate(for: "Fresh.TEST")

        let expected = try #require(ISO8601DateFormatter().date(from: "2019-03-14T10:11:12Z"))
        let actual = try #require(date)
        #expect(abs(actual.timeIntervalSince(expected) - 0.345) < 0.01)
        #expect(api.requests.first?.url.path == "/domain/fresh.test")
        #expect(api.requests.first?.headers["Accept"]?.contains("application/rdap+json") == true)
    }

    @Test("404는 nil(오류 아님)")
    func notFoundIsNil() async throws {
        let api = MockHost("rdap-404")
        api.stub("/domain/unknown.test", .json(#"{"errorCode":404}"#, status: 404))
        let date = try await client(api).registrationDate(for: "unknown.test")
        #expect(date == nil)
    }

    @Test("registration 이벤트가 없으면 nil")
    func missingEventIsNil() async throws {
        let api = MockHost("rdap-noevent")
        api.stub("/domain/noevent.test", .json(#"{"events":[{"eventAction":"expiration","eventDate":"2030-01-01T00:00:00Z"}]}"#))
        let date = try await client(api).registrationDate(for: "noevent.test")
        #expect(date == nil)
    }

    @Test("5xx·네트워크 오류·시간 초과는 throw")
    func errorsThrow() async {
        let api = MockHost("rdap-500")
        api.stub("/domain/broken.test", .json("{}", status: 500))
        await #expect(throws: RDAPClient.RDAPError.httpStatus(500)) {
            _ = try await client(api).registrationDate(for: "broken.test")
        }

        let down = MockHost("rdap-down")
        down.stubAll(.failing(.cannotConnectToHost))
        await #expect(throws: (any Error).self) {
            _ = try await client(down).registrationDate(for: "down.test")
        }

        let slow = MockHost("rdap-hang")
        slow.stubAll(.hanging)
        let hanging = RDAPClient(session: mockSession(requestTimeout: 1), baseURL: slow.url("/domain/"), timeout: .milliseconds(300))
        await #expect(throws: (any Error).self) {
            _ = try await hanging.registrationDate(for: "slow.test")
        }
    }

    @Test("rdap.org → 레지스트리 리다이렉트는 정상적으로 따라간다")
    func followsBootstrapRedirect() async throws {
        let bootstrap = MockHost("rdap-boot")
        let registry = MockHost("rdap-registry")
        bootstrap.stub("/domain/moved.test", .redirect(302, to: registry.url("/domain/moved.test").absoluteString))
        registry.stub("/domain/moved.test", .json(#"{"events":[{"eventAction":"registration","eventDate":"2001-07-20T00:00:00+09:00"}]}"#))

        let date = try await client(bootstrap).registrationDate(for: "moved.test")

        #expect(date == ISO8601DateFormatter().date(from: "2001-07-19T15:00:00Z"))
        #expect(registry.requests.count == 1)
    }

    @Test("ISO 8601 변형 파싱", arguments: [
        ("1995-08-14T04:00:00Z", "1995-08-14T04:00:00Z"),
        ("2020-01-01T09:00:00+09:00", "2020-01-01T00:00:00Z"),
        ("2020-01-01T00:00:00.000Z", "2020-01-01T00:00:00Z"),
        ("2020-06-15T12:30:00", "2020-06-15T12:30:00Z"),
        ("2020-06-15", "2020-06-15T00:00:00Z"),
    ])
    func parsesVariants(raw: String, expectedISO: String) throws {
        let expected = try #require(ISO8601DateFormatter().date(from: expectedISO))
        #expect(RDAPClient.parseISO8601(raw) == expected)
    }
}
