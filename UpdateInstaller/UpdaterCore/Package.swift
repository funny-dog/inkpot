// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "UpdaterCore",
  platforms: [
    .macOS(.v26),
  ],
  products: [
    .library(
      name: "UpdaterCore",
      targets: ["UpdaterCore"]
    ),
  ],
  dependencies: [
  ],
  targets: [
    .target(
      name: "UpdaterCore",
      path: "Sources"
    ),

    .testTarget(
      name: "UpdaterCoreTests",
      dependencies: ["UpdaterCore"],
      path: "Tests"
    ),
  ]
)
