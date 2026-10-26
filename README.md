<div align="center">

# Inkpot

**面向 macOS 的轻量 Markdown 编辑器。**

**A lightweight Markdown editor for macOS.**

基于 MarkEdit 的成熟实现独立构建，使用 AppKit、WKWebView 与 CodeMirror 6 / Built independently on MarkEdit's mature implementation with AppKit, WKWebView, and CodeMirror 6

[English](#english) · [中文](#中文)

<br/>

<img src="assets/editor.png" alt="Inkpot 编辑器界面：左侧文件树，右侧实时预览的 Markdown 文档 / Inkpot editor: file tree on the left, Markdown document with live preview on the right" width="860" />

</div>

---

## 中文

Inkpot 是面向 macOS 的轻量 Markdown 编辑器。基于 MarkEdit 的成熟实现独立构建，使用 AppKit、WKWebView 与 CodeMirror 6，面向日常中文和 Markdown 写作。当前最低系统为 macOS 15；应用名为 Inkpot，Swift 模块名为 `Inkpot`，bundle ID 为 `com.erhu.inkpot`。

- 实时／源码编辑，查找替换、常用格式操作和列表续写。
- 设置窗口（字体字号、默认打开模式、明暗外观、图片文件夹）、标题大纲、文件树、窗口与文件夹恢复和字数统计。
- 代码块按语言着色、本地图片、表格、公式、Mermaid、富文本粘贴以及 HTML／PDF 导出。
- UTF-8 与 BOM、混合行尾保护、关闭前保存确认、外部修改保护、本地恢复草稿与可选自动保存。

使用范围与已知限制见 [功能说明](App/README.md)。

Windows 11 版本使用 WinUI 3 + WebView2，并复用同一编辑器；设置、文件树、大纲、图片、导出打印与恢复功能见 [Windows 文档](Windows/README.md)。

### 下载与安装

#### 方式一：Homebrew

```bash
brew install --cask funny-dog/tap/inkpot
```

Cask 安装 GitHub 正式 Release 并校验 SHA-256；应用为自签名、未经 Apple 公证，安装后会移除本应用的隔离属性，免去首次打开的手动放行。更新交给 Homebrew 管理：`brew update && brew upgrade --cask inkpot`（应用可自动下载更新包，但不自动安装；曾手动覆盖安装时执行一次升级命令即可对齐版本记录）。卸载与 zap 清理见 [tap 仓库说明](https://github.com/funny-dog/homebrew-tap)。

#### 方式二：DMG／ZIP 手动安装

从 [GitHub 最新正式版本](https://github.com/funny-dog/inkpot/releases/latest) 下载，校验 `.sha256` 后安装。自签名安装首次打开若被拦截，到「系统设置 → 隐私与安全性」点「仍要打开」。升级前正常退出并处理未保存文档，校验安装包后手动覆盖安装。

### 构建与验证

使用仓库携带的 Yarn，不改变系统的 `xcode-select`：

```bash
cd CoreEditor
node .yarn/releases/yarn-4.18.0.cjs install --immutable
node .yarn/releases/yarn-4.18.0.cjs build
node .yarn/releases/yarn-4.18.0.cjs test --runInBand
cd ..
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swiftlint lint --strict --config .swiftlint.yml
xcodebuild build -project App/Inkpot.xcodeproj -scheme Inkpot \
  -destination 'platform=macOS' -derivedDataPath build/Debug \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

原生测试使用同一工程和 scheme，将 `build` 换成 `test`。局部修改用 `-only-testing:InkpotTests/测试类/方法` 定向运行。SwiftLint 使用 0.65.1；CI 的安装来源与校验和固定在工作流中。首次构建 Web 资源后才能构建应用，公式与图表资源全部随应用打包，运行时不需要 CDN。

唯一安装位置为 `/Applications/Inkpot.app`。更新前正常退出旧实例并保留系统未保存提示，安装后移走构建目录中的临时应用副本。不自动改变文件关联。

### 仓库结构

- `App/`：macOS 原生应用工程、原生测试与功能说明。
- `Windows/`：Windows 原生应用、文件安全与工作区测试。
- `CoreEditor/editor/`：当前 Web 编辑器与公式解析器。
- `CoreEditor/test/`：当前编辑器测试；与构建使用相同的官方 CodeMirror 依赖。
- `CoreEditor/scripts/`：离线渲染资源构建。
- `.github/workflows/`：当前应用的构建与验证。

旧 MarkEdit 分叉工程、旧桥接／扩展和重复编辑器已移出当前工程，仅保留当前轻量实现。

### 许可

Inkpot 保留 [MarkEdit](https://github.com/MarkEdit-app/MarkEdit) 的版权与 MIT 许可；迁入的公式解析器保留 Joplin 来源说明。KaTeX、Mermaid 等第三方资源在构建时携带对应许可。

---

## English

Inkpot is a lightweight Markdown editor for macOS, built independently on MarkEdit's mature implementation with AppKit, WKWebView, and CodeMirror 6, for everyday writing in Chinese and Markdown. The minimum system requirement is macOS 15. The app is named Inkpot, the Swift module is `Inkpot`, and the bundle ID is `com.erhu.inkpot`.

- Live and source editing, find & replace, common formatting actions, and list continuation.
- Settings window (font and size, default open mode, light/dark appearance, image folder), heading outline, file tree, window and folder restoration, and word count.
- Syntax-highlighted code blocks, local images, tables, math, Mermaid, rich-text paste, and HTML/PDF export.
- UTF-8 and BOM, mixed line-ending protection, save confirmation on close, external modification protection, local draft recovery, and optional autosave.

See the feature notes (in Chinese) for scope and known limitations: [App/README.md](App/README.md).

The Windows preview uses WinUI 3 and WebView2 with the same editor. It includes a file tree, heading outline, basic settings, and document tabs; feature parity with macOS is still incomplete. See the [Windows guide](Windows/README.md) for build instructions and limitations.

### Download and Install

#### Method 1: Homebrew

```bash
brew install --cask funny-dog/tap/inkpot
```

The cask installs the official GitHub release and verifies its SHA-256. The app is self-signed and not notarized by Apple; the cask removes the quarantine attribute after installation, so no manual approval is needed on first launch. Updates are handled by Homebrew: `brew update && brew upgrade --cask inkpot` (the app can download updates automatically but does not install them; if you previously installed a build manually, running the upgrade command once aligns the version record). Uninstall and `zap` cleanup are described in the [tap repository](https://github.com/funny-dog/homebrew-tap).

#### Method 2: DMG/ZIP manual install

Download from the [latest GitHub release](https://github.com/funny-dog/inkpot/releases/latest), verify the `.sha256`, then install. If the self-signed app is blocked on first launch, go to "System Settings → Privacy & Security" and click "Open Anyway". Before upgrading, quit the app normally and take care of unsaved documents; verify the package, then replace the existing install manually.

### Build and Verify

Use the bundled Yarn and leave the system `xcode-select` untouched:

```bash
cd CoreEditor
node .yarn/releases/yarn-4.18.0.cjs install --immutable
node .yarn/releases/yarn-4.18.0.cjs build
node .yarn/releases/yarn-4.18.0.cjs test --runInBand
cd ..
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swiftlint lint --strict --config .swiftlint.yml
xcodebuild build -project App/Inkpot.xcodeproj -scheme Inkpot \
  -destination 'platform=macOS' -derivedDataPath build/Debug \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

Native tests use the same project and scheme with `build` replaced by `test`. For targeted runs after a local change, use `-only-testing:InkpotTests/TestClass/testMethod`. SwiftLint is pinned to 0.65.1; CI's download source and checksum are fixed in the workflow. The web assets must be built once before the app can build; the math and diagram resources ship inside the app, so no CDN is needed at runtime.

The only install location is `/Applications/Inkpot.app`. Before updating, quit the old instance normally and keep the system prompts for unsaved documents; after installing, remove the temporary app copy from the build directory. File associations are not changed automatically.

### Repository Structure

- `App/`: the only native app project, its native tests, and the feature notes.
- `CoreEditor/editor/`: the current web editor and math parser.
- `CoreEditor/test/`: current editor tests; uses the same official CodeMirror dependencies as the build.
- `CoreEditor/scripts/`: offline rendering asset build.
- `.github/workflows/`: build and verification for the current app.

The old MarkEdit fork project, legacy bridges/extensions, and duplicate editors have been removed; only the current lightweight implementation remains.

### License

Inkpot retains the copyright and MIT license of [MarkEdit](https://github.com/MarkEdit-app/MarkEdit); the imported math parser keeps its Joplin provenance. Third-party assets such as KaTeX and Mermaid carry their corresponding licenses at build time.
