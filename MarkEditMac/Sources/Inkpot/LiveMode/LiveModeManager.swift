//
//  LiveModeManager.swift
//  MarkEditMac
//
//  Created by Inkpot on 2026-10-23.
//

import AppKit
import ExtensionCore

/// 实时模式（Live Mode / 所见即所得）管理器
@MainActor
public enum LiveModeManager {
  /// 标记是否已提示过 MarkEdit-preview 冲突（依据设计规范 D14，仅首次启动提示一次）
  @Storage(key: "inkpot.live-mode.warned-preview-conflict", defaultValue: false)
  private static var hasWarnedPreviewConflict: Bool

  /// 检测用户是否安装并启用了 markedit-preview 扩展
  public static var isPreviewExtensionActive: Bool {
    ExtensionConfig.installed.contains {
      ($0.id == "markedit-preview" || $0.file.contains("markedit-preview")) && ($0.enabled ?? true)
    }
  }

  /// 依据设计规范 D14：检测到用户启用了 markedit-preview 扩展时，实时模式照常工作，
  /// 但在首次启动时提示用户关闭该扩展的 Mixed 模式以避免重复装饰。
  public static func checkExtensionConflictIfNeeded() {
    guard !hasWarnedPreviewConflict else {
      return
    }

    if isPreviewExtensionActive {
      hasWarnedPreviewConflict = true

      let alert = NSAlert()
      alert.alertStyle = .informational
      alert.messageText = Localized.Inkpot.previewConflictTitle
      alert.informativeText = Localized.Inkpot.previewConflictMessage
      alert.addButton(withTitle: Localized.General.done)
      alert.runModal()
    }
  }
}
