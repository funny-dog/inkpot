# Inkpot Windows

C# / WinUI 3 原生窗口以 WebView2 承载仓库共用的 `CoreEditor/`，不复制编辑器源码。当前为非打包应用，提供新建、打开、编辑、保存/另存为、撤销重做、多标签、关闭保护及中英文界面，并提供文件树、大纲、设置、显示菜单和字数状态栏。

## 界面布局

与 macOS 版保持同一套布局：菜单栏右侧放侧栏、专注模式和源码模式三个按钮，对应 macOS 工具栏；侧栏顶部用分段按钮切换文件和大纲，未打开文件夹或没有标题时显示带说明的空状态；底部状态栏左侧是编辑模式和保存状态，右侧是字数统计。侧栏选中行和按钮选中态使用与 macOS 一致的墨蓝强调色（深色模式下为浅蓝），其余控件沿用 Windows 原生 Fluent 样式。设置对话框按外观、字体、编辑、自动配对、显示模式分组。

## 侧栏与设置

- 文件 → 打开文件夹（Ctrl+Alt+O）：文件树按目录优先及名称自然排序，只显示 Markdown／文本文件；子目录展开时读取，不跟随符号链接或目录联接，也不显示隐藏／系统项。打开文件进入标签页，相同路径复用已有标签，不替换其他标签的未保存内容。
- 显示 → 侧栏（Ctrl+Shift+E）、标题大纲（Ctrl+Shift+O）：支持侧栏显隐、文件／大纲切换，拖动分隔条调整宽度；分隔条也可通过 Tab 聚焦后用左右键调整。大纲按标题层级缩进，点击跳转，随正文滚动高亮当前章节。
- 显示 → 设置（Ctrl+,）：正文与代码字体／字号、系统／浅色／深色外观、默认源码模式、2／4 空格缩进、自动配对、专注和打字机模式。保存后同步当前已打开的标签；默认模式只影响之后首次激活的文档。取消不修改偏好。
- 专注模式（F8）、打字机模式（F9）可在显示菜单切换。底部显示当前实时／源码模式、字数、字符数和行数。
- 偏好保存在 `%LOCALAPPDATA%\Inkpot\preferences.json`，重启后保留；侧栏显隐和宽度也会保存。设置读取／保存失败会提示，不改写 Markdown 内容或撤销历史。

Windows 版尚未与 macOS 全部功能对齐：暂不提供文件树右键管理、文件夹全文搜索、图片读取／插入、HTML／PDF 导出与打印、最近打开、会话／草稿恢复、自动保存或自动更新。

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

发布目录含 .NET 运行时，仍需安装共享的 [Windows App Runtime 2.5.1](https://learn.microsoft.com/windows/apps/windows-app-sdk/downloads) 与 [WebView2 Evergreen Runtime](https://developer.microsoft.com/microsoft-edge/webview2/)。不安装独立 WebView2 固定版本，不生成 MSIX 或安装器；分发方式留待后续决定。启动 `build/Windows/Inkpot.exe`，也可用命令行传入一个或多个 `.md`、`.markdown`、`.txt` 文件路径。

## 文件安全与桥接

- 严格 UTF-8 解码，保留原 BOM 与混合行尾；无效编码直接拒绝打开。
- 保存先写同目录临时文件并写穿落盘，校验文件大小、修改时间及 SHA-256，再使用 `MoveFileEx(REPLACE_EXISTING | WRITE_THROUGH)` 原子替换。失败保留目标文件，外部修改或删除须确认后才能覆盖。
- 保存与关闭前取得最新编辑器快照；输入法候选尚未确认、快照失败或编辑器停止时阻止保存和关闭。
- 标签初次激活时才创建 WebView2，全部共享同一个环境。编辑器资源通过 HTTPS 虚拟域名映射，禁止跳转到其他页面，正文通过结构化消息传递。
- `CoreEditor/editor/bridge.ts` 是协议入口；Windows 对消息解析、文档 generation 和 revision 做校验，不接收旧文档状态。
- WebView2 浏览数据保存在 `%LOCALAPPDATA%\Inkpot\WebView2`，不在程序目录写入用户文档或恢复草稿。

文件在基线检查与最终原子替换之间仍有很短的竞争窗口；未提供跨进程锁协议。外部编辑器在这段时间写入时，不能保证检测每一次并发写入。

## CI 与测量

`.github/workflows/build-and-test.yml` 的 Windows 任务先构建与测试 CoreEditor，再编译应用、运行文件安全／桥接／设置／文件树测试、裁剪发布，并启动**发布产物**执行真实 WebView2 冒烟检查。冒烟覆盖文件树按需展开、设置对话框显示与取消、偏好持久化与同步、大纲跳转、标签切换及侧栏／状态栏。测试使用独立临时目录，不读取用户文档与设置。手动触发时可选择 `windows_only` 仅运行 Windows 任务。下载产物位于该次 Actions 运行的 `inkpot-windows-x64`，原始测试和测量结果位于 `inkpot-windows-validation`；保留 7 天。

也可在 Windows 上运行：

```powershell
./Windows/scripts/measure.ps1 -AppDirectory build/Windows -ResultsDirectory build/WindowsResults
```

检查实际编辑、撤销、混合行尾及 1 MiB 文本传输；验证 10 标签按需创建与激活，并记录逐进程工作集和私有内存、发布目录大小。原始机器信息、测量方法和数据保存在 `measurements.json`，不把 GitHub Windows Server runner 的数据当作 Windows 11 桌面性能验收。启动时间从启动进程前取样到网页发出 ready；未清理系统缓存，不等于重启机器后的冷启动。1 MiB 文档指标包括完整快照往返，比单纯收到 open 确认更严格。

## Windows 11 人工验收

1. 打开带 BOM 与混合行尾的 Markdown，修改、撤销/重做、保存、关闭重开，确认文字与行尾保留。
2. 打开多个文件并切换标签；分别关闭标签、关闭窗口和通过菜单退出，逐一验证保存、不保存、取消。另存为取消或保存失败时保留文档。
3. 使用其他编辑器修改同一文件，再在 Inkpot 保存，验证覆盖/取消；独占锁定目标文件时保存失败，原文件保持完好。
4. 验证 Ctrl+N/O/S/Shift+S/W、Ctrl+Z/Y、格式快捷键与菜单，系统明暗切换和中文/英文系统语言。
5. 用微软拼音和搜狗分别输入连续中文、中文标点、拼音候选、选区替换；候选未确认时尝试保存和关闭，不应保存未确认文本或丢失候选。
6. 打开包含子目录与中文文件名的文件夹，展开目录、打开文件、重复打开同一文件；确认原标签的未保存内容保留。切换文件／大纲、点击不同级别标题，滚动正文核对高亮，拖动或用键盘调整侧栏宽度并重启验证。
7. 设置中修改字体、字号、外观、缩进与配对，保存并切换已有标签核对同步；取消设置应保留旧值。默认源码模式只影响新文档，重启后设置保留。验证 F8／F9、状态栏与快捷键在正文聚焦时仍可使用。
8. 在明确配置的 Windows 11 机器记录冷启动到 ready（目标 <1 秒）、1 MiB 文档可输入延时（对照 macOS 基线）、10 标签应用及 WebView2 内存总和（目标 <400 MB）、裁剪发布体积（目标 <50 MB）。保留原始数据，不以 CI 成功代替这些门槛。
