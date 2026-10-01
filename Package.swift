// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "Pip",
  defaultLocalization: "en",
  platforms: [
    .macOS("15.2")
  ],
  products: [
    .executable(
      name: "Pip",
      targets: ["Pip"]
    )
  ],
  targets: [
    .executableTarget(
      name: "Pip",
      path: "Sources/Pip",
      resources: [
        .copy("Resources/Video.metal"),
        .process("Localization"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6)
      ],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("Carbon"),
        .linkedFramework("CoreVideo"),
        .linkedFramework("Metal"),
        .linkedFramework("MetalKit"),
        .linkedFramework("QuartzCore"),
        .linkedFramework("ScreenCaptureKit"),
        .linkedFramework("ServiceManagement"),
      ]
    )
  ]
)
