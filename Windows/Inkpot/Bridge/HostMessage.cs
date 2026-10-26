using System.Text.Json;

namespace Inkpot.Bridge;

// 字段与 CoreEditor/editor/bridge.ts 对齐，解析失败时不更新文档状态。
internal abstract record HostMessage
{
    internal static HostMessage? Parse(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.TryGetProperty("ready", out var ready) && ready.GetBoolean()) return new ReadyMessage();
            if (root.TryGetProperty("response", out var response) && response.GetBoolean())
            {
                var snapshot = root.TryGetProperty("snapshot", out var value)
                    ? new EditorSnapshot(value.GetProperty("text").GetString()!, value.GetProperty("revision").GetInt32()) : null;
                return new ResponseMessage(root.GetProperty("requestId").GetInt32(), snapshot,
                    root.TryGetProperty("error", out var error) ? error.GetString() : null,
                    root.TryGetProperty("value", out var result) ? result.GetString() : null);
            }
            int generation = root.GetProperty("generation").GetInt32();
            if (generation < 0) return null;
            if (root.TryGetProperty("shortcut", out var shortcut)) return new ShortcutMessage(generation, shortcut.GetString()!);
            if (root.TryGetProperty("pasteImage", out var paste) && paste.GetBoolean()) return new PasteImageMessage(generation);
            if (root.TryGetProperty("openLink", out var link)) return new LinkMessage(generation, link.GetString()!);
            int revision = root.GetProperty("revision").GetInt32();
            if (revision < 0) return null;
            if (root.TryGetProperty("outline", out var outline) && outline.GetBoolean())
            {
                Heading[]? headingsList = null;
                if (root.TryGetProperty("headings", out var headings) && headings.ValueKind == JsonValueKind.Array)
                {
                    var items = new List<Heading>();
                    foreach (var heading in headings.EnumerateArray())
                    {
                        if (!heading.TryGetProperty("id", out var idProp) || idProp.ValueKind != JsonValueKind.Number || idProp.GetInt32() < 0) return null;
                        if (!heading.TryGetProperty("level", out var levelProp) || levelProp.ValueKind != JsonValueKind.Number || levelProp.GetInt32() is < 1 or > 6) return null;
                        if (!heading.TryGetProperty("title", out var titleProp) || titleProp.ValueKind != JsonValueKind.String || titleProp.GetString() is not { } title) return null;
                        if (heading.TryGetProperty("from", out var fromProp) && heading.TryGetProperty("to", out var toProp))
                        {
                            if (fromProp.ValueKind != JsonValueKind.Number || toProp.ValueKind != JsonValueKind.Number) return null;
                            int from = fromProp.GetInt32();
                            int to = toProp.GetInt32();
                            if (from < 0 || to < from) return null;
                        }
                        else if (heading.TryGetProperty("from", out _) || heading.TryGetProperty("to", out _))
                        {
                            return null;
                        }
                        items.Add(new Heading(idProp.GetInt32(), levelProp.GetInt32(), title));
                    }
                    if (items.Select(item => item.Id).Distinct().Count() != items.Count) return null;
                    headingsList = items.ToArray();
                }
                int? activeId = null;
                if (root.TryGetProperty("active", out var active))
                {
                    if (active.ValueKind == JsonValueKind.Number)
                    {
                        int val = active.GetInt32();
                        if (val < 0) return null;
                        activeId = val;
                    }
                    else if (active.ValueKind != JsonValueKind.Null)
                    {
                        return null;
                    }
                }
                return new OutlineMessage(generation, revision, headingsList, activeId);
            }
            var stats = root.GetProperty("stats");
            return new PublishMessage(generation, revision, root.GetProperty("changed").GetBoolean(),
                root.GetProperty("canUndo").GetBoolean(), root.GetProperty("canRedo").GetBoolean(),
                root.GetProperty("searchInputFocused").GetBoolean(), root.GetProperty("tableCellFocused").GetBoolean(),
                root.GetProperty("editorFocused").GetBoolean(), root.GetProperty("sourceMode").GetBoolean(),
                root.GetProperty("composing").GetBoolean(),
                root.GetProperty("tableActions").EnumerateArray().Select(action => action.GetString()!).ToArray(),
                new DocumentStats(stats.GetProperty("words").GetInt32(), stats.GetProperty("characters").GetInt32(), stats.GetProperty("lines").GetInt32()));
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException or KeyNotFoundException or FormatException or OverflowException)
        {
            return null;
        }
    }
}

internal sealed record ReadyMessage : HostMessage;
internal sealed record PasteImageMessage(int Generation) : HostMessage;
internal sealed record ShortcutMessage(int Generation, string Shortcut) : HostMessage;
internal sealed record LinkMessage(int Generation, string OpenLink) : HostMessage;
internal sealed record Heading(int Id, int Level, string Title);
internal sealed record OutlineHeading(int Id, int From, int To, int Level, string Title);
internal sealed record OutlineMessage(int Generation, int Revision, Heading[]? Headings, int? Active) : HostMessage;
internal sealed record EditorSnapshot(string Text, int Revision);
internal sealed record DocumentStats(int Words, int Characters, int Lines);
internal sealed record ResponseMessage(int RequestId, EditorSnapshot? Snapshot, string? Error, string? Value = null) : HostMessage;
internal sealed record PublishMessage(int Generation, int Revision, bool Changed, bool CanUndo, bool CanRedo,
    bool SearchInputFocused, bool TableCellFocused, bool EditorFocused, bool SourceMode, bool Composing,
    string[] TableActions, DocumentStats Stats) : HostMessage;
