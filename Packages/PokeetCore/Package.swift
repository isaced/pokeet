// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PokeetCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "PokeetCore", targets: ["PokeetCore"])
    ],
    targets: [
        .target(name: "PokeetCore"),
        .testTarget(name: "PokeetCoreTests", dependencies: ["PokeetCore"])
    ]
)
