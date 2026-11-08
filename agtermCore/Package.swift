// swift-tools-version: 6.0
import PackageDescription

let coreTarget = Target.target(name: "agtermCore", dependencies: [.product(name: "TOMLDecoder", package: "TOMLDecoder")])

let package = Package(
    name: "agtermCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "agtermCore", targets: ["agtermCore"]),
        .library(name: "agtermctlKit", targets: ["agtermctlKit"]),
        .library(name: "AgtermResponsibility", targets: ["AgtermResponsibility"]),
        .executable(name: "agtermctl", targets: ["agtermctl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/dduan/TOMLDecoder", from: "0.4.5"),
    ],
    targets: [
        coreTarget,
        .target(name: "AgtermResponsibility"),
        .testTarget(name: "agtermCoreTests", dependencies: ["agtermCore"]),
        .target(
            name: "agtermctlKit",
            dependencies: [
                "agtermCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(name: "agtermctl", dependencies: ["agtermctlKit"]),
        // debug-only fixture: it imports agtermctlKit @testable, and release builds name their products.
        .executableTarget(name: "session-wait-watchdog-probe", dependencies: ["agtermctlKit"]),
        .testTarget(name: "agtermctlKitTests", dependencies: ["agtermctlKit", "agtermctl", "session-wait-watchdog-probe"]),
    ],
    swiftLanguageModes: [.v6]
)

#if os(Linux)
// Foundation's attributed Markdown APIs are absent on Linux. Keep the parser dependency local to the
// hosts that need it so upstream Darwin builds retain their original dependency graph and behavior.
package.dependencies.append(.package(url: "https://github.com/swiftlang/swift-markdown", exact: "0.8.0"))
coreTarget.dependencies.append(.product(name: "Markdown", package: "swift-markdown"))
#endif

#if os(macOS)
package.products.append(.executable(name: "agterm-session-host", targets: ["agterm-session-host"]))
package.targets += [
    .target(name: "SessionHostTrampoline"),
    .target(name: "SessionHostRuntime", dependencies: ["SessionHostTrampoline", "AgtermResponsibility", "agtermCore"]),
    .executableTarget(name: "agterm-session-host", dependencies: ["SessionHostRuntime"]),
    // The fixtures need a socket client they can copy into a test bundle, which /usr/bin/nc
    // cannot be (see the target's own comment).
    .executableTarget(name: "session-host-test-client"),
    .executableTarget(name: "session-host-pty-probe"),
    .testTarget(name: "SessionHostRuntimeTests",
                dependencies: ["SessionHostRuntime", "agterm-session-host", "session-host-test-client",
                               "session-host-pty-probe"]),
]
#endif
