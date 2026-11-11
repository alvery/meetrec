// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "meetrec",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "rec", path: "Sources/rec"),
    ]
)
