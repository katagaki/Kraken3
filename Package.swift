// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Kraken",
    targets: [
        .systemLibrary(
            name: "CZlib",
            path: "Sources/CZlib"
        ),
        .executableTarget(
            name: "Kraken",
            dependencies: ["CZlib"],
            path: "Sources/Kraken"
        ),
        .executableTarget(
            name: "KrakenReaper",
            path: "Sources/KrakenReaper"
        )
    ]
)
