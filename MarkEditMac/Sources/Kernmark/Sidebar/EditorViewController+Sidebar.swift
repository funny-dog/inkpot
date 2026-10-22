import AppKit

extension EditorViewController {
  var kernmarkSidebar: SidebarViewController? {
    children.compactMap { $0 as? SidebarViewController }.first
  }

  var kernmarkSidebarWidth: CGFloat {
    kernmarkSidebar?.view.isHidden == false ? min(220, view.bounds.width / 2) : 0
  }

  func installKernmarkSidebar() {
    let sidebar = SidebarViewController()
    sidebar.hostViewController = self
    addChild(sidebar)
    sidebar.view.isHidden = true
    view.addSubview(sidebar.view)
  }

  func layoutKernmarkSidebar() {
    let height = view.bounds.height - view.safeAreaInsets.top
    kernmarkSidebar?.view.frame = CGRect(x: 0, y: 0, width: kernmarkSidebarWidth, height: height)
  }

  @objc func openKernmarkFolder(_ sender: Any?) {
    kernmarkSidebar?.view.isHidden = false
    view.needsLayout = true
    kernmarkSidebar?.openFolderPanel(sender)
  }

  @objc func toggleKernmarkSidebar(_ sender: Any?) {
    guard let sidebar = kernmarkSidebar else { return }
    sidebar.view.isHidden.toggle()
    if !sidebar.view.isHidden { sidebar.refreshContent() }
    view.needsLayout = true
    if sidebar.view.isHidden { startTextEditing() }
  }
}
