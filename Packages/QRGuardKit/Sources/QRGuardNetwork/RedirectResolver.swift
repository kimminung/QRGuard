import Foundation
import QRGuardCore

/// 리다이렉트 추적기 (TASKS T-4.1, TECH_PRD 6.2).
///
/// - 델리게이트가 `willPerformHTTPRedirection`에서 항상 `nil`을 돌려주므로 세션은 리다이렉트를 자동으로 따라가지 않는다.
///   각 3xx 응답의 `Location`을 직접 해석해 한 홉씩 기록·검사하며 따라간다.
/// - `http://` 홉은 접속하지 않고 `.stoppedAtInsecureHop`으로 종료한다(ATS).
/// - 사설 IP·localhost·`.local` 홉은 요청하지 않고 `.blockedPrivateAddress`.
/// - HEAD 우선, 405/403/501 또는 Location 없는 3xx면 `GET` + `Range: bytes=0-0`으로 재시도.
public final class RedirectResolver: RedirectResolving {
    public static let defaultMaxHops = 10
    public static let defaultPerHopTimeout: Duration = .seconds(3)
    public static let defaultTotalTimeout: Duration = .seconds(6)

    private let session: URLSession

    /// - Parameter configuration: 기본은 `HardenedSession.configuration()`. 테스트에서는 `protocolClasses`로 스텁을 주입한다.
    public init(configuration: URLSessionConfiguration = HardenedSession.configuration()) {
        session = URLSession(configuration: configuration, delegate: RedirectRefusingDelegate(), delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// 테스트·규칙에서 쓰는 공개 헬퍼.
    public static func isPrivateOrLocal(host: String) -> Bool {
        PrivateAddressChecker.isPrivateOrLocal(host: host)
    }

    public func resolve(
        _ url: URL,
        maxHops: Int = RedirectResolver.defaultMaxHops,
        perHopTimeout: Duration = RedirectResolver.defaultPerHopTimeout,
        totalTimeout: Duration = RedirectResolver.defaultTotalTimeout
    ) async -> RedirectChain {
        let clock = ContinuousClock()
        let deadline = clock.now + totalTimeout
        var hops = [RedirectHop(order: 0, url: url, statusCode: nil)]
        var visited: Set<String> = [Self.visitKey(url)]
        var index = 0

        while true {
            let current = hops[index].url

            guard let scheme = current.scheme?.lowercased() else {
                return RedirectChain(hops: hops, outcome: .failed("invalid URL"))
            }
            if scheme == "http" {
                return RedirectChain(hops: hops, outcome: .stoppedAtInsecureHop)
            }
            guard scheme == "https" else {
                // 앱 스킴 등 웹이 아닌 최종 목적지: 더 따라갈 수 없으므로 여기서 확정.
                return RedirectChain(hops: hops, outcome: .completed)
            }
            guard let host = current.host, !host.isEmpty else {
                return RedirectChain(hops: hops, outcome: .failed("missing host"))
            }
            if Self.isPrivateOrLocal(host: host) {
                return RedirectChain(hops: hops, outcome: .blockedPrivateAddress)
            }
            if Task.isCancelled {
                return RedirectChain(hops: hops, outcome: .failed("cancelled"))
            }
            guard clock.now < deadline else {
                return RedirectChain(hops: hops, outcome: .timedOut)
            }

            let response: HTTPURLResponse
            do {
                response = try await fetch(current, perHopTimeout: perHopTimeout, deadline: deadline, clock: clock)
            } catch let error as URLError where error.isTLSFailure {
                return RedirectChain(hops: hops, outcome: .tlsFailure)
            } catch let error as URLError where error.code == .timedOut {
                return RedirectChain(hops: hops, outcome: .timedOut)
            } catch is TimeoutError {
                return RedirectChain(hops: hops, outcome: .timedOut)
            } catch is CancellationError {
                return RedirectChain(hops: hops, outcome: .failed("cancelled"))
            } catch let error as URLError where error.code == .cancelled {
                return RedirectChain(hops: hops, outcome: Task.isCancelled ? .failed("cancelled") : .timedOut)
            } catch {
                return RedirectChain(hops: hops, outcome: .failed(Self.describe(error)))
            }

            let status = response.statusCode
            hops[index] = RedirectHop(order: index, url: current, statusCode: status)

            if Self.isRedirectStatus(status),
               let location = response.value(forHTTPHeaderField: "Location"),
               let next = Self.resolveLocation(location, relativeTo: current) {
                if index >= maxHops {
                    return RedirectChain(hops: hops, outcome: .tooManyHops)
                }
                let key = Self.visitKey(next)
                hops.append(RedirectHop(order: index + 1, url: next, statusCode: nil))
                if visited.contains(key) {
                    return RedirectChain(hops: hops, outcome: .loopDetected)
                }
                visited.insert(key)
                index += 1
                continue
            }

            let contentType = response.value(forHTTPHeaderField: "Content-Type")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return RedirectChain(
                hops: hops,
                outcome: .completed,
                finalContentType: contentType.flatMap { $0.isEmpty ? nil : $0 },
                finalStatusCode: status
            )
        }
    }

    // MARK: - 요청

    private func fetch(
        _ url: URL,
        perHopTimeout: Duration,
        deadline: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async throws -> HTTPURLResponse {
        let head = try await perform(makeRequest(url, method: "HEAD"), perHopTimeout: perHopTimeout, deadline: deadline, clock: clock)
        let needsGET = [405, 403, 501].contains(head.statusCode)
            || (Self.isRedirectStatus(head.statusCode) && head.value(forHTTPHeaderField: "Location") == nil)
        guard needsGET else { return head }

        var get = makeRequest(url, method: "GET")
        get.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        return try await perform(get, perHopTimeout: perHopTimeout, deadline: deadline, clock: clock)
    }

    private func perform(
        _ request: URLRequest,
        perHopTimeout: Duration,
        deadline: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async throws -> HTTPURLResponse {
        let remaining = deadline - clock.now
        guard remaining > .zero else { throw TimeoutError() }
        let budget = min(perHopTimeout, remaining)
        var timedRequest = request
        timedRequest.timeoutInterval = Self.seconds(budget)
        let request = timedRequest
        let session = self.session
        return try await withTimeout(budget) {
            // 본문은 읽지 않는다. 헤더가 도착하면 즉시 작업을 취소한다(Range 무시 서버 대비).
            let (bytes, response) = try await session.bytes(for: request)
            bytes.task.cancel()
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            return http
        }
    }

    private func makeRequest(_ url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: - 헬퍼

    static func isRedirectStatus(_ status: Int) -> Bool {
        (300..<400).contains(status) && status != 304
    }

    static func resolveLocation(_ location: String, relativeTo base: URL) -> URL? {
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed, relativeTo: base)?.absoluteURL, url.scheme != nil { return url }
        // 공백 등 비허용 문자가 섞인 Location 대비
        let escaped = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.union(CharacterSet(charactersIn: "#"))) ?? trimmed
        return URL(string: escaped, relativeTo: base)?.absoluteURL
    }

    /// 루프 감지용 키: 스킴·호스트 소문자, 프래그먼트 제거, 기본 포트 제거.
    static func visitKey(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        if (components.scheme == "https" && components.port == 443) || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        if components.path.isEmpty { components.path = "/" }
        return components.string ?? url.absoluteString
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        let c = duration.components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }

    static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return "URLError \(urlError.code.rawValue)"
        }
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
    }
}

/// 리다이렉트를 자동으로 따라가지 않게 하는 세션 델리게이트. 상태가 없다.
final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
