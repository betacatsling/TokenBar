// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TokenBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "TokenBar",
            path: "Sources/TokenBar",
            resources: [.copy("Resources/remote_collect.py"),
                        .copy("Resources/model_prices.json")],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ]
)
