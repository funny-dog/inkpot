using Inkpot.Storage;

namespace Inkpot.Tests;

public sealed class ParityStorageTests : IDisposable
{
    private readonly string folder = Path.Combine(Path.GetTempPath(), "InkpotTests", Guid.NewGuid().ToString("N"));
    private readonly AppState store;
    public ParityStorageTests() { Directory.CreateDirectory(folder); store = new(Path.Combine(folder, "state")); }
    public void Dispose() { Directory.Delete(folder, true); }

    [Fact]
    public void PreferencesAndSessionsRoundTripWithoutChangingDocumentFiles()
    {
        string path = Path.Combine(folder, "中文.md"); File.WriteAllText(path, "# 原文\r\n");
        var preferences = new Preferences { BodyFont = "等线", CodeFont = "Consolas", Zoom = 1.2, Indent = 4, Focus = true, RemoteImages = true };
        Preferences.Remember(preferences.RecentFiles, path); Preferences.Remember(preferences.RecentFiles, path.ToUpperInvariant());
        store.SavePreferences(preferences);
        var restored = store.LoadPreferences();
        Assert.Equal("等线", restored.BodyFont); Assert.True(restored.Focus); Assert.Equal(1.2, restored.Zoom); Assert.Single(restored.RecentFiles);
        var session = new SavedWindow([new(path, folder, true, "outline", 280)], 0, 50, 60, 1100, 780);
        store.SaveSession([session]);
        Assert.Equal(path, Assert.Single(Assert.Single(store.LoadSession()).Tabs).Path);
        Assert.Equal("# 原文\r\n", File.ReadAllText(path));
    }
    [Fact]
    public void RecoveryKeepsOriginalBaselineAndLineEndingsAndDeletesOnlySelectedDraft()
    {
        store.RemoveDraft(Guid.NewGuid().ToString("N")); // Closing a clean tab before any draft exists is valid.
        var baseline = new FileBaseline(12, DateTime.UtcNow, "original-hash");
        var first = new RecoveryDraft(Guid.NewGuid().ToString("N"), Path.Combine(folder, "doc.md"), "新文\r\n次行\n尾", true, baseline, DateTime.UtcNow);
        var second = first with { Id = Guid.NewGuid().ToString("N"), Text = "other" };
        store.SaveDraft(first); store.SaveDraft(second);
        Assert.Equal(first, store.LoadDrafts().Single(draft => draft.Id == first.Id));
        store.RemoveDraft(second.Id); Assert.Equal(first, Assert.Single(store.LoadDrafts()));
        Assert.Throws<FormatException>(() => store.RemoveDraft("../../settings"));
        Assert.Empty(Directory.EnumerateFiles(Path.Combine(store.DirectoryPath, "drafts"), "*.tmp"));
    }
    [Fact]
    public void InvalidPreferencesAreRetainedAndUnsafeNumericSettingsAreNormalized()
    {
        Directory.CreateDirectory(store.DirectoryPath);
        File.WriteAllText(Path.Combine(store.DirectoryPath, "settings.json"), "{broken");
        Assert.True(store.LoadPreferences().RestoreSession);
        Assert.Single(Directory.EnumerateFiles(store.DirectoryPath, "settings.json.invalid-*"));
        var preferences = new Preferences { Indent = 200, Zoom = double.NaN, BodySize = -99, PageMargin = 100 };
        store.SavePreferences(preferences);
        var restored = store.LoadPreferences(); Assert.Equal(2, restored.Indent); Assert.Equal(1, restored.Zoom); Assert.Equal(8, restored.BodySize);
        Assert.True(restored.PageMargin < restored.PageWidth / 2);
    }
    [Fact]
    public async Task FolderSearchUsesUtf16ColumnsAndNeverReturnsBinaryOrHiddenFilesByDefault()
    {
        File.WriteAllText(Path.Combine(folder, "10.md"), "line\r\n😀中文 target TARGET\n");
        File.WriteAllText(Path.Combine(folder, "2.md"), "other");
        File.WriteAllText(Path.Combine(folder, ".hidden.md"), "target");
        File.WriteAllText(Path.Combine(folder, "binary.dat"), "target");
        Directory.CreateDirectory(Path.Combine(folder, "sub")); File.WriteAllText(Path.Combine(folder, "sub", "child.txt"), "target");
        Assert.Equal(new[] { "sub", "2.md", "10.md" }, FolderIndex.Children(folder, false, false).Select(entry => entry.Name));
        var found = new List<FolderMatch>(); await FolderIndex.SearchAsync(folder, "target", false, found.Add, CancellationToken.None);
        Assert.Equal(3, found.Count);
        var first = found.First(match => match.Path.EndsWith("10.md")); Assert.Equal(2, first.Line); Assert.Equal(5, first.Column); Assert.Equal(6, first.Length);
    }
    [Theory]
    [InlineData("../escape.md")]
    [InlineData("NUL.txt")]
    [InlineData("CON")]
    [InlineData("trailing.")]
    [InlineData("bad:name")]
    public void FileActionsRejectNamesThatEscapeOrAliasTheSelectedFolder(string name) => Assert.Throws<IOException>(() => FolderIndex.ChildPath(folder, name));
    [Fact]
    public async Task ImportedImagesUseRelativeEscapedPathsWithoutOverwritingExistingAssets()
    {
        byte[] png = Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=");
        string document = Path.Combine(folder, "中文 空格.md");
        var preferences = new Preferences { DocumentImageFolder = true };
        string first = await ImageStorage.ImportAsync(png, document, preferences), second = await ImageStorage.ImportAsync(png, document, preferences);
        Assert.NotEqual(first, second); Assert.Contains("中文%20空格.assets/", first);
        string path = ImageStorage.ResolveLocal(first, document);
        Assert.Equal(png, (await ImageStorage.ReadAsync(path, document, false)).Bytes);
        Assert.Throws<IOException>(() => ImageStorage.Mime("<svg onload='alert(1)'/>"u8));
        Assert.Throws<IOException>(() => ImageStorage.ResolveLocal("https://example.com/img.png", document));
        await Assert.ThrowsAsync<IOException>(() => ImageStorage.ReadAsync("https://example.com/img.png", document, false));
    }
    [Theory]
    [InlineData("v0.2.0", "0.1.9", true)]
    [InlineData("1.0.0", "1.0.0", false)]
    [InlineData("0.9.0", "1.0.0", false)]
    public void UpdatesCompareStableNumericVersions(string tag, string current, bool newer) => Assert.Equal(newer, UpdateService.IsNewer(tag, current));
    [Theory]
    [InlineData("v1.0.0-beta")]
    [InlineData("01.2.3")]
    [InlineData("1.0")]
    public void UpdatesRejectMalformedOrPrereleaseVersions(string tag) => Assert.Throws<IOException>(() => UpdateService.IsNewer(tag, "0.1.0"));
}
