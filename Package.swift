// swift-tools-version:5.10
// PulseMac — native macOS performance monitor & diagnostics.
//
// Layout (see docs/architecture/architecture.md):
//   PulseCore         Pure Swift domain logic. No OS calls. Builds and tests on Linux.
//   CSQLite           System SQLite shim (macOS SDK / libsqlite3-dev on Linux).
//   PulsePersistence  Bounded SQLite time-series history.
//   PulseMonitoring   Collectors (macOS-only implementations behind #if os(macOS)),
//                     sampling coordinator, storage scanner, process actions.
//   PulseMacApp       SwiftUI + AppKit application (macOS only).
import PackageDescription

var products: [Product] = [
    .library(name: "PulseCore", targets: ["PulseCore"]),
    .library(name: "PulsePersistence", targets: ["PulsePersistence"]),
    .library(name: "PulseMonitoring", targets: ["PulseMonitoring"]),
]

let strictness: [SwiftSetting] = [
    .enableUpcomingFeature("BareSlashRegexLiterals"),
    .enableUpcomingFeature("ExistentialAny"),
]

var targets: [Target] = [
    .target(name: "PulseCore", swiftSettings: strictness),
    .systemLibrary(name: "CSQLite", providers: [.apt(["libsqlite3-dev"])]),
    .target(name: "PulsePersistence", dependencies: ["PulseCore", "CSQLite"], swiftSettings: strictness),
    .target(name: "PulseMonitoring", dependencies: ["PulseCore", "PulsePersistence"], swiftSettings: strictness),
    .testTarget(name: "PulseCoreTests", dependencies: ["PulseCore"]),
    .testTarget(name: "PulsePersistenceTests", dependencies: ["PulsePersistence"]),
    .testTarget(name: "PulseMonitoringTests", dependencies: ["PulseMonitoring"]),
]

#if os(macOS)
products.append(.executable(name: "PulseMac", targets: ["PulseMacApp"]))
targets.append(
    .executableTarget(
        name: "PulseMacApp",
        dependencies: ["PulseCore", "PulsePersistence", "PulseMonitoring"],
        swiftSettings: strictness
    )
)
#endif

let package = Package(
    name: "PulseMac",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
