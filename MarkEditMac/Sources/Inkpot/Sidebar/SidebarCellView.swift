//
//  SidebarCellView.swift
//  MarkEditMac
//
//  Created by Inkpot on 2026-10-23.
//

import AppKit
import MarkEditKit

/// 侧栏单元格视图（用于展示文件树节点及大纲标题）
final class SidebarCellView: NSTableCellView {
  static let identifier = NSUserInterfaceItemIdentifier("SidebarCellView")

  /// 自定义图标视图
  private let customImageView: NSImageView = {
    let imageView = NSImageView()
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.imageScaling = .scaleProportionallyDown
    return imageView
  }()

  /// 自定义文本标签
  private let customTextField: NSTextField = {
    let textField = NSTextField(labelWithString: "")
    textField.translatesAutoresizingMaskIntoConstraints = false
    textField.lineBreakMode = .byTruncatingMiddle
    textField.isEditable = false
    textField.isSelectable = false
    textField.isBordered = false
    textField.drawsBackground = false
    textField.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
    return textField
  }()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setUpUI()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setUpUI()
  }

  private func setUpUI() {
    self.imageView = customImageView
    self.textField = customTextField

    addSubview(customImageView)
    addSubview(customTextField)

    NSLayoutConstraint.activate([
      customImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
      customImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
      customImageView.widthAnchor.constraint(equalToConstant: 16),
      customImageView.heightAnchor.constraint(equalToConstant: 16),

      customTextField.leadingAnchor.constraint(equalTo: customImageView.trailingAnchor, constant: 6),
      customTextField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
      customTextField.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  /// 配置为文件树节点显示内容
  func configure(with item: FileTreeItem) {
    if item.isOpenFolderAction {
      customImageView.image = NSImage(
        systemSymbolName: "folder.badge.plus",
        accessibilityDescription: item.displayName
      )
      customTextField.stringValue = item.displayName
      customTextField.textColor = .controlAccentColor
      return
    }

    customTextField.textColor = .labelColor
    customTextField.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
    customTextField.stringValue = item.displayName

    customImageView.image = NSWorkspace.shared.icon(forFile: item.url.path)
  }

  /// 配置为大纲节点显示内容
  func configure(with item: OutlineItem) {
    let heading = item.headingInfo
    let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
    customImageView.image = NSImage(
      systemSymbolName: "text.alignleft",
      accessibilityDescription: heading.title
    )?.withSymbolConfiguration(symbolConfig)

    let fontSize = max(11, 14.0 - Double(heading.level))
    let fontWeight: NSFont.Weight = heading.level <= 2 ? .medium : .regular
    customTextField.font = .systemFont(ofSize: fontSize, weight: fontWeight)
    customTextField.stringValue = heading.title

    if heading.selected {
      customTextField.textColor = .controlAccentColor
    } else {
      customTextField.textColor = .labelColor
    }
  }
}
