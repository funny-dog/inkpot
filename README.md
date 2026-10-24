# Inkpot

Inkpot 是面向 macOS 的轻量 Markdown 编辑器。基于 MarkEdit 的成熟实现独立构建，使用 AppKit、WKWebView 与 CodeMirror 6，面向日常中文和 Markdown 写作。

当前最低系统为 macOS 15。应用名为 Inkpot，Swift 模块名保留为 `MarkEdit`，bundle ID 为 `com.erhu.inkpot`。

- 实时／源码编辑，查找替换、常用格式操作和列表续写。
- 设置窗口（字体字号、默认打开模式、明暗外观、图片文件夹）、标题大纲、文件树、窗口与文件夹恢复和字数统计。
- 代码块按语言着色、本地图片、表格、公式、Mermaid、富文本粘贴以及 HTML／PDF 导出。
- UTF-8 与 BOM、混合行尾保护、关闭前保存确认、外部修改保护、本地恢复草稿与可选自动保存。

使用范围、已知限制与验收记录见 [功能说明](MVP/README.md)，后续计划见 [任务清单](MVP/NEXT-STEPS.md)。

## 构建与验证

使用仓库携带的 Yarn，不改变系统的 `xcode-select`：

```bash
cd CoreEditor
node .yarn/releases/yarn-4.18.0.cjs install --immutable
node .yarn/releases/yarn-4.18.0.cjs build
node .yarn/releases/yarn-4.18.0.cjs test --runInBand
cd ..
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swiftlint lint --strict --config .swiftlint.yml
xcodebuild build -project MVP/Inkpot.xcodeproj -scheme Inkpot \
  -destination 'platform=macOS' -derivedDataPath build/MVP \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

原生测试使用同一工程和 scheme，将 `build` 换成 `test`。局部修改用 `-only-testing:InkpotMVPTests/测试类/方法` 定向运行。SwiftLint 使用 0.65.1；CI 的安装来源与校验和固定在工作流中。首次构建 Web 资源后才能构建应用，公式与图表资源全部随应用打包，运行时不需要 CDN。

唯一安装位置为 `/Applications/Inkpot.app`。更新前正常退出旧实例并保留系统未保存提示，安装后移走构建目录中的临时应用副本。不自动改变文件关联。

## 仓库结构

- `MVP/`：唯一原生应用工程、原生测试与功能说明。
- `CoreEditor/mvp/`：当前 Web 编辑器与公式解析器。
- `CoreEditor/test/`：当前编辑器测试；与构建使用相同的官方 CodeMirror 依赖。
- `CoreEditor/scripts/`：离线渲染资源构建。
- `.github/workflows/`：当前应用的构建与验证。

旧 MarkEdit 分叉工程、旧桥接／扩展和重复编辑器已移出当前分支，不再单独归档；最后的完整版本是提交 `acde3b34`，仍在 `main` 历史中，需要时可用 `git show acde3b34:路径` 查看。收敛范围和重新评估见 [工程收敛记录](docs/engineering-consolidation.md)。

Inkpot 保留 [MarkEdit](https://github.com/MarkEdit-app/MarkEdit) 的版权与 MIT 许可；迁入的公式解析器保留 Joplin 来源说明。KaTeX、Mermaid 等第三方资源在构建时携带对应许可。
