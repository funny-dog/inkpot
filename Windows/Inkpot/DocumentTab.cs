using Inkpot.Bridge;
using Inkpot.Storage;
using Microsoft.UI.Xaml.Controls;

namespace Inkpot;

internal sealed class DocumentTab(string? path, string text, bool hasBom, FileBaseline? baseline)
{
    internal string? Path { get; set; } = path;
    internal string InitialText { get; set; } = text;
    internal bool HasBom { get; } = hasBom;
    internal FileBaseline? Baseline { get; set; } = baseline;
    internal int SavedRevision { get; set; }
    internal EditorSession? Editor { get; set; }
    internal TabViewItem Item { get; } = new() { IsClosable = true };
    internal bool Dirty => (Editor?.State?.Revision ?? 0) != SavedRevision;
    internal string Name => Path is null ? L10n.Text("Untitled") : System.IO.Path.GetFileName(Path);
    internal void RefreshHeader() => Item.Header = Name + (Dirty ? " •" : "");
}
