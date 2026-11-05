// swift-tools-version:5.9
// The phone's brick engine, with no Apple-only dependencies, so its tests run
// anywhere (`swift test` on a Mac or Linux). The app compiles these same
// sources directly into each target (see project.yml).
import PackageDescription

let package = Package(
    name: "BrickCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "BrickCore", targets: ["BrickCore"])],
    targets: [
        .target(name: "BrickCore"),
        .testTarget(name: "BrickCoreTests", dependencies: ["BrickCore"]),
    ]
)
