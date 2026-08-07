// swift-tools-version: 6.0
import PackageDescription

// PfadiCore holds everything that has no AppKit in it: reading a directory,
// sorting it, completing a half-typed path. That is the part worth testing,
// and a test target cannot open a window.
//
// The tests are an executable rather than a .testTarget on purpose. Both
// XCTest and swift-testing live inside the full Xcode install, so `swift test`
// cannot run on a machine that only has the Command Line Tools. A 15 GB
// download is a steep price for four assertions.
let package = Package(
    name: "pfadi",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "PfadiCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "pfadi",
            dependencies: ["PfadiCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The `pfadi` command. A separate executable from the application
        // because it must return the moment LaunchServices has been asked,
        // rather than holding the terminal until the window is closed.
        .executableTarget(
            name: "pfadi-cli",
            dependencies: ["PfadiCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "pfadi-default",
            dependencies: ["PfadiCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "pfadi-selftest",
            dependencies: ["PfadiCore"],
            path: "Tests/PfadiSelfTest",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
