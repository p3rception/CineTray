// swift-tools-version: 6.3
// Builds CineTray without Xcode (Command Line Tools only). Run ./build.sh to
// produce dist/CineTray.app. The Xcode project remains the alternative.
import PackageDescription

let package = Package(
    name: "CineTray",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/harflabs/SwiftVLC.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "CineTray",
            dependencies: [.product(name: "SwiftVLC", package: "SwiftVLC")],
            path: "CineTray",
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
