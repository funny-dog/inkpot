import AppKit

extension EditorViewController {
  var inkpotSidebar: SidebarViewController? {
    children.compactMap { $0 as? SidebarViewController }.first
  }

  var inkpotSidebarWidth: CGFloat {
    inkpotSidebar?.view.isHidden == false ? min(220, view.bounds.width / 2) : 0
  }

  func installInkpotSidebar() {
    let sidebar = SidebarViewController()
    sidebar.hostViewController = self
    addChild(sidebar)
    sidebar.view.isHidden = true
    view.addSubview(sidebar.view)
  }

  func layoutInkpotSidebar() {
    let height = view.bounds.height - view.safeAreaInsets.top
    inkpotSidebar?.view.frame = CGRect(x: 0, y: 0, width: inkpotSidebarWidth, height: height)
  }

  @objc func openInkpotFolder(_ sender: Any?) {
    inkpotSidebar?.view.isHidden = false
    view.needsLayout = true
    inkpotSidebar?.openFolderPanel(sender)
  }

  @objc func toggleInkpotSidebar(_ sender: Any?) {
    guard let sidebar = inkpotSidebar else { return }
    sidebar.view.isHidden.toggle()
    if !sidebar.view.isHidden { sidebar.refreshContent() }
    view.needsLayout = true
    if sidebar.view.isHidden { startTextEditing() }
  }
}
