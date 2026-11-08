// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "MyTablet",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CPrivate", path: "Sources/CPrivate"),
        .executableTarget(name: "MyTablet", dependencies: ["CPrivate"], path: "Sources/MyTablet",
                          swiftSettings: [.unsafeFlags(["-swift-version", "5"])]),
    ]
)
