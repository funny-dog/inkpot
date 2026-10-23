//
//  SidebarItem.swift
//  MarkEditMac
//
//  Created by Inkpot on 2026-10-23.
//

import AppKit
import MarkEditKit

// MARK: - 文件树节点数据模型

/// 文件树节点（支持懒加载、符号链接防环检测与隐藏文件过滤）
final class FileTreeItem: NSObject {
  /// 文件或目录路径
  let url: URL

  /// 是否为目录（包括符号链接指向的目录）
  let isDirectory: Bool

  /// 是否为符号链接
  let isSymlink: Bool

  /// 规范化真实路径（用于检测符号链接循环）
  let canonicalPath: String

  /// 祖先真实路径集合（用于检测循环引用）
  let ancestorPaths: Set<String>

  /// 是否为特殊的“打开文件夹…”操作项
  let isOpenFolderAction: Bool

  /// 子节点列表（nil 表示尚未加载，实现按需懒加载）
  private(set) var children: [FileTreeItem]?

  /// 父节点引用
  weak var parent: FileTreeItem?

  /// 显示名称
  var displayName: String {
    if isOpenFolderAction {
      return SidebarStrings.localized(.openFolderEllipsis)
    }
    return url.lastPathComponent
  }

  /// 初始化普通文件或目录项
  init(
    url: URL,
    isDirectory: Bool,
    isSymlink: Bool,
    canonicalPath: String,
    ancestorPaths: Set<String> = [],
    isOpenFolderAction: Bool = false
  ) {
    self.url = url
    self.isDirectory = isDirectory
    self.isSymlink = isSymlink
    self.canonicalPath = canonicalPath
    self.ancestorPaths = ancestorPaths
    self.isOpenFolderAction = isOpenFolderAction
    super.init()
  }

  /// 构造特殊的“打开文件夹…”快捷操作节点
  static func makeOpenFolderActionItem() -> FileTreeItem {
    FileTreeItem(
      url: URL(fileURLWithPath: "/"),
      isDirectory: false,
      isSymlink: false,
      canonicalPath: "/",
      isOpenFolderAction: true
    )
  }

  /// 重置子节点缓存（在需要重新刷新时调用）
  func invalidateChildren() {
    children = nil
  }

  /// 懒加载并获取子节点（已加载则直接返回，未加载则遍历单层目录）
  func loadChildrenIfNeeded() -> [FileTreeItem] {
    if let children {
      return children
    }

    // 操作项与普通文件没有子节点
    guard isDirectory, !isOpenFolderAction else {
      children = []
      return []
    }

    let fileManager = FileManager.default
    let showHidden = AppPreferences.General.showHiddenFiles

    var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
    if !showHidden {
      options.insert(.skipsHiddenFiles)
    }

    guard let childURLs = try? fileManager.contentsOfDirectory(
      at: url,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey],
      options: options
    ) else {
      children = []
      return []
    }

    // 记录当前目录真实路径到祖先链中，供子级检测符号链接循环
    var nextAncestors = ancestorPaths
    nextAncestors.insert(canonicalPath)

    // 数组元素类型显式写成 FileTreeItem：类内的 Self 是动态类型，无法作为元素类型使用
    // swiftlint:disable:next prefer_self_in_static_references
    var directories = [FileTreeItem]()
    // swiftlint:disable:next prefer_self_in_static_references
    var files = [FileTreeItem]()

    for childURL in childURLs {
      let fileName = childURL.lastPathComponent

      // 沿用隐藏文件偏好设置
      if !showHidden && fileName.hasPrefix(".") {
        continue
      }

      let resourceValues = try? childURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey])
      if !showHidden && (resourceValues?.isHidden == true) {
        continue
      }

      let isSymlink = resourceValues?.isSymbolicLink ?? false
      let realURL = childURL.resolvingSymlinksInPath()
      let realPath = realURL.path

      var isDir: ObjCBool = false
      let exists = fileManager.fileExists(atPath: realPath, isDirectory: &isDir)
      guard exists else {
        continue
      }

      let isDirectory = isDir.boolValue

      // 核心检测：若为目录且其真实路径已在祖先路径中，说明出现符号链接循环引用，直接跳过
      if isDirectory {
        if isSymlink && nextAncestors.contains(realPath) {
          continue
        }

        let item = FileTreeItem(
          url: childURL,
          isDirectory: true,
          isSymlink: isSymlink,
          canonicalPath: realPath,
          ancestorPaths: nextAncestors
        )
        item.parent = self
        directories.append(item)
      } else {
        let item = FileTreeItem(
          url: childURL,
          isDirectory: false,
          isSymlink: isSymlink,
          canonicalPath: realPath,
          ancestorPaths: nextAncestors
        )
        item.parent = self
        files.append(item)
      }
    }

    // 文件夹优先，同类型按名称自然排序
    directories.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    files.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

    let result = directories + files
    self.children = result
    return result
  }
}

// MARK: - 文档大纲节点数据模型

/// 文档大纲树节点（包装 HeadingInfo，支持层级嵌套与展开）
final class OutlineItem: NSObject {
  /// 标题元数据
  let headingInfo: HeadingInfo

  /// 子标题列表
  private(set) var children: [OutlineItem] = []

  /// 父标题引用
  weak var parent: OutlineItem?

  init(headingInfo: HeadingInfo) {
    self.headingInfo = headingInfo
    super.init()
  }

  /// 添加子标题
  func addChild(_ child: OutlineItem) {
    child.parent = self
    children.append(child)
  }

  /// 将 EditorViewController.tableOfContents 返回的扁平 HeadingInfo 构建为嵌套树
  static func buildTree(from headings: [HeadingInfo]) -> [OutlineItem] {
    // 数组元素类型显式写成 OutlineItem：类内的 Self 是动态类型，无法作为元素类型使用
    // swiftlint:disable:next prefer_self_in_static_references
    var rootItems = [OutlineItem]()
    // swiftlint:disable:next prefer_self_in_static_references
    var stack = [OutlineItem]()

    for heading in headings {
      let item = OutlineItem(headingInfo: heading)

      // 弹出栈中同级或更深层级的项，找到其直接父标题
      while let top = stack.last, top.headingInfo.level >= heading.level {
        stack.removeLast()
      }

      if let parent = stack.last {
        parent.addChild(item)
      } else {
        rootItems.append(item)
      }

      stack.append(item)
    }

    return rootItems
  }
}
