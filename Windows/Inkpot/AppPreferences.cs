using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Inkpot;

[JsonSourceGenerationOptions(
    WriteIndented = true,
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    PropertyNameCaseInsensitive = true)]
[JsonSerializable(typeof(AppPreferences))]
internal sealed partial class AppPreferencesJsonContext : JsonSerializerContext
{
}

internal sealed record AppPreferences
{
    public string Appearance { get; init; } = "system";
    public string BodyFamily { get; init; } = "";
    public string CodeFamily { get; init; } = "Consolas";
    public double BodySize { get; init; } = 15;
    public double CodeSize { get; init; } = 14;
    public bool DefaultSourceMode { get; init; } = false;
    public bool PairBrackets { get; init; } = true;
    public bool PairMarkdown { get; init; } = true;
    public bool FocusMode { get; init; } = false;
    public bool TypewriterMode { get; init; } = false;
    public int IndentWidth { get; init; } = 2;
    public bool SidebarVisible { get; init; } = true;
    public double SidebarWidth { get; init; } = 260;

    internal AppPreferences Normalize()
    {
        string normalizedAppearance = Appearance?.Trim().ToLowerInvariant() switch
        {
            "light" => "light",
            "dark" => "dark",
            "system" => "system",
            _ => "system",
        };

        string normalizedBodyFamily = string.IsNullOrWhiteSpace(BodyFamily) ? "" : BodyFamily.Trim();
        string normalizedCodeFamily = string.IsNullOrWhiteSpace(CodeFamily) ? "Consolas" : CodeFamily.Trim();

        double normalizedBodySize = double.IsFinite(BodySize) && BodySize >= 8 && BodySize <= 72 ? BodySize : 15;
        double normalizedCodeSize = double.IsFinite(CodeSize) && CodeSize >= 8 && CodeSize <= 72 ? CodeSize : 14;

        int normalizedIndentWidth = IndentWidth == 4 ? 4 : 2;

        double normalizedSidebarWidth = double.IsFinite(SidebarWidth) && SidebarWidth >= 180 && SidebarWidth <= 480 ? SidebarWidth : 260;

        return this with
        {
            Appearance = normalizedAppearance,
            BodyFamily = normalizedBodyFamily,
            CodeFamily = normalizedCodeFamily,
            BodySize = normalizedBodySize,
            CodeSize = normalizedCodeSize,
            IndentWidth = normalizedIndentWidth,
            SidebarWidth = normalizedSidebarWidth,
        };
    }

    internal static AppPreferences Load(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        string fullPath = Path.GetFullPath(path);
        try
        {
            using var stream = new FileStream(fullPath, FileMode.Open, FileAccess.Read, FileShare.Read);
            var preferences = JsonSerializer.Deserialize(stream, AppPreferencesJsonContext.Default.AppPreferences);
            if (preferences is null)
            {
                throw new IOException($"首选项文件“{fullPath}”内容为空。");
            }

            return preferences.Normalize();
        }
        catch (FileNotFoundException) { return new AppPreferences(); }
        catch (DirectoryNotFoundException) { return new AppPreferences(); }
        catch (JsonException ex)
        {
            throw new IOException($"首选项文件“{fullPath}”损坏，无法解析为有效 JSON。", ex);
        }
        catch (Exception ex) when (ex is not IOException)
        {
            throw new IOException($"读取首选项文件“{fullPath}”失败：{ex.Message}", ex);
        }
    }

    internal void Save(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        string fullPath = Path.GetFullPath(path);
        string directory = Path.GetDirectoryName(fullPath)
            ?? throw new DirectoryNotFoundException($"无法获取路径“{fullPath}”的所在目录。");

        string tempPath = Path.Combine(directory, $".{Path.GetFileName(fullPath)}.{Guid.NewGuid():N}.tmp");
        var normalized = Normalize();

        try
        {
            Directory.CreateDirectory(directory);
            using (var stream = new FileStream(tempPath, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            {
                JsonSerializer.Serialize(stream, normalized, AppPreferencesJsonContext.Default.AppPreferences);
                stream.Flush(flushToDisk: true);
            }

            File.Move(tempPath, fullPath, overwrite: true);
        }
        catch (Exception ex) when (ex is not IOException)
        {
            throw new IOException($"保存首选项到“{fullPath}”失败：{ex.Message}", ex);
        }
        finally
        {
            try
            {
                if (File.Exists(tempPath))
                {
                    File.Delete(tempPath);
                }
            }
            catch
            {
                // 清理临时文件失败不掩盖保存错误
            }
        }
    }
}
