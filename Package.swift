// swift-tools-version: 6.0
import PackageDescription

// NOTE ON TESTING
//
// swift-testing ships inside the active developer directory, but SwiftPM does
// not add that directory to the framework search path on its own. `swift test`
// on its own therefore builds and then silently runs zero tests (and Command
// Line Tools ships no `xctest` binary to fall back to).
//
// The flags have to apply to EVERY target — including the runner target SwiftPM
// generates — so putting them in this manifest's testTarget does not work. They
// live in the Makefile instead. Use `make test`, not `swift test`.

let package = Package(
    name: "Zmkonfig",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .target(
            name: "ZmkonfigKit",
            path: "Sources/ZmkonfigKit",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "Zmkonfig",
            dependencies: ["ZmkonfigKit"],
            path: "Sources/Zmkonfig"
        ),
        .testTarget(
            name: "ZmkonfigKitTests",
            dependencies: ["ZmkonfigKit"],
            path: "Tests/ZmkonfigKitTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
    ]
)
