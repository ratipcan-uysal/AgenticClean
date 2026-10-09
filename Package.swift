// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "Cleaner", platforms: [.macOS(.v14)], products: [.executable(name: "Cleaner", targets: ["Cleaner"])], targets: [
    .target(name: "ProcessKit"),
    .target(name: "CleanerCore", dependencies: ["ProcessKit"]),
    .executableTarget(name: "Cleaner", dependencies: ["CleanerCore"], swiftSettings: [.defaultIsolation(MainActor.self), .enableUpcomingFeature("NonisolatedNonsendingByDefault")]),
    .testTarget(name: "CleanerCoreTests", dependencies: ["CleanerCore"])
])
