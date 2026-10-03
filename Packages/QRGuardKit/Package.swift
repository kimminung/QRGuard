// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QRGuardKit",
    defaultLocalization: "ko",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "QRGuardCore", targets: ["QRGuardCore"]),
        .library(name: "QRGuardNetwork", targets: ["QRGuardNetwork"]),
    ],
    targets: [
        // 분석 엔진: 페이로드 · URL 정규화 · PSL · 규칙 · 점수. UIKit/SwiftUI를 import하지 않는다.
        .target(
            name: "QRGuardCore",
            resources: [.process("Resources")]
        ),
        // 온라인 검사: 리다이렉트 추적 · 평판 조회 · RDAP · 페이지 사전 검사 · 파이프라인.
        .target(
            name: "QRGuardNetwork",
            dependencies: ["QRGuardCore"]
        ),
        .testTarget(
            name: "QRGuardCoreTests",
            dependencies: ["QRGuardCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "QRGuardNetworkTests",
            dependencies: ["QRGuardNetwork", "QRGuardCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
