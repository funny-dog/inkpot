namespace Inkpot.Tests;

using System;
using System.IO;
using Inkpot;
using Xunit;

public class PreferencesTests : IDisposable
{
    private readonly string testDirectory;

    public PreferencesTests()
    {
        testDirectory = Path.Combine(Path.GetTempPath(), $"InkpotPreferencesTests_{Guid.NewGuid():N}");
        Directory.CreateDirectory(testDirectory);
    }

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(testDirectory))
            {
                Directory.Delete(testDirectory, recursive: true);
            }
        }
        catch
        {
            // 忽略临时测试目录的清理异常
        }
    }

    [Fact]
    public void Load_NonExistentFile_ReturnsDefaultPreferences()
    {
        string filePath = Path.Combine(testDirectory, "non_existent_preferences.json");

        var preferences = AppPreferences.Load(filePath);

        Assert.Equal(new AppPreferences(), preferences);
        Assert.Equal("system", preferences.Appearance);
        Assert.Equal("", preferences.BodyFamily);
        Assert.Equal("Consolas", preferences.CodeFamily);
        Assert.Equal(15, preferences.BodySize);
        Assert.Equal(14, preferences.CodeSize);
        Assert.False(preferences.DefaultSourceMode);
        Assert.True(preferences.PairBrackets);
        Assert.True(preferences.PairMarkdown);
        Assert.False(preferences.FocusMode);
        Assert.False(preferences.TypewriterMode);
        Assert.Equal(2, preferences.IndentWidth);
        Assert.True(preferences.SidebarVisible);
        Assert.Equal(260, preferences.SidebarWidth);
    }

    [Fact]
    public void SaveAndLoad_Roundtrip_PreservesAllProperties()
    {
        string filePath = Path.Combine(testDirectory, "roundtrip_preferences.json");
        var original = new AppPreferences
        {
            Appearance = "dark",
            BodyFamily = "Segoe UI",
            CodeFamily = "Cascadia Code",
            BodySize = 18.5,
            CodeSize = 16,
            DefaultSourceMode = true,
            PairBrackets = false,
            PairMarkdown = false,
            FocusMode = true,
            TypewriterMode = true,
            IndentWidth = 4,
            SidebarVisible = false,
            SidebarWidth = 320,
        };

        original.Save(filePath);
        var loaded = AppPreferences.Load(filePath);

        Assert.Equal(original, loaded);
    }

    [Fact]
    public void Load_CorruptJson_ThrowsIOException()
    {
        string filePath = Path.Combine(testDirectory, "corrupt.json");
        File.WriteAllText(filePath, "{ invalid json structure, not valid syntax");

        var exception = Assert.Throws<IOException>(() => AppPreferences.Load(filePath));
        Assert.Contains("损坏", exception.Message);
    }

    [Fact]
    public void Load_EmptyFile_ThrowsIOException()
    {
        string filePath = Path.Combine(testDirectory, "empty.json");
        File.WriteAllText(filePath, "   ");

        Assert.Throws<IOException>(() => AppPreferences.Load(filePath));
    }

    [Fact]
    public void Load_DirectoryPath_ReportsReadFailure() => Assert.Throws<IOException>(() => AppPreferences.Load(testDirectory));

    [Fact]
    public void Normalize_InvalidFields_FallsBackToDefaults()
    {
        var invalid = new AppPreferences
        {
            Appearance = "neon-glow",
            BodyFamily = "   ",
            CodeFamily = "   ",
            BodySize = 100,
            CodeSize = -5,
            IndentWidth = 8,
            SidebarWidth = 50,
        };

        var normalized = invalid.Normalize();

        Assert.Equal("system", normalized.Appearance);
        Assert.Equal("", normalized.BodyFamily);
        Assert.Equal("Consolas", normalized.CodeFamily);
        Assert.Equal(15, normalized.BodySize);
        Assert.Equal(14, normalized.CodeSize);
        Assert.Equal(2, normalized.IndentWidth);
        Assert.Equal(260, normalized.SidebarWidth);
    }

    [Fact]
    public void Normalize_NonFiniteNumbersAndRangeBoundaries_FallsBackToDefaults()
    {
        var nonFinite = new AppPreferences
        {
            BodySize = double.NaN,
            CodeSize = double.PositiveInfinity,
            SidebarWidth = double.NegativeInfinity,
            IndentWidth = 0,
        };

        var normalized = nonFinite.Normalize();

        Assert.Equal(15, normalized.BodySize);
        Assert.Equal(14, normalized.CodeSize);
        Assert.Equal(260, normalized.SidebarWidth);
        Assert.Equal(2, normalized.IndentWidth);

        var outOfRange = new AppPreferences
        {
            BodySize = 7.9,
            CodeSize = 72.1,
            SidebarWidth = 179.9,
        };

        var normalizedOutOfRange = outOfRange.Normalize();
        Assert.Equal(15, normalizedOutOfRange.BodySize);
        Assert.Equal(14, normalizedOutOfRange.CodeSize);
        Assert.Equal(260, normalizedOutOfRange.SidebarWidth);
    }

    [Fact]
    public void Normalize_ValidFields_Preserved()
    {
        var valid = new AppPreferences
        {
            Appearance = "light",
            BodyFamily = "Arial",
            CodeFamily = "Courier New",
            BodySize = 8,
            CodeSize = 72,
            IndentWidth = 4,
            SidebarWidth = 180,
        };

        var normalized = valid.Normalize();

        Assert.Equal("light", normalized.Appearance);
        Assert.Equal("Arial", normalized.BodyFamily);
        Assert.Equal("Courier New", normalized.CodeFamily);
        Assert.Equal(8, normalized.BodySize);
        Assert.Equal(72, normalized.CodeSize);
        Assert.Equal(4, normalized.IndentWidth);
        Assert.Equal(180, normalized.SidebarWidth);
    }

    [Fact]
    public void Save_WhenTargetFileLocked_KeepsOriginalFileAndCleansTemp()
    {
        string filePath = Path.Combine(testDirectory, "locked_preferences.json");
        var original = new AppPreferences
        {
            Appearance = "light",
            BodySize = 20,
        };
        original.Save(filePath);
        Assert.True(File.Exists(filePath));

        var modified = original with
        {
            Appearance = "dark",
            BodySize = 24,
        };

        // 独占锁定目标文件，使替换无法完成
        using (var lockStream = new FileStream(filePath, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            Assert.Throws<IOException>(() => modified.Save(filePath));
        }

        // 确认原有文件内容未被损坏
        var reloaded = AppPreferences.Load(filePath);
        Assert.Equal(original, reloaded);

        // 确认没有残留临时文件
        var tempFiles = Directory.GetFiles(testDirectory, "*.tmp");
        Assert.Empty(tempFiles);
    }
}
