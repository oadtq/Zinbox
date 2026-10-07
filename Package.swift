// swift-tools-version: 6.0
import PackageDescription

// Chromium (CEF) lives in vendor/cef, fetched by scripts/fetch-cef.sh.
// Its framework is loaded at runtime, so nothing links against it directly;
// the static wrapper library is what both CEF targets link.
let cefCXX: [CXXSetting] = [
    .headerSearchPath("../../vendor/cef"),
    .define("__STDC_CONSTANT_MACROS"),
    .define("__STDC_FORMAT_MACROS"),
    .define("CEF_USE_SANDBOX"),
    .unsafeFlags(["-fno-rtti", "-fno-strict-aliasing", "-fobjc-arc"]),
]
let cefLink: [LinkerSetting] = [
    .unsafeFlags(["-Lvendor/cef/build/libcef_dll_wrapper", "-lcef_dll_wrapper"]),
    .linkedFramework("AppKit"),
]

let package = Package(
    name: "Zinbox",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Zinbox",
            dependencies: ["ZinboxCEF"],
            path: "Sources/Zinbox",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The Objective-C++ side of Chromium: the NSApplication subclass CEF
        // needs, startup, and an NSView per Chromium service.
        .target(
            name: "ZinboxCEF",
            path: "Sources/ZinboxCEF",
            cxxSettings: cefCXX,
            linkerSettings: cefLink
        ),
        // Chromium's renderer, GPU and utility processes run this.
        .executableTarget(
            name: "ZinboxHelper",
            path: "Sources/ZinboxHelper",
            cxxSettings: cefCXX,
            linkerSettings: cefLink
        ),
    ],
    cxxLanguageStandard: .cxx20
)
