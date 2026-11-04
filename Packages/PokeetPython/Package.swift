// swift-tools-version: 6.0
import Foundation
import PackageDescription

// The package links no interpreter on purpose: the app embeds Vendor/Python.xcframework
// through project.yml, and the test bundle links the host dylib from the command line.
// That keeps one manifest that works for both, instead of branching on a platform the
// manifest cannot see (Xcode does not pass PLATFORM_NAME to package evaluation).
//
//   scripts/fetch-python.sh
//   swift test --package-path Packages/PokeetPython \
//     -Xlinker /opt/homebrew/opt/python@3.12/Frameworks/Python.framework/Versions/3.12/lib/libpython3.12.dylib
//
// Headers are staged by the fetch script and are identical for every slice.
// The vendor tree lives at the repository root, next to the other staged inputs.
let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let pythonInclude = "\(packageDirectory)/../../Vendor/python-include"

let package = Package(
    name: "PokeetPython",
    platforms: [
        .iOS(.v18),
        .macOS(.v14)
    ],
    products: [
        .library(name: "PokeetPython", targets: ["PokeetPython"])
    ],
    dependencies: [
        .package(path: "../PokeetCore")
    ],
    targets: [
        .target(
            name: "CPython",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-I\(pythonInclude)"])]
        ),
        .target(
            name: "PokeetPython",
            dependencies: [
                "CPython",
                .product(name: "PokeetCore", package: "PokeetCore")
            ],
            resources: [.copy("Resources/python-prelude.py")],
            swiftSettings: [.unsafeFlags(["-Xcc", "-I\(pythonInclude)"])]
        ),
        .testTarget(
            name: "PokeetPythonTests",
            dependencies: ["PokeetPython"]
        )
    ]
)
