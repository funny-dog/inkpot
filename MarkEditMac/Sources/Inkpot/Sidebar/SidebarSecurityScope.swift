//
//  SidebarSecurityScope.swift
//  MarkEditMac
//
//  Created by Inkpot on 2026-10-23.
//

import Foundation

/// 文件夹安全访问作用域管理器（管理沙盒权限与生命周期）
final class SidebarSecurityScope {
  /// 当前访问的文件夹 URL
  private(set) var folderURL: URL?

  /// 是否正在持有安全作用域访问权限
  private var isAccessing: Bool = false

  /// 开始访问指定的文件夹 URL
  /// - Parameter url: 用户通过 NSOpenPanel 选择的文件夹路径
  /// - Returns: 是否成功获取安全作用域访问权限
  @discardableResult
  func startAccessing(url: URL) -> Bool {
    stopAccessing()

    let success = url.startAccessingSecurityScopedResource()
    self.isAccessing = success
    self.folderURL = url
    return success
  }

  /// 停止访问当前文件夹，释放沙盒资源占用
  func stopAccessing() {
    if isAccessing, let folderURL {
      folderURL.stopAccessingSecurityScopedResource()
      isAccessing = false
    }
    folderURL = nil
  }

  deinit {
    stopAccessing()
  }
}
