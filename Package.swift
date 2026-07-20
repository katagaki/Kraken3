// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Kraken",
    targets: [
        .executableTarget(
            name: "Kraken",
            path: "Sources/Kraken"
        ),
        .executableTarget(
            name: "KrakenReaper",
            path: "Sources/KrakenReaper"
        )
    ]
)
