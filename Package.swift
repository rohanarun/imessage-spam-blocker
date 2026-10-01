// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "QuietMessages", platforms: [.macOS(.v14)], products: [.executable(name: "QuietMessages", targets: ["QuietMessages"])], targets: [
 .target(name: "NativeBlocking", linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("Contacts")]),
 .target(name: "GuardCore", dependencies: ["NativeBlocking"]),
 .executableTarget(name: "QuietMessages", dependencies: ["GuardCore"]),
 .testTarget(name: "GuardCoreTests", dependencies: ["GuardCore"])
])
