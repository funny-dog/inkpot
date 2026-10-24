import AppKit
import XCTest

@MainActor
final class SidebarTests: XCTestCase {
  func testTabBarSwitchesSidebarContent() throws {
    let sidebar = SidebarViewController()
    _ = sidebar.view
    XCTAssertEqual(sidebar.tabs.titles, ["文件", "大纲", "搜索"])
    XCTAssertEqual(sidebar.tabs.selectedIndex, 1)
    XCTAssertEqual(sidebar.content, .outline)
    // 点按“文件”：切换选中项并显示文件树页。
    let buttons = sidebar.tabs.subviews.flatMap(\.subviews).compactMap { $0 as? SidebarTabBar.Tab }
    XCTAssertEqual(buttons.count, 3)
    buttons[0].performClick(nil)
    XCTAssertEqual(sidebar.content, .files)
    XCTAssertEqual(sidebar.tabs.selectedIndex, 0)
    XCTAssertTrue(buttons[0].isChosen)
    XCTAssertFalse(buttons[1].isChosen)
    XCTAssertEqual(buttons[0].accessibilityRole(), .radioButton)
    // 菜单或快捷键切换时，切换条同步选中。
    sidebar.show(.search)
    XCTAssertEqual(sidebar.tabs.selectedIndex, 2)
    XCTAssertTrue(buttons[2].isChosen)
  }

  func testSelectedRowUsesAccentLabel() {
    let row = SidebarRowView()
    let label = SidebarLabel(labelWithString: "为什么要写")
    label.baseColor = .secondaryLabelColor
    label.baseWeight = .regular
    row.addSubview(label)
    XCTAssertEqual(label.textColor, .secondaryLabelColor)
    row.isSelected = true
    XCTAssertEqual(label.textColor, .inkpotAccent)
    XCTAssertEqual(label.font?.fontDescriptor.symbolicTraits.contains(.bold), true)
    XCTAssertEqual(row.interiorBackgroundStyle, .normal)
    row.isSelected = false
    XCTAssertEqual(label.textColor, .secondaryLabelColor)
  }

  func testOutlineUsesSidebarRowsAndHierarchyStyles() {
    let outline = OutlineViewController()
    _ = outline.view
    outline.update([
      DocumentHeading(id: 1, from: 0, to: 4, level: 1, title: "计划"),
      DocumentHeading(id: 2, from: 5, to: 9, level: 3, title: "选题"),
    ], active: 2)
    XCTAssertTrue(outline.outlineView(outline.outlineView, rowViewForItem: NSObject()) is SidebarRowView)
    let top = (outline.outlineView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)?.textField as? SidebarLabel
    XCTAssertEqual(top?.baseWeight, .semibold)
    let deep = (outline.outlineView.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NSTableCellView)?.textField as? SidebarLabel
    XCTAssertEqual(deep?.baseColor, .secondaryLabelColor)
    XCTAssertEqual(outline.outlineView.selectedRow, 1)
  }
}
