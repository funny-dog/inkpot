// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "Modules",
  platforms: [
    .macOS(.v26),
  ],
  products: [
    .library(
      name: "SharedUI",
      targets: ["SharedUI"]
    ),
    .library(
      name: "QuickSearchUI",
      targets: ["QuickSearchUI"]
    ),
    .library(
      name: "QuickSearchCore",
      targets: ["QuickSearchCore"]
    ),
    .library(
      name: "AppKitExtensions",
      targets: ["AppKitExtensions"]
    ),
    .library(
      name: "DiffKit",
      targets: ["DiffKit"]
    ),
    .library(
      name: "ExtensionCore",
      targets: ["ExtensionCore"]
    ),
    .library(
      name: "FileDrop",
      targets: ["FileDrop"]
    ),
    .library(
      name: "FileVersion",
      targets: ["FileVersion"]
    ),
    .library(
      name: "FontPicker",
      targets: ["FontPicker"]
    ),
    .library(
      name: "SettingsUI",
      targets: ["SettingsUI"]
    ),
    .library(
      name: "Statistics",
      targets: ["Statistics"]
    ),
    .library(
      name: "TextBundle",
      targets: ["TextBundle"]
    ),
    .library(
      name: "TextCompletion",
      targets: ["TextCompletion"]
    ),
  ],
  dependencies: [
    .package(path: "../MarkEditCore"),
    .package(path: "../MarkEditKit"),
  ],
  targets: [
    .target(
      name: "QuickSearchUI",
      dependencies: ["QuickSearchCore", "AppKitExtensions"],
      path: "Sources/QuickSearchUI"
    ),
    .target(
      name: "QuickSearchCore",
      path: "Sources/QuickSearchCore"
    ),
    .target(
      name: "SharedUI",
      dependencies: ["AppKitExtensions"],
      path: "Sources/SharedUI"
    ),
    .target(
      name: "AppKitExtensions",
      path: "Sources/AppKitExtensions"
    ),
    .target(
      name: "DiffKit",
      path: "Sources/DiffKit",
      resources: [
        .process("Resources"),
      ]
    ),
    .target(
      name: "ExtensionCore",
      dependencies: ["AppKitExtensions", "MarkEditCore", "MarkEditKit"],
      path: "Sources/ExtensionCore"
    ),
    .target(
      name: "FileDrop",
      dependencies: ["AppKitExtensions", "MarkEditKit", "TextBundle"],
      path: "Sources/FileDrop"
    ),
    .target(
      name: "FileVersion",
      dependencies: ["SharedUI", "MarkEditKit", "DiffKit"],
      path: "Sources/FileVersion"
    ),
    .target(
      name: "FontPicker",
      dependencies: ["AppKitExtensions"],
      path: "Sources/FontPicker"
    ),
    .target(
      name: "SettingsUI",
      dependencies: ["AppKitExtensions"],
      path: "Sources/SettingsUI"
    ),
    .target(
      name: "Statistics",
      dependencies: ["AppKitExtensions", "MarkEditKit"],
      path: "Sources/Statistics"
    ),
    .target(
      name: "TextBundle",
      path: "Sources/TextBundle"
    ),
    .target(
      name: "TextCompletion",
      dependencies: ["AppKitExtensions"],
      path: "Sources/TextCompletion"
    ),

    .testTarget(
      name: "ModulesTests",
      dependencies: [
        "SharedUI",
        "QuickSearchUI",
        "QuickSearchCore",
        "AppKitExtensions",
        "ExtensionCore",
        "FileDrop",
        "Statistics",
        "TextBundle",
        "MarkEditKit",
      ],
      path: "Tests",
      resources: [
        .copy("Files/sample.textbundle"),
      ]
    ),
  ]
)
