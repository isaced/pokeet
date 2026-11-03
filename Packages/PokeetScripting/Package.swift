// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PokeetScripting",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "PokeetScripting", targets: ["PokeetScripting"])
    ],
    dependencies: [
        .package(path: "../PokeetCore")
    ],
    targets: [
        .target(
            name: "CQuickJS",
            publicHeadersPath: "include",
            cSettings: [
                .define("_GNU_SOURCE"),
                .define("DUMP_LEAKS", to: "0")
            ]
        ),
        .target(
            name: "PokeetScripting",
            dependencies: [
                "CQuickJS",
                .product(name: "PokeetCore", package: "PokeetCore")
            ]
        ),
        .testTarget(
            name: "PokeetScriptingTests",
            dependencies: [
                "PokeetScripting",
                .product(name: "PokeetCore", package: "PokeetCore")
            ]
        )
    ]
)
