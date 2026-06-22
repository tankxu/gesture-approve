// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GestureApprove",
    platforms: [.macOS(.v14)],
    dependencies: [
        // 仅 GestureGatekeeper(可选、按需下载的 helper)链接 MLX。
        // 主 app 不依赖它,安装包大小不受影响。
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.31.3")),
        // mlx-swift-lm 3.x 把 HuggingFace/tokenizer 接入交给消费方:用 MLXHuggingFace
        // 宏(Method 2)适配下面这两个官方包。仅 helper 链接,主 app 不受影响。
        .package(url: "https://github.com/huggingface/swift-huggingface", .upToNextMajor(from: "0.9.0")),
        .package(url: "https://github.com/huggingface/swift-transformers", .upToNextMajor(from: "1.3.0")),
    ],
    targets: [
        // 主 app:零 MLX 依赖,保持安装包小巧。
        .executableTarget(
            name: "GestureApprove",
            path: "Sources/GestureApprove",
            swiftSettings: [
                // 用 Swift 5 语言模式，避免严格并发检查在 AVFoundation/Vision
                // 的回调里产生大量编译噪声。
                .swiftLanguageMode(.v5)
            ]
        ),
        // 可选的本地 LLM 守门员 helper。单独编译、单独分发(不打进 .app),
        // 用户在设置里开启「智能放行」时按需下载到 Application Support。
        .executableTarget(
            name: "GestureGatekeeper",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/GestureGatekeeper",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
