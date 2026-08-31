// swift-tools-version: 6.2
import PackageDescription

/// Local modules are deliberately kept acyclic so camera, networking, and image
/// implementations can evolve independently behind their future protocols.
let package = Package(
    name: "TeamDModules",
    platforms: [
        .iOS(.v18),
    ],
    products: [
        .library(name: "DomainKit", targets: ["DomainKit"]),
        .library(name: "ContractKit", targets: ["ContractKit"]),
        .library(name: "CaptureKit", targets: ["CaptureKit"]),
        .library(name: "APIClient", targets: ["APIClient"]),
        .library(name: "LiveKitBridge", targets: ["LiveKitBridge"]),
        .library(name: "MeasurementKit", targets: ["MeasurementKit"]),
        .library(name: "CompositionKit", targets: ["CompositionKit"]),
        .library(name: "TestSupport", targets: ["TestSupport"]),
    ],
    targets: [
        .target(name: "DomainKit"),
        .target(
            name: "ContractKit",
            dependencies: ["DomainKit"]
        ),
        .target(
            name: "CaptureKit",
            dependencies: ["DomainKit"]
        ),
        .target(
            name: "APIClient",
            dependencies: ["ContractKit"]
        ),
        .target(
            name: "LiveKitBridge",
            dependencies: ["CaptureKit", "ContractKit"]
        ),
        .target(
            name: "MeasurementKit",
            dependencies: ["DomainKit"]
        ),
        .target(
            name: "CompositionKit",
            dependencies: ["DomainKit"]
        ),
        .target(
            name: "TestSupport",
            dependencies: [
                "DomainKit",
                "ContractKit",
                "CaptureKit",
                "APIClient",
                "LiveKitBridge",
                "MeasurementKit",
                "CompositionKit",
            ],
            path: "Sources/TestSupport"
        ),
        .testTarget(
            name: "ContractKitTests",
            dependencies: ["ContractKit", "DomainKit"],
            resources: [
                .copy("Resources/Golden"),
            ]
        ),
        .testTarget(
            name: "DomainKitTests",
            dependencies: ["DomainKit"]
        ),
    ]
)
