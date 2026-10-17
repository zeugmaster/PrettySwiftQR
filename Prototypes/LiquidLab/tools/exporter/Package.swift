// swift-tools-version:6.0
// Exports the matrices the lab runs on: `swift run --package-path tools/exporter exporter ../../matrices.json`
import PackageDescription

let package = Package(
    name: "exporter",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../../..")],
    targets: [.executableTarget(name: "exporter", dependencies: [.product(name: "PrettyQRCore", package: "PrettySwiftQR")])]
)
