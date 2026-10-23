//
//  SidebarStrings.swift
//  MarkEditMac
//
//  Created by Inkpot on 2026-10-23.
//

import Foundation

/// 侧栏本地化文案字典（中英繁三语支持）
enum SidebarStrings {
  /// 语言类型识别
  private enum Language {
    case zhHans
    case zhHant
    case en
  }

  /// 获取当前环境语言（优先匹配系统首选语言列表）
  private static var currentLanguage: Language {
    let languages = Locale.preferredLanguages
    for lang in languages {
      let lower = lang.lowercased()
      if lower.hasPrefix("zh-hant") || lower.hasPrefix("zh-tw") || lower.hasPrefix("zh-hk") {
        return .zhHant
      } else if lower.hasPrefix("zh") {
        return .zhHans
      } else if lower.hasPrefix("en") {
        return .en
      }
    }
    return .en
  }

  /// 侧栏文案枚举
  enum Key: String {
    case folders = "Sidebar.Folders"
    case outline = "Sidebar.Outline"
    case openFolder = "Sidebar.OpenFolder"
    case openFolderEllipsis = "Sidebar.OpenFolderEllipsis"
    case selectFolderPrompt = "Sidebar.SelectFolderPrompt"
    case noOutline = "Sidebar.NoOutline"
    case noFolderOpened = "Sidebar.NoFolderOpened"
    case sidebar = "Sidebar.Sidebar"
    case toggleSidebar = "Sidebar.ToggleSidebar"
    case reload = "Sidebar.Reload"

    var zhHans: String {
      switch self {
      case .folders: return "文件夹"
      case .outline: return "大纲"
      case .openFolder: return "打开文件夹"
      case .openFolderEllipsis: return "打开文件夹…"
      case .selectFolderPrompt: return "选择要浏览的文件夹"
      case .noOutline: return "暂无大纲"
      case .noFolderOpened: return "未打开文件夹"
      case .sidebar: return "侧栏"
      case .toggleSidebar: return "切换侧栏"
      case .reload: return "刷新"
      }
    }

    var zhHant: String {
      switch self {
      case .folders: return "檔案夾"
      case .outline: return "大綱"
      case .openFolder: return "打開檔案夾"
      case .openFolderEllipsis: return "開啟檔案夾…"
      case .selectFolderPrompt: return "選擇要瀏覽的檔案夾"
      case .noOutline: return "暫無大綱"
      case .noFolderOpened: return "未開啟檔案夾"
      case .sidebar: return "側欄"
      case .toggleSidebar: return "切換側欄"
      case .reload: return "重新整理"
      }
    }

    var en: String {
      switch self {
      case .folders: return "Folders"
      case .outline: return "Outline"
      case .openFolder: return "Open Folder"
      case .openFolderEllipsis: return "Open Folder…"
      case .selectFolderPrompt: return "Select a folder to browse"
      case .noOutline: return "No Outline"
      case .noFolderOpened: return "No Folder Opened"
      case .sidebar: return "Sidebar"
      case .toggleSidebar: return "Toggle Sidebar"
      case .reload: return "Reload"
      }
    }
  }

  /// 获取本地化文本：优先读取 Bundle 本地化，缺省则从内置中英繁映射表中返回
  static func localized(_ key: Key) -> String {
    let bundleString = Bundle.main.localizedString(forKey: key.rawValue, value: nil, table: nil)
    if bundleString != key.rawValue {
      return bundleString
    }

    switch currentLanguage {
    case .zhHans:
      return key.zhHans
    case .zhHant:
      return key.zhHant
    case .en:
      return key.en
    }
  }
}
