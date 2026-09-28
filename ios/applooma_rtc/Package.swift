// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "applooma_rtc",
    platforms: [
        .iOS("13.0")
    ],
    products: [
        .library(name: "applooma-rtc", targets: ["applooma_rtc"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        // Resolved by the Flutter tool to the media plugin package.
        .package(name: "flutter_webrtc", path: "../flutter_webrtc")
    ],
    targets: [
        .target(
            name: "applooma_rtc",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "flutter-webrtc", package: "flutter_webrtc"),
                .product(name: "WebRTC", package: "flutter_webrtc")
            ],
            cSettings: [
                .headerSearchPath("include/applooma_rtc")
            ],
            linkerSettings: [
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreVideo")
            ]
        )
    ]
)
