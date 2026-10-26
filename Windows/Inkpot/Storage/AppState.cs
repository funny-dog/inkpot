using System.Text.Json;
using System.Text.Json.Serialization;

namespace Inkpot.Storage;

public sealed class Preferences
{
    public bool RestoreSession { get; set; } = true;
    public bool AllFiles { get; set; }
    public bool HiddenFiles { get; set; }
    public bool Autosave { get; set; }
    public bool DefaultSource { get; set; }
    public bool PairBrackets { get; set; } = true;
    public bool PairMarkdown { get; set; } = true;
    public bool Spellcheck { get; set; } = true;
    public bool Focus { get; set; }
    public bool Typewriter { get; set; }
    public int Indent { get; set; } = 2;
    public string Appearance { get; set; } = "system";
    public string BodyFont { get; set; } = "";
    public string CodeFont { get; set; } = "";
    public double BodySize { get; set; } = 15;
    public double CodeSize { get; set; } = 15;
    public double Zoom { get; set; } = 1;
    public bool ZoomWithControlScroll { get; set; }
    public bool RemoteImages { get; set; }
    public bool DocumentImageFolder { get; set; }
    public string? ImageFolder { get; set; }
    public bool AutomaticUpdates { get; set; } = true;
    public bool PaginatedPdf { get; set; } = true;
    public bool Landscape { get; set; }
    public double PageWidth { get; set; } = 8.2677;
    public double PageHeight { get; set; } = 11.6929;
    public double PageMargin { get; set; } = .5;
    public DateTime LastUpdateCheck { get; set; }
    public List<string> RecentFiles { get; set; } = [];
    public List<string> RecentFolders { get; set; } = [];
    public Dictionary<string, string> DocumentFolders { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    public void Normalize()
    {
        Indent = Indent == 4 ? 4 : 2;
        Appearance = Appearance is "light" or "dark" ? Appearance : "system";
        BodySize = Clamp(BodySize, 8, 72, 15);
        CodeSize = Clamp(CodeSize, 8, 72, 15);
        Zoom = Clamp(Zoom, .5, 2, 1);
        PageWidth = Clamp(PageWidth, 1, 100, 8.2677);
        PageHeight = Clamp(PageHeight, 1, 100, 11.6929);
        PageMargin = Clamp(PageMargin, 0, Math.Min(PageWidth, PageHeight) / 3, .5);
        RecentFiles ??= []; RecentFolders ??= []; DocumentFolders ??= new(StringComparer.OrdinalIgnoreCase);
    }

    private static double Clamp(double value, double min, double max, double fallback) =>
        double.IsFinite(value) ? Math.Clamp(value, min, max) : fallback;

    public static void Remember(List<string> paths, string path)
    {
        path = Path.GetFullPath(path);
        paths.RemoveAll(item => string.Equals(item, path, StringComparison.OrdinalIgnoreCase));
        paths.Insert(0, path);
        if (paths.Count > 10) paths.RemoveRange(10, paths.Count - 10);
    }
}

public sealed record SavedTab(string? Path, string? Folder, bool Sidebar, string SidebarPage, double SidebarWidth);
public sealed record SavedWindow(List<SavedTab> Tabs, int Selected, int X, int Y, int Width, int Height);
public sealed record RecoveryDraft(string Id, string? Path, string Text, bool HasBom, FileBaseline? Baseline, DateTime Updated);

// Keep application metadata separate from user documents. Replace files atomically and preserve corrupt
// metadata for diagnosis instead of overwriting it during startup.
public sealed class AppState(string directory)
{
    public string DirectoryPath { get; } = Path.GetFullPath(directory);
    public Preferences LoadPreferences()
    {
        var preferences = Read("settings.json", StateJson.Default.Preferences) ?? new();
        preferences.Normalize();
        return preferences;
    }
    public void SavePreferences(Preferences preferences) { preferences.Normalize(); Write("settings.json", preferences, StateJson.Default.Preferences); }
    public List<SavedWindow> LoadSession() => Read("session.json", StateJson.Default.ListSavedWindow) ?? [];
    public void SaveSession(List<SavedWindow> windows) => Write("session.json", windows, StateJson.Default.ListSavedWindow);
    public void SaveDraft(RecoveryDraft draft) => Write($"drafts/{SafeId(draft.Id)}.json", draft, StateJson.Default.RecoveryDraft);
    public void RemoveDraft(string id)
    {
        string path = Path.Combine(DirectoryPath, "drafts", SafeId(id) + ".json");
        if (Directory.Exists(Path.GetDirectoryName(path))) File.Delete(path);
    }
    public List<RecoveryDraft> LoadDrafts()
    {
        string folder = Path.Combine(DirectoryPath, "drafts");
        if (!Directory.Exists(folder)) return [];
        return Directory.EnumerateFiles(folder, "*.json").Select(path => Read(Path.GetRelativePath(DirectoryPath, path), StateJson.Default.RecoveryDraft))
            .OfType<RecoveryDraft>().OrderByDescending(draft => draft.Updated).ToList();
    }
    private static string SafeId(string id) => Guid.ParseExact(id, "N").ToString("N");
    private T? Read<T>(string name, System.Text.Json.Serialization.Metadata.JsonTypeInfo<T> type)
    {
        string path = Path.Combine(DirectoryPath, name);
        if (!File.Exists(path)) return default;
        try { return JsonSerializer.Deserialize(File.ReadAllText(path), type); }
        catch (JsonException) { File.Copy(path, path + ".invalid-" + DateTime.UtcNow.Ticks, false); return default; }
    }
    private void Write<T>(string name, T value, System.Text.Json.Serialization.Metadata.JsonTypeInfo<T> type)
    {
        string path = Path.Combine(DirectoryPath, name);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            { JsonSerializer.Serialize(stream, value, type); stream.Flush(true); }
            File.Move(temporary, path, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}

[JsonSerializable(typeof(Preferences))]
[JsonSerializable(typeof(List<SavedWindow>))]
[JsonSerializable(typeof(RecoveryDraft))]
internal partial class StateJson : JsonSerializerContext;
