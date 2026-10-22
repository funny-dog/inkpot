// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "MarkEditCore",
  platforms: [
    .iOS(.v26),
    .macOS(.v26),
  ],
  products: [
    .library(
      name: "MarkEditCore",
      targets: ["MarkEditCore"]
    ),
  ],
  dependencies: [
  ],
  targets: [
    .target(
      name: "MarkEditCore",
      path: "Sources"
    ),

    .testTarget(
      name: "MarkEditCoreTests",
      dependencies: ["MarkEditCore"],
      path: "Tests",
      resources: [
        .process("Files"),
      ]
    ),
  ]
)
