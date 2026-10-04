import Foundation

/// 앱·공유 확장·위젯이 공유하는 딥링크와 App Group 식별자.
/// 위젯 타깃은 패키지를 링크하지 않으므로 같은 문자열을 하드코딩한다(변경 시 함께 수정).
public enum QRGuardLinks {
    public static let scheme = "qrguard"
    public static let appGroup = "group.com.coulson.QRGuard"

    /// `qrguard://scan` — 스캐너 바로 열기 (제어 센터 컨트롤·잠금화면 위젯)
    public static let scan = URL(string: "\(scheme)://scan")!

    /// `qrguard://analyze?inbox=<uuid>` — 공유 확장이 App Group 받은편지함에 남긴 분석 결과 열기
    public static func openInbox(_ id: UUID) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "analyze"
        components.queryItems = [URLQueryItem(name: "inbox", value: id.uuidString)]
        return components.url!
    }

    /// `qrguard://analyze?p=<base64url>` — 원문을 넘겨 앱에서 다시 분석
    public static func analyze(payload: String, source: ScanSource) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "analyze"
        let encoded = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        components.queryItems = [
            URLQueryItem(name: "p", value: encoded),
            URLQueryItem(name: "source", value: source.rawValue),
        ]
        return components.url!
    }

    /// 딥링크 해석 결과.
    public enum Route: Equatable {
        case scan
        case inbox(UUID)
        case analyze(payload: String, source: ScanSource)
    }

    public static func route(for url: URL) -> Route? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        switch url.host()?.lowercased() {
        case "scan":
            return .scan
        case "analyze":
            let items = components?.queryItems ?? []
            if let inbox = items.first(where: { $0.name == "inbox" })?.value, let id = UUID(uuidString: inbox) {
                return .inbox(id)
            }
            if let p = items.first(where: { $0.name == "p" })?.value {
                var base64 = p.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                while base64.count % 4 != 0 { base64.append("=") }
                guard let data = Data(base64Encoded: base64), let payload = String(data: data, encoding: .utf8), !payload.isEmpty else { return nil }
                let source = items.first(where: { $0.name == "source" }).flatMap { $0.value }.flatMap(ScanSource.init(rawValue:)) ?? .shareExtension
                return .analyze(payload: payload, source: source)
            }
            return nil
        default:
            return nil
        }
    }
}

/// 공유 확장 → 앱으로 넘기는 분석 결과 1건 (App Group 컨테이너의 `Inbox/` 폴더에 JSON으로 저장).
public struct SharedInboxItem: Codable, Sendable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let raw: String
    public let context: AnalysisContext
    public let report: RiskReport
    public let snapshot: AnalysisSnapshot?

    public init(id: UUID = UUID(), createdAt: Date = .now, raw: String, context: AnalysisContext, report: RiskReport, snapshot: AnalysisSnapshot?) {
        self.id = id
        self.createdAt = createdAt
        self.raw = raw
        self.context = context
        self.report = report
        self.snapshot = snapshot
    }
}

/// App Group 받은편지함 읽기·쓰기. 확장은 쓰기만, 앱은 읽고 지운다.
public struct SharedInbox: Sendable {
    public let directory: URL

    public init?(appGroup: String = QRGuardLinks.appGroup) {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        directory = container.appendingPathComponent("Inbox", isDirectory: true)
    }

    public init(directory: URL) {
        self.directory = directory
    }

    public func write(_ item: SharedInboxItem) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(item)
        try data.write(to: directory.appendingPathComponent("\(item.id.uuidString).json"), options: .atomic)
    }

    /// 오래된 것부터 돌려준다.
    public func drain() -> [SharedInboxItem] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var items: [SharedInboxItem] = []
        for url in urls where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url), let item = try? JSONDecoder().decode(SharedInboxItem.self, from: data) {
                items.append(item)
            }
            try? FileManager.default.removeItem(at: url)
        }
        return items.sorted { $0.createdAt < $1.createdAt }
    }
}
