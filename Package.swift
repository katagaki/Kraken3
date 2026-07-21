// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Kraken",
    targets: [
        .systemLibrary(
            name: "CZlib",
            path: "Sources/CZlib"
        ),
        .target(
            name: "CJPEG",
            path: "Sources/CJPEG",
            linkerSettings: [.linkedLibrary("jpeg")]
        ),
        .executableTarget(
            name: "Kraken",
            dependencies: [
                "CZlib",
                // libjpeg-turbo is only guaranteed in the Docker image; macOS
                // dev builds fall back to the pure-Swift encoder.
                .target(name: "CJPEG", condition: .when(platforms: [.linux]))
            ],
            path: "Sources/Kraken"
        ),
        .executableTarget(
            name: "KrakenReaper",
            path: "Sources/KrakenReaper"
        )
    ]
)
