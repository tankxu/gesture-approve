// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GestureApprove",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GestureApprove",
            path: "Sources/GestureApprove",
            swiftSettings: [
                // 用 Swift 5 语言模式，避免严格并发检查在 AVFoundation/Vision
                // 的回调里产生大量编译噪声。
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
