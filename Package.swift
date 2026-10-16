// swift-tools-version:6.0

import PackageDescription

let package = Package(
    name: "PrettySwiftQR",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "PrettySwiftQR", targets: ["PrettySwiftQR"]),
        .library(name: "PrettyQRCore", targets: ["PrettyQRCore"]),
    ],
    targets: [
        .target(
            name: "PrettyQRCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "PrettySwiftQR",
            dependencies: ["PrettyQRCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PrettyQRCoreTests",
            dependencies: ["PrettyQRCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PrettySwiftQRTests",
            dependencies: ["PrettySwiftQR"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
