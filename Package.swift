// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "CodexNotch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "codex-notch", targets: ["CodexNotch"]),
    ],
    targets: [
        .target(
            name: "PTYShim",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "CodexNotch",
            dependencies: ["PTYShim"]
        ),
    ]
)
