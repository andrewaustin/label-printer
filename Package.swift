// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LabelPrinter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "LabelPrinter", path: "Sources/LabelPrinter"),
        .testTarget(name: "LabelPrinterTests", dependencies: ["LabelPrinter"], path: "Tests/LabelPrinterTests"),
    ],
    swiftLanguageModes: [.v5]
)
