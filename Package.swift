// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KramaIsland",
    platforms: [.macOS(.v13)],
    products: [
        // Loaded by /usr/bin/perl, not by the app: see Sources/MediaRemoteAdapter/adapter.m.
        .library(name: "MediaRemoteAdapter", type: .dynamic, targets: ["MediaRemoteAdapter"]),
    ],
    targets: [
        .target(
            name: "MediaRemoteAdapter",
            path: "Sources/MediaRemoteAdapter",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("Foundation")]
        ),
        // Embeds an Info.plist into the executable (see Sources/KramaIslandInfoPlist/info.c).
        .target(
            name: "KramaIslandInfoPlist",
            path: "Sources/KramaIslandInfoPlist"
        ),
        .executableTarget(
            name: "KramaIsland",
            dependencies: ["KramaIslandInfoPlist"],
            path: "Sources/KramaIsland",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("EventKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("IOKit"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
    ]
)
