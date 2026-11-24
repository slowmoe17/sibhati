// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MotionProbeCore",
    platforms: [.macOS(.v13), .watchOS(.v9)],
    products: [.library(name: "MotionProbeCore", targets: ["MotionProbeCore"])],
    targets: [
        .target(name: "MotionProbeCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "MotionProbeCoreTests", dependencies: ["MotionProbeCore"])
    ]
)
