// swift-tools-version:6.0
import PackageDescription

// Library-only package: no executable or app target lives here.
// The runnable demo is a separate Xcode project in its own repository
// (seat-entitlement-kit-demo-app) that consumes this package by tag.
let package = Package(
    name: "SeatEntitlements",
    // Only platforms that CI actually builds are declared.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SeatEntitlements", targets: ["SeatEntitlements"]),
        .library(name: "SeatEntitlementsUI", targets: ["SeatEntitlementsUI"]),
    ],
    targets: [
        .target(name: "SeatEntitlements"),
        .target(name: "SeatEntitlementsUI", dependencies: ["SeatEntitlements"]),
        .testTarget(name: "SeatEntitlementsTests", dependencies: ["SeatEntitlements"]),
    ]
)
