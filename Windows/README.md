# Inkpot Windows

C# / WinUI 3 原生窗口以 WebView2 承载仓库共用的 `CoreEditor/`，不复制编辑器源码。Windows 接入与 macOS 对应的设置、文档管理、写作显示、图片和导出能力，界面提供中英文。

## 界面布局

与 macOS 版保持同一套布局：菜单栏右侧放侧栏、专注模式和源码模式三个按钮，对应 macOS 工具栏；侧栏顶部用分段按钮切换文件、大纲和搜索，未打开文件夹或没有标题时显示带说明的空状态；底部状态栏左侧是编辑模式和保存状态，右侧是字数统计。侧栏选中行和按钮选中态使用与 macOS 一致的墨蓝强调色（深色模式下为浅蓝），其余控件沿用 Windows 原生 Fluent 样式。设置窗口包含通用、编辑、外观和关于页面。

## 功能与入口

| 功能 | Windows 入口与行为 |
| --- | --- |
| 设置与关于 | 文件 → 设置（Ctrl+,），包含通用、编辑、外观、关于；帮助 → 关于 Inkpot 直接进入关于页，可查看版本与离线第三方许可 |
| 文件管理 | 打开文件夹（Ctrl+Alt+O）、文件树（Ctrl+Shift+E）、最近文件/文件夹；文件树按自然顺序懒加载，右键新建、复制、重命名、移到回收站、复制路径或在资源管理器中显示 |
| 文件夹搜索 | Ctrl+Shift+F；后台递归搜索 Markdown/文本，最多显示 1000 处匹配，点击跳转并选中命中内容 |
| 标题大纲 | Ctrl+Shift+O；层级导航与正文当前标题同步；侧栏可拖动调整宽度 |
| 多窗口与标签 | Ctrl+N 新窗口，Ctrl+Alt+N 新标签，Ctrl+Tab / Ctrl+Shift+Tab 切换；窗口菜单可拆分、合并、隐藏标签栏、查看所有标签；移窗保留编辑器和撤销历史 |
| 写作显示 | 显示菜单提供源码模式（Ctrl+Shift+M）、专注模式（F8）、打字机模式（F9）、字体字号、缩放和全屏（F11） |
| 偏好 | 启动方式、文件树范围、自动保存、默认编辑模式、2/4 空格缩进、自动配对、拼写检查、正文/等宽代码字体字号、明暗外观和图片目录；更改后即时同步各窗口 |
| 图片与链接 | 菜单插入、粘贴和拖入位图，复制到相对素材目录；支持本地图片及可选 HTTPS 图片预览，限制 20 MB/4000 万像素；网页、邮件、Markdown/文本链接及文内锚点导航 |
| 表格与公式 | 格式 → 表格提供插入、增删行列与对齐，表格右键提供当前可用操作；格式 → 插入公式块；共享 KaTeX、Mermaid 与代码高亮资源 |
| 剪贴板 | 普通粘贴支持 HTML 转 Markdown，源码/代码区域保持纯文本；编辑菜单提供复制 Markdown、粘贴为纯文本（Ctrl+Shift+V） |
| 导出打印 | 文件菜单导出独立 HTML、分页/连续 PDF，图片内嵌；页面设置（Ctrl+Shift+P）选择尺寸、方向与页边距；打印（Ctrl+P）打开系统打印对话框 |
| 状态与恢复 | 状态栏显示模式、保存状态与字/字符/行数；停止输入约 2 秒保存恢复草稿，可选自动保存已有文件；正常关闭恢复文件、标签顺序、选中标签、窗口位置与侧栏 |
| 更新与帮助 | 帮助菜单提供官网、反馈、检查更新；关于页可开启每日自动检查和下载，下载经 SHA-256 校验后缓存，退出应用后手动解压覆盖安装 |

连续 PDF 受引擎 200 英寸页高上限约束，超限会提示改为分页，不截断内容。系统打印的最终打印机选项由 Windows 对话框提供。

## 构建与运行

使用 Windows 11 x64、Visual Studio 的 .NET 桌面工具和 Windows SDK、.NET 10 LTS。依赖固定在项目文件中：Windows App SDK 2.5.1、WebView2 1.0.4314.35。先在仓库根目录构建编辑器：

```powershell
cd CoreEditor
node .yarn/releases/yarn-4.18.0.cjs install --immutable
node .yarn/releases/yarn-4.18.0.cjs build
cd ../Windows
dotnet build Inkpot.Windows.sln -c Release -p:Platform=x64
dotnet test Inkpot.Tests/Inkpot.Tests.csproj -c Release
dotnet publish Inkpot/Inkpot.csproj -c Release -p:Platform=x64 -o ../build/Windows
```

