// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TourMix",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "TourMixCore",
            targets: ["TourMixCore"]
        ),
        .executable(
            name: "TourMix",
            targets: ["TourMix"]
        )
    ],
    targets: [
        .target(
            name: "TourMixCore",
            path: "Sources/TourMixCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices")
            ]
        ),
        .executableTarget(
            name: "TourMix",
            dependencies: ["TourMixCore"],
            path: "Sources/TourMixApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "TourMixCoreTests",
            dependencies: ["TourMixCore"],
            path: "Tests/TourMixCoreTests"
        )
    ]
)
