using Inkpot.Bridge;
using Inkpot.Storage;
using Microsoft.UI.Xaml.Controls;

namespace Inkpot;

internal sealed class DocumentTab(string? path, string text, bool hasBom, FileBaseline? baseline)
{
    internal string? Path { get; set; } = path;
    internal string InitialText { get; set; } = text;
    internal bool HasBom { get; set; } = hasBom;
    internal FileBaseline? Baseline { get; set; } = baseline;
    internal int SavedRevision { get; set; }
    internal string RecoveryId { get; set; } = Guid.NewGuid().ToString("N");
    internal bool Recovered { get; set; }
    internal string? Folder { get; set; }
    internal bool Sidebar { get; set; }
    internal string SidebarPage { get; set; } = "files";
    internal double SidebarWidth { get; set; } = 260;
    internal DateTime LastEdit { get; set; }
    internal int DraftRevision { get; set; } = -1;
    internal bool AutosaveBlocked { get; set; }
    internal EditorSession? Editor { get; set; }
    internal TabViewItem Item { get; set; } = new() { IsClosable = true };
    internal bool Dirty => Recovered || (Editor?.State?.Revision ?? 0) != SavedRevision;
    internal string Name => Path is null ? L10n.Text("Untitled") : System.IO.Path.GetFileName(Path);
    internal void RefreshHeader() => Item.Header = Name + (Dirty ? " •" : "");
}
