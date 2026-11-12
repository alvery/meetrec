// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "meetrec",
    platforms: [.macOS("14.2")], // Core Audio process taps
    targets: [
        .target(name: "RecorderKit", path: "Sources/RecorderKit"),
        .executableTarget(name: "rec", dependencies: ["RecorderKit"], path: "Sources/rec"),
        .executableTarget(name: "MeetrecApp", dependencies: ["RecorderKit"], path: "Sources/MeetrecApp"),
    ]
)
