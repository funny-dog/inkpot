using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;
using Inkpot.Bridge;
using Inkpot.Storage;

namespace Inkpot;

public sealed partial class MainWindow
{
    // 仅由 CI 显式参数触发；使用临时文档，不读取或覆盖用户文件。
    private async Task RunSmokeAsync(string reportPath)
    {
        var report = new JsonObject { ["success"] = false, ["os"] = Environment.OSVersion.ToString(),
            ["cpuCount"] = Environment.ProcessorCount, ["runtime"] = Environment.Version.ToString() };
        try
        {
            var initial = CreateDocument();
            await ActivateCurrentAsync();
            await AssertEditorVisibleAsync(initial, "首个文档");
            report["readyMilliseconds"] = initial.Editor!.ReadyMilliseconds;
            report["readyUnixMilliseconds"] = initial.Editor.ReadyUnixMilliseconds;
            report["editorVisualSize"] = $"{initial.Editor.Control.ActualWidth:0}x{initial.Editor.Control.ActualHeight:0}";
            const string original = "# 标题\r\n中文\n尾";
            await initial.Editor.OpenAsync(original, Dark, L10n.Language);
            await initial.Editor.CommandAsync("heading2");
            var changed = await initial.Editor.SnapshotAsync();
            if (changed.Text != "## 标题\r\n中文\n尾" || initial.Editor.State?.CanUndo != true)
                throw new IOException("编辑命令或撤销状态不正确。");
            await initial.Editor.CommandAsync("undo");
            if ((await initial.Editor.SnapshotAsync()).Text != original) throw new IOException("撤销未恢复原文。");
            report["editUndoAndLineEndings"] = true;
            var text = new StringBuilder();
            const string paragraph = "Markdown paragraph 中文测试 with **bold** and a link.\n\n";
            int paragraphBytes = Encoding.UTF8.GetByteCount(paragraph);
            int totalBytes = 0;
            while (totalBytes + paragraphBytes <= 1024 * 1024) { text.Append(paragraph); totalBytes += paragraphBytes; }
            text.Append('x', 1024 * 1024 - totalBytes);
            string large = text.ToString();
            var timer = Stopwatch.StartNew();
            await initial.Editor.OpenAsync(large, Dark, L10n.Language);
            await initial.Editor.CommandAsync("focus");
            if ((await initial.Editor.SnapshotAsync()).Text != large) throw new IOException("大文档内容不一致。");
            report["open1MiBMilliseconds"] = timer.Elapsed.TotalMilliseconds;
            report["documentCharacters"] = large.Length;
            report["documentUtf8Bytes"] = Encoding.UTF8.GetByteCount(large);
            for (int index = 1; index < 10; index++) CreateDocument();
            report["webViewsBeforeActivation"] = documents.Count(document => document.Editor is not null);
            if (documents.Count(document => document.Editor is not null) != 1) throw new IOException("后台标签提前创建了 WebView2。");
            foreach (var document in documents)
            {
                Tabs.SelectedItem = document.Item;
                await ActivateCurrentAsync();
                await document.Editor!.CommandAsync("focus");
                await AssertEditorVisibleAsync(document, $"标签{documents.IndexOf(document) + 1}");
            }
            report["activatedTabs"] = documents.Count(document => document.Editor is not null);
            report["appWorkingSetBytes"] = Process.GetCurrentProcess().WorkingSet64;
            report["webView2ProcessIds"] = new JsonArray((await environment).GetProcessInfos()
                .Select(info => JsonValue.Create(info.ProcessId)).Cast<JsonNode?>().ToArray());
            report["success"] = true;
            foreach (var document in documents) document.SavedRevision = document.Editor?.State?.Revision ?? 0;
        }
        catch (Exception error)
        {
            report["error"] = error.ToString();
            Environment.ExitCode = 1;
        }
        finally
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(reportPath))!);
            await File.WriteAllTextAsync(reportPath, report.ToJsonString(new() { WriteIndented = true }));
            // 失败时保留窗口数秒：measure.ps1 读到报告会先截图留现场再关闭应用。
            if (report["success"]?.GetValue<bool>() != true)
            {
                allowClose = true;
                await Task.Delay(TimeSpan.FromSeconds(8));
                Close();
            }
        }
    }

    // 冒烟必须确认编辑器真的显示出来：逻辑通过但组合层不可见时，用户看到的就是空白窗口。
    // 布局可能在 ready 之后才完成，先短等；仍不可视时输出布局链关键尺寸供定位。
    private async Task AssertEditorVisibleAsync(DocumentTab document, string label)
    {
        var control = document.Editor?.Control ?? throw new IOException($"{label}没有编辑器。");
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(5);
        while (control.ActualHeight < 100 || control.ActualWidth < 100)
        {
            if (DateTime.UtcNow > deadline)
                throw new IOException(
                    $"{label}的编辑器未进入可视区域：尺寸={control.ActualWidth:0}x{control.ActualHeight:0} " +
                    $"XamlRoot={control.XamlRoot is not null} IsLoaded={control.IsLoaded} " +
                    $"TabView={Tabs.ActualWidth:0}x{Tabs.ActualHeight:0} Root={Root.ActualHeight:0} " +
                    $"父级={control.Parent?.GetType().Name ?? "null"} 选中={ReferenceEquals(Tabs.SelectedItem, document.Item)}");
            await Task.Delay(100);
        }
        if (control.XamlRoot is null || !control.IsLoaded)
            throw new IOException($"{label}的编辑器有可视尺寸但未完成挂载。");
    }
}
