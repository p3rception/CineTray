// swift-tools-version: 6.3
// Builds QuPi without Xcode (Command Line Tools only). Run ./build.sh to
// produce dist/QuPi.app. The Xcode project remains the alternative.
import PackageDescription

let package = Package(
    name: "QuPi",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/harflabs/SwiftVLC.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "QuPi",
            dependencies: [.product(name: "SwiftVLC", package: "SwiftVLC")],
            path: "QuPi",
            exclude: ["Info.plist", "AppIcon.icns"],
            // Mirrors the Xcode project's build settings.
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("MemberImportVisibility"),
                .enableUpcomingFeature("BareSlashRegexLiterals"),
            ]
        ),
    ]
)
