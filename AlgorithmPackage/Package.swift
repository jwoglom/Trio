// swift-tools-version:5.9
import PackageDescription

// Builds the oref algorithm as a standalone, macOS-capable module
// so the algorithm test suite can run with `swift test`
//
// This is a "shadow" package: it compiles the *existing* files in
// place rather than owning its own copy, so there is exactly one
// copy of every source file and the Xcode app target keeps
// compiling the same ones. `Sources` and `OpenAPSSwiftTests` are
// symlinks back to Trio/Sources and TrioTests/OpenAPSSwiftTests.
//
// This lives in a subdirectory, not the repo root, because Xcode
// prefers a root Package.swift over Trio.xcworkspace when opening
// a folder — a root manifest makes `xed .` open the package and
// hides every app scheme.
//
// Usage:
//   swift test --package-path AlgorithmPackage
//   swift test --package-path AlgorithmPackage --filter IobGenerateTests

let algorithmModels = [
    "Autosens",
    "BGTargets",
    "BasalProfileEntry",
    "BloodGlucose",
    "CarbRatios",
    "CarbsEntry",
    "Determination",
    "IOBEntry",
    "InsulinSensitivities",
    "Override",
    "Preferences",
    "PumpHistoryEvent",
    "PumpSettings",
    "TDD",
    "TempBasal",
    "TempTarget",
    "TrioCustomOrefVariables"
].map { "Models/\($0).swift" }

let algorithmHelpers = [
    "LinuxCompat",
    "ConvenienceExtensions",
    "Decimal+Extensions",
    "Formatters",
    "JSON",
    "Rounding",
    "String+Extensions",
    "TherapySettingsUtil",
    "TimeInterval+Convenience"
].map { "Helpers/\($0).swift" }

// Units outside the algorithm that are Foundation-only, so they build and test
// on Linux too. Kept as a separate list from the algorithm's own sources: the
// algorithm suite is what gates dosing changes, this is everything else that
// happens to be portable.
let portableSources = [
    "Models/GlucoseAlerts/DayNightOptions.swift",
    "Models/GlucoseAlerts/DeviceAlertSeverity.swift",
    "Models/GlucoseAlerts/GlucoseAlert.swift",
    "Models/GlucoseAlerts/GlucoseAlertConfiguration.swift",
    "Models/GlucoseAlerts/GlucoseAlertType.swift",
    "Modules/Home/View/MultiUsePanelState.swift",
    "Services/Alerts/ForecastedGlucoseEvaluator.swift",
    "Services/Network/Nightscout/NightscoutUploadPipeline.swift",
    "Services/Network/Nightscout/NightscoutUploadSerializer.swift",
    "Services/Network/TidepoolUploadSerializer.swift"
]

let package = Package(
    name: "TrioAlgorithm",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Trio", targets: ["Trio"])
    ],
    targets: [
        .target(
            name: "Trio",
            path: "Sources",
            sources: [
                "APS/OpenAPSSwift",
                "APS/Extensions/DecimalExtensions.swift"
            ] + algorithmModels + algorithmHelpers + portableSources,
            swiftSettings: [.define("TRIO_ALGORITHM_PACKAGE")]
        ),
        .testTarget(
            name: "OpenAPSSwiftTests",
            dependencies: ["Trio"],
            path: "OpenAPSSwiftTests",
            // goldens are read from disk via #filePath, not from the test bundle
            exclude: ["Parity/goldens"],
            resources: [.copy("json")],
            swiftSettings: [.define("TRIO_ALGORITHM_PACKAGE")]
        ),
        // Tests for the portable non-algorithm units. Each file is a symlink to
        // the real test under TrioTests/, so there is one copy and the app test
        // target keeps running the same tests.
        .testTarget(
            name: "PortableTests",
            dependencies: ["Trio"],
            path: "PortableTests",
            swiftSettings: [.define("TRIO_ALGORITHM_PACKAGE")]
        )
    ]
)
