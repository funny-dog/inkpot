//
//  AppTheme.swift
//  MarkEditMac
//
//  Created by cyan on 12/17/22.
//

import AppKit

struct AppTheme {
  let isDark: Bool
  let editorTheme: String
  // Pre-defined colors to style the window for initial launch
  let windowBackground: NSColor
  let colorPattern: [String]
  // Enables editor-colored tinting for translucent surfaces.
  let prefersTintedColors: Bool

  @MainActor static var current: Self {
    NSApplication.shared.isDarkMode ? darkTheme : lightTheme
  }

  static func withName(_ name: String) -> Self {
    allCases.first { $0.editorTheme == name } ?? GitHubLight
  }

  /// Get a "resolved" appearance name based on the current effective appearance.
  @MainActor var resolvedAppearance: NSAppearance? {
    NSAppearance(named: NSApp.effectiveAppearance.resolvedName(isDarkMode: isDark))
  }

  /// Illustration of the theme's color pattern.
  @MainActor var patternImage: NSImage {
    Self.patternImage(colorPattern: colorPattern, isDark: isDark)
  }

  @MainActor
  static func patternImage(colorPattern: [String], isDark: Bool) -> NSImage {
    let length = 8.0
    let spacing = 2.5
    let padding = 3.0

    let allColors = colorPattern.map { NSColor(hexCode: UInt32($0.dropFirst(), radix: 16) ?? 0) }
    let circleColors = allColors.dropFirst()

    let size = CGSize(
      width: Double(circleColors.count) * length + Double(max(circleColors.count - 1, 0)) * spacing + padding * 2,
      height: length + padding * 2
    )

    return NSImage(size: CGSize(width: size.width + 4, height: size.height), flipped: false) { _ in
      let backgroundRect = CGRect(origin: .zero, size: size)
      let radius = size.height * 0.5
      (allColors.first ?? .clear).setFill()
      NSBezierPath(roundedRect: backgroundRect, xRadius: radius, yRadius: radius).fill()

      NSColor.black.withAlphaComponent(0.4).setStroke()
      let border = NSBezierPath(
        roundedRect: backgroundRect.insetBy(dx: 0.25, dy: 0.25),
        xRadius: radius - 0.25,
        yRadius: radius - 0.25
      )

      border.lineWidth = 0.5
      border.stroke()

      for (index, color) in circleColors.enumerated() {
        color.setFill()

        let rect = CGRect(
          x: padding + Double(index) * (length + spacing),
          y: padding,
          width: length,
          height: length
        )

        // Bright circles appear larger on dark backgrounds
        let inset = isDark ? 0.25 : 0.0
        NSBezierPath(ovalIn: rect.insetBy(dx: inset, dy: inset)).fill()
      }

      return true
    }
  }

  /// Trigger theme update for all editors.
  @MainActor
  func updateAppearance(animateChanges: Bool = false) {
    EditorPreloader.shared.viewControllers().forEach {
      $0.setTheme(self, animated: animateChanges)
    }
  }
}

// MARK: - Themes

extension AppTheme: CaseIterable, Hashable {
  static var allCases: [AppTheme] {
    [
      GitHubLight, GitHubDark,
      XcodeLight, XcodeDark,
    ]
  }

  static var GitHubLight: Self {
    Self(
      isDark: false,
      editorTheme: "github-light",
      windowBackground: NSColor(hexCode: 0xffffff),
      colorPattern: ["#ffffff", "#1f2328", "#0550ae", "#cf222e", "#0a3069", "#6e7781"],
      prefersTintedColors: false
    )
  }

  static var GitHubDark: Self {
    Self(
      isDark: true,
      editorTheme: "github-dark",
      windowBackground: NSColor(hexCode: 0x0d1117),
      colorPattern: ["#0d1117", "#e6edf3", "#79c0ff", "#ff7b72", "#a5d6ff", "#8b949e"],
      prefersTintedColors: true
    )
  }

  static var XcodeLight: Self {
    Self(
      isDark: false,
      editorTheme: "xcode-light",
      windowBackground: NSColor(hexCode: 0xffffff),
      colorPattern: ["#ffffff", "#000000", "#0b4f79", "#9b2393", "#c41a16", "#5d6c79"],
      prefersTintedColors: false
    )
  }

  static var XcodeDark: Self {
    Self(
      isDark: true,
      editorTheme: "xcode-dark",
      windowBackground: NSColor(hexCode: 0x1f1f24),
      colorPattern: ["#1f1f24", "#dedede", "#5dd8ff", "#fc5fa3", "#fc6a5d", "#6c7986"],
      prefersTintedColors: true
    )
  }

  var displayName: String {
    switch self {
    case Self.GitHubLight, Self.GitHubDark:
      return "GitHub"
    case Self.XcodeLight, Self.XcodeDark:
      return "Xcode"
    default:
      fatalError("Invalid theme was found")
    }
  }
}

// MARK: - Private

@MainActor
private extension AppTheme {
  static var lightTheme: Self {
    withName(AppPreferences.Editor.lightTheme)
  }

  static var darkTheme: Self {
    withName(AppPreferences.Editor.darkTheme)
  }
}
