// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TessyLink",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "TessyLink", targets: ["TessyLink"])
    ],
    targets: [
        // Objective-C shim exposing Apple's private CGVirtualDisplay APIs
        // through a clean, Swift-friendly interface.
        .target(
            name: "CVirtualDisplay",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "TessyLink",
            dependencies: ["CVirtualDisplay"],
            resources: [
                .copy("Resources/index.html")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreImage"),
                .linkedFramework("Network")
            ]
        )
    ]
)
