# Inkpot Windows MVP

C# / WinUI 3 原生窗口以 WebView2 承载仓库共用的 `CoreEditor/`，不复制编辑器源码。当前为非打包应用，提供新建、打开、编辑、保存/另存为、撤销重做、多标签、关闭保护及中英文界面。暂不提供文件树、大纲、设置、导出、图片插入、会话恢复或自动更新。

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

`.github/workflows/build-and-test.yml` 的 Windows 任务先构建与测试 CoreEditor，再编译应用、运行文件安全测试、裁剪发布，并启动**发布产物**执行真实 WebView2 冒烟检查。下载产物位于该次 Actions 运行的 `inkpot-windows-x64`，原始测试和测量结果位于 `inkpot-windows-validation`；保留 7 天。

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
6. 在明确配置的 Windows 11 机器记录冷启动到 ready（目标 <1 秒）、1 MiB 文档可输入延时（对照 macOS 基线）、10 标签应用及 WebView2 内存总和（目标 <400 MB）、裁剪发布体积（目标 <50 MB）。保留原始数据，不以 CI 成功代替这些门槛。