发布目录含 .NET 运行时，仍需安装共享的 [Windows App Runtime 2.5.1](https://learn.microsoft.com/windows/apps/windows-app-sdk/downloads) 与 [WebView2 Evergreen Runtime](https://developer.microsoft.com/microsoft-edge/webview2/)。不安装独立 WebView2 固定版本，不生成 MSIX 或安装器。启动 `build/Windows/Inkpot.exe`，也可用命令行传入一个或多个 `.md`、`.markdown`、`.txt` 文件路径。

`.github/workflows/release-windows.yml` 在正式 GitHub Release 发布后构建与测试 Windows，并附加 `Inkpot-windows-x64.zip` 和 `.sha256`；更新器只接受这组 Windows 资产。已有 Release 若没有 Windows 资产，会引导前往下载页，不下载 Mac 安装包。

## 文件安全与桥接

- 严格 UTF-8 解码，保留原 BOM 与混合行尾；无效编码直接拒绝打开。
- 保存先写同目录临时文件并写穿落盘，校验文件大小、修改时间及 SHA-256，再使用 `MoveFileEx(REPLACE_EXISTING | WRITE_THROUGH)` 原子替换。失败保留目标文件，外部修改或删除须确认后才能覆盖。
- 保存与关闭前取得最新编辑器快照；输入法候选尚未确认、快照失败或编辑器停止时阻止保存和关闭。
- 标签初次激活时才创建 WebView2，全部共享同一个环境。编辑器资源通过 HTTPS 虚拟域名映射，禁止跳转到其他页面，正文通过结构化消息传递。
- `CoreEditor/editor/bridge.ts` 是协议入口；Windows 对消息解析、文档 generation 和 revision 做校验，不接收旧文档状态。
- WebView2 浏览数据保存在 `%LOCALAPPDATA%\Inkpot\WebView2`，不在程序目录写入用户文档或恢复草稿。
- 偏好、会话和草稿分别在 `%LOCALAPPDATA%\Inkpot\settings.json`、`session.json`、`drafts/`；元数据原子替换，损坏的 JSON 会保留副本。草稿保留原始文本、BOM 与文件基线，恢复后仍须通过外部修改检查才能覆盖原文件。
- 自动保存遇到外部修改会暂停，不自动覆盖；通过手动保存处理冲突。恢复草稿会创建独立的脏标签，不替换正在编辑的标签。
- 文件树不跟随重解析点；删除先确认并移入系统回收站。导出先生成完整临时产物，图片或渲染失败不覆盖目标。
- 自动化验收可设置 `INKPOT_DATA_DIRECTORY` 使用独立数据目录；`--smoke-report` 默认自动使用临时目录，不读取用户设置或草稿。
- 未处理异常会在数据目录的 `Logs/crash.log` 记录时间、消息和异常堆栈，便于与 Windows 崩溃转储对照定位；日志记录不拦截或忽略原异常。

文件在基线检查与最终原子替换之间仍有很短的竞争窗口；未提供跨进程锁协议。外部编辑器在这段时间写入时，不能保证检测每一次并发写入。

## CI 与测量

`.github/workflows/build-and-test.yml` 的 Windows 任务先构建与测试 CoreEditor，再编译应用、运行文件安全／桥接／设置／文件树测试、裁剪发布，并启动**发布产物**执行真实 WebView2 冒烟检查。冒烟覆盖文件树按需展开、设置对话框显示与取消、偏好持久化与同步、大纲跳转、标签切换及侧栏／状态栏。测试使用独立临时目录，不读取用户文档与设置。手动触发时可选择 `windows_only` 仅运行 Windows 任务。下载产物位于该次 Actions 运行的 `inkpot-windows-x64`，原始测试和测量结果位于 `inkpot-windows-validation`；保留 7 天。

也可在 Windows 上运行：

```powershell
./Windows/scripts/measure.ps1 -AppDirectory build/Windows -ResultsDirectory build/WindowsResults
```

检查实际编辑、撤销、混合行尾、偏好、大纲/状态栏、文件树、图片/公式/Mermaid 的 HTML 内嵌、真实 PDF、设置/关于、移窗撤销历史及 1 MiB 文本传输；验证 10 标签按需创建与激活，并记录逐进程工作集和私有内存、发布目录大小。原始机器信息、测量方法和数据保存在 `measurements.json`，不把 GitHub Windows Server runner 的数据当作 Windows 11 桌面性能验收。启动时间从启动进程前取样到网页发出 ready；未清理系统缓存，不等于重启机器后的冷启动。1 MiB 文档指标包括完整快照往返，比单纯收到 open 确认更严格。

## Windows 11 人工验收

1. 打开带 BOM 与混合行尾的 Markdown，修改、撤销/重做、保存、关闭重开，确认文字与行尾保留。
2. 打开多个文件并切换标签；分别关闭标签、关闭窗口和通过菜单退出，逐一验证保存、不保存、取消。另存为取消或保存失败时保留文档。
3. 使用其他编辑器修改同一文件，再在 Inkpot 保存，验证覆盖/取消；独占锁定目标文件时保存失败，原文件保持完好。
4. 验证 Ctrl+N/O/S/Shift+S/W、Ctrl+Z/Y、格式快捷键与菜单，系统明暗切换和中文/英文系统语言。
5. 用微软拼音和搜狗分别输入连续中文、中文标点、拼音候选、选区替换；候选未确认时尝试保存和关闭，不应保存未确认文本或丢失候选。
6. 打开包含子目录与中文文件名的文件夹，展开目录、打开文件、重复打开同一文件；确认原标签的未保存内容保留。切换文件／大纲、点击不同级别标题，滚动正文核对高亮，拖动或用键盘调整侧栏宽度并重启验证。
7. 设置中修改字体、字号、外观、缩进与配对，保存并切换已有标签核对同步；取消设置应保留旧值。默认源码模式只影响新文档，重启后设置保留。验证 F8／F9、状态栏与快捷键在正文聚焦时仍可使用。
8. 在明确配置的 Windows 11 机器记录冷启动到 ready（目标 <1 秒）、1 MiB 文档可输入延时（对照 macOS 基线）、10 标签应用及 WebView2 内存总和（目标 <400 MB）、裁剪发布体积（目标 <50 MB）。保留原始数据，不以 CI 成功代替这些门槛。
