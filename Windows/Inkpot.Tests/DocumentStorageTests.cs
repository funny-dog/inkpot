namespace Inkpot.Tests;

using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using Inkpot.Storage;
using Xunit;

/// <summary>
/// 验证 DocumentStorage 的 UTF-8 编码、BOM 往返、混合行尾保真、原子保存及外部修改保护等纯逻辑。
/// </summary>
public class DocumentStorageTests : IDisposable
{
    private readonly string _testDirectory;

    public DocumentStorageTests()
    {
        _testDirectory = Path.Combine(Path.GetTempPath(), $"InkpotStorageTests_{Guid.NewGuid():N}");
        Directory.CreateDirectory(_testDirectory);
    }

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(_testDirectory))
            {
                Directory.Delete(_testDirectory, recursive: true);
            }
        }
        catch
        {
            // 忽略临时测试目录的清理异常
        }
    }

    [Fact]
    public async Task ReadAsync_WithBom_ReturnsHasBomTrueAndStripsBom()
    {
        string filePath = Path.Combine(_testDirectory, "bom_document.md");
        byte[] bom = [0xEF, 0xBB, 0xBF];
        byte[] contentBytes = Encoding.UTF8.GetBytes("# 标题\r\n正文内容");
        await File.WriteAllBytesAsync(filePath, [.. bom, .. contentBytes]);

        var loaded = await DocumentStorage.ReadAsync(filePath);

        Assert.True(loaded.HasBom);
        Assert.Equal("# 标题\r\n正文内容", loaded.Text);
        Assert.False(loaded.Text.StartsWith('\uFEFF'));
        Assert.Equal(bom.Length + contentBytes.Length, loaded.Baseline.Length);
        Assert.False(string.IsNullOrWhiteSpace(loaded.Baseline.Sha256));
    }

    [Fact]
    public async Task ReadAsync_WithoutBom_ReturnsHasBomFalse()
    {
        string filePath = Path.Combine(_testDirectory, "no_bom_document.md");
        string originalText = "纯文本，无 BOM 标记";
        await File.WriteAllTextAsync(filePath, originalText, new UTF8Encoding(false));

        var loaded = await DocumentStorage.ReadAsync(filePath);

        Assert.False(loaded.HasBom);
        Assert.Equal(originalText, loaded.Text);
    }

    [Fact]
    public async Task SaveAsync_BomRoundtrip_PreservesBomState()
    {
        string filePath = Path.Combine(_testDirectory, "roundtrip_bom.md");
        string text = "测试 BOM 往返与切换";

        // 1. 初始以带 BOM 写入
        var baseline1 = await DocumentStorage.SaveAsync(filePath, text, hasBom: true, expectedBaseline: null);
        byte[] bytes1 = await File.ReadAllBytesAsync(filePath);
        Assert.True(bytes1.Length >= 3 && bytes1[0] == 0xEF && bytes1[1] == 0xBB && bytes1[2] == 0xBF);

        var loaded1 = await DocumentStorage.ReadAsync(filePath);
        Assert.True(loaded1.HasBom);
        Assert.Equal(text, loaded1.Text);
        Assert.Equal(baseline1.Sha256, loaded1.Baseline.Sha256);

        // 2. 切换为不带 BOM 保存
        var baseline2 = await DocumentStorage.SaveAsync(filePath, text, hasBom: false, expectedBaseline: loaded1.Baseline);
        byte[] bytes2 = await File.ReadAllBytesAsync(filePath);
        Assert.False(bytes2.Length >= 3 && bytes2[0] == 0xEF && bytes2[1] == 0xBB && bytes2[2] == 0xBF);

        var loaded2 = await DocumentStorage.ReadAsync(filePath);
        Assert.False(loaded2.HasBom);
        Assert.Equal(text, loaded2.Text);
        Assert.Equal(baseline2.Sha256, loaded2.Baseline.Sha256);
    }

    [Fact]
    public async Task ReadAndSave_MixedLineEndings_PreservesExactLineEndings()
    {
        string filePath = Path.Combine(_testDirectory, "mixed_line_endings.md");
        // 显式混合 CRLF, LF, CR
        string mixedText = "Line1 CRLF\r\nLine2 LF\nLine3 CR\rLine4 CRLF\r\nEnd";

        await DocumentStorage.SaveAsync(filePath, mixedText, hasBom: false, expectedBaseline: null);
        var loaded = await DocumentStorage.ReadAsync(filePath);

        Assert.Equal(mixedText, loaded.Text);
        Assert.Contains("\r\n", loaded.Text);
        Assert.Contains("\n", loaded.Text);
        Assert.Contains("\r", loaded.Text);

        // 再次保存后读取，确认完全忠实往返
        await DocumentStorage.SaveAsync(filePath, loaded.Text, hasBom: false, loaded.Baseline);
        var reloaded = await DocumentStorage.ReadAsync(filePath);
        Assert.Equal(mixedText, reloaded.Text);
    }

    [Fact]
    public async Task ReadAsync_InvalidUtf8_ThrowsDecoderFallbackException_AndPreservesOriginalFile()
    {
        string filePath = Path.Combine(_testDirectory, "invalid_utf8.dat");
        // 包含非法 UTF-8 字节序列（0xFF, 0xFE）
        byte[] invalidBytes = [0x48, 0x65, 0x6C, 0x6C, 0x6F, 0xFF, 0xFE, 0x21];
        await File.WriteAllBytesAsync(filePath, invalidBytes);
        DateTime originalMTime = File.GetLastWriteTimeUtc(filePath);

        await Assert.ThrowsAnyAsync<DecoderFallbackException>(async () =>
        {
            await DocumentStorage.ReadAsync(filePath);
        });

        // 验证原文件未受任何改动
        byte[] diskBytes = await File.ReadAllBytesAsync(filePath);
        Assert.Equal(invalidBytes, diskBytes);
        Assert.Equal(originalMTime, File.GetLastWriteTimeUtc(filePath));
    }

    [Fact]
    public async Task SaveAsync_WhenDestinationLockedExclusively_FailsPreservesOriginalFileAndCleansTemp()
    {
        string filePath = Path.Combine(_testDirectory, "locked_target.txt");
        string originalContent = "不可篡改的初始内容";
        await File.WriteAllTextAsync(filePath, originalContent, Encoding.UTF8);

        var loaded = await DocumentStorage.ReadAsync(filePath);

        // 以独占模式打开目标文件（禁止共享写入与删除替换）
        using (var lockStream = new FileStream(filePath, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            await Assert.ThrowsAnyAsync<IOException>(async () =>
            {
                await DocumentStorage.SaveAsync(
                    filePath,
                    "试图覆盖的新内容",
                    hasBom: false,
                    expectedBaseline: null,
                    overwriteExternal: false);
            });
        }

        // 释放独占锁后，验证原文件完好无损
        string currentContent = await File.ReadAllTextAsync(filePath, Encoding.UTF8);
        Assert.Equal(originalContent, currentContent);

        // 验证临时文件已清理，未残留垃圾文件
        string[] tempFiles = Directory.GetFiles(_testDirectory, "*.tmp");
        Assert.Empty(tempFiles);
    }

    [Fact]
    public async Task SaveAsync_ExternalModification_SameLengthSameMTimeDifferentHash_ThrowsExternalChangeException()
    {
        string filePath = Path.Combine(_testDirectory, "hash_conflict.txt");
        await File.WriteAllTextAsync(filePath, "AAAA", Encoding.UTF8);

        var loaded = await DocumentStorage.ReadAsync(filePath);

        // 外部修改为相同长度（4 字节）的不同内容，并将修改时间强行重置为原基准时间
        await File.WriteAllTextAsync(filePath, "BBBB", Encoding.UTF8);
        File.SetLastWriteTimeUtc(filePath, loaded.Baseline.LastWriteTimeUtc);

        var currentInfo = new FileInfo(filePath);
        Assert.Equal(loaded.Baseline.Length, currentInfo.Length);
        Assert.Equal(loaded.Baseline.LastWriteTimeUtc, currentInfo.LastWriteTimeUtc);

        // 因 SHA256 哈希发生变化，未确认覆盖时必须抛出 ExternalChangeException
        await Assert.ThrowsAsync<ExternalChangeException>(async () =>
        {
            await DocumentStorage.SaveAsync(
                filePath,
                "本地编辑内容",
                hasBom: false,
                expectedBaseline: loaded.Baseline,
                overwriteExternal: false);
        });

        // 验证原外部修改内容未被静默覆盖，临时文件已清理
        string currentDiskText = await File.ReadAllTextAsync(filePath, Encoding.UTF8);
        Assert.Equal("BBBB", currentDiskText);
        Assert.Empty(Directory.GetFiles(_testDirectory, "*.tmp"));
    }

    [Fact]
    public async Task SaveAsync_ExternalModification_DifferentLengthOrTime_ThrowsExternalChangeException()
    {
        string filePath = Path.Combine(_testDirectory, "meta_conflict.txt");
        await File.WriteAllTextAsync(filePath, "初始文字", Encoding.UTF8);

        var loaded = await DocumentStorage.ReadAsync(filePath);

        // 外部追加修改（长度改变）
        await File.WriteAllTextAsync(filePath, "外部进程追加了更长的文字", Encoding.UTF8);

        await Assert.ThrowsAsync<ExternalChangeException>(async () =>
        {
            await DocumentStorage.SaveAsync(
                filePath,
                "本地修改",
                hasBom: false,
                expectedBaseline: loaded.Baseline,
                overwriteExternal: false);
        });

        Assert.Empty(Directory.GetFiles(_testDirectory, "*.tmp"));
    }

    [Fact]
    public async Task SaveAsync_ExternalDeletion_ThrowsExternalChangeException_AndCleansTemp()
    {
        string filePath = Path.Combine(_testDirectory, "deleted_conflict.txt");
        await File.WriteAllTextAsync(filePath, "即将被外部删除的文件", Encoding.UTF8);

        var loaded = await DocumentStorage.ReadAsync(filePath);

        // 外部删除文件
        File.Delete(filePath);
        Assert.False(File.Exists(filePath));

        // 保存时预期文件存在，因被外部删除抛出 ExternalChangeException
        await Assert.ThrowsAsync<ExternalChangeException>(async () =>
        {
            await DocumentStorage.SaveAsync(
                filePath,
                "准备保存的内容",
                hasBom: false,
                expectedBaseline: loaded.Baseline,
                overwriteExternal: false);
        });

        // 确保不会残留临时文件，也不会意外生成空文件
        Assert.False(File.Exists(filePath));
        Assert.Empty(Directory.GetFiles(_testDirectory, "*.tmp"));
    }

    [Fact]
    public async Task SaveAsync_OverwriteExternalTrue_SucceedsWhenConflictOrDeleted()
    {
        string filePath = Path.Combine(_testDirectory, "overwrite_confirm.txt");
        await File.WriteAllTextAsync(filePath, "第一版", Encoding.UTF8);

        var loaded = await DocumentStorage.ReadAsync(filePath);

        // 外部修改
        await File.WriteAllTextAsync(filePath, "外部修改版", Encoding.UTF8);

        // 用户通过对话框确认覆盖 (overwriteExternal = true)
        var newBaseline = await DocumentStorage.SaveAsync(
            filePath,
            "强制覆盖后的本地内容",
            hasBom: false,
            expectedBaseline: loaded.Baseline,
            overwriteExternal: true);

        Assert.NotNull(newBaseline);
        string diskContent = await File.ReadAllTextAsync(filePath, Encoding.UTF8);
        Assert.Equal("强制覆盖后的本地内容", diskContent);

        // 外部被删除后，overwriteExternal = true 仍能正常重建文件
        File.Delete(filePath);
        var recreateBaseline = await DocumentStorage.SaveAsync(
            filePath,
            "重新写入的内容",
            hasBom: false,
            expectedBaseline: newBaseline,
            overwriteExternal: true);

        Assert.True(File.Exists(filePath));
        Assert.Equal(recreateBaseline.Length, new FileInfo(filePath).Length);
    }

    [Fact]
    public async Task SaveAsync_ExpectedBaselineNull_AsSaveAs_SucceedsForNewOrExistingFile()
    {
        string filePath = Path.Combine(_testDirectory, "save_as_target.md");

        // 另存为全新文件
        var baseline1 = await DocumentStorage.SaveAsync(
            filePath,
            "另存为新文件内容",
            hasBom: false,
            expectedBaseline: null);

        Assert.True(File.Exists(filePath));
        Assert.Equal("另存为新文件内容", await File.ReadAllTextAsync(filePath, Encoding.UTF8));

        // 另存为覆盖已确认的文件（expectedBaseline 为 null）
        var baseline2 = await DocumentStorage.SaveAsync(
            filePath,
            "另存为覆盖后的内容",
            hasBom: false,
            expectedBaseline: null);

        Assert.NotEqual(baseline1.Sha256, baseline2.Sha256);
        Assert.Equal("另存为覆盖后的内容", await File.ReadAllTextAsync(filePath, Encoding.UTF8));
    }

    [Fact]
    public async Task SaveAsync_NonExistentParentDirectory_ThrowsDirectoryNotFoundException()
    {
        string invalidPath = Path.Combine(_testDirectory, "no_such_folder", "file.txt");

        await Assert.ThrowsAsync<DirectoryNotFoundException>(async () =>
        {
            await DocumentStorage.SaveAsync(
                invalidPath,
                "一些文本",
                hasBom: false,
                expectedBaseline: null);
        });

        Assert.False(Directory.Exists(Path.Combine(_testDirectory, "no_such_folder")));
        Assert.Empty(Directory.GetFiles(_testDirectory, "*.tmp", SearchOption.AllDirectories));
    }

    [Fact]
    public async Task ReadAndSave_EmptyFile_Succeeds()
    {
        string filePath = Path.Combine(_testDirectory, "empty.txt");

        var baseline = await DocumentStorage.SaveAsync(filePath, string.Empty, hasBom: false, expectedBaseline: null);
        Assert.Equal(0, baseline.Length);

        var loaded = await DocumentStorage.ReadAsync(filePath);
        Assert.Equal(string.Empty, loaded.Text);
        Assert.False(loaded.HasBom);
        Assert.Equal("utf-8", loaded.Encoding);
        Assert.Equal(0, loaded.Baseline.Length);
    }

    [Fact]
    public async Task ReadAndSave_Utf16WithBom_RoundTripsLosslessly()
    {
        string text = "# 标题\r\nHello UTF-16";

        string lePath = Path.Combine(_testDirectory, "utf16le.md");
        byte[] leBytes = [0xFF, 0xFE, .. new UnicodeEncoding(bigEndian: false, byteOrderMark: false).GetBytes(text)];
        await File.WriteAllBytesAsync(lePath, leBytes);
        var loadedLe = await DocumentStorage.ReadAsync(lePath);
        Assert.Equal("utf-16le", loadedLe.Encoding);
        Assert.True(loadedLe.HasBom);
        Assert.Equal(text, loadedLe.Text);
        await DocumentStorage.SaveAsync(lePath, loadedLe.Text, loadedLe.HasBom, loadedLe.Baseline, encoding: loadedLe.Encoding);
        Assert.Equal(leBytes, await File.ReadAllBytesAsync(lePath));

        string bePath = Path.Combine(_testDirectory, "utf16be.md");
        byte[] beBytes = [0xFE, 0xFF, .. new UnicodeEncoding(bigEndian: true, byteOrderMark: false).GetBytes(text)];
        await File.WriteAllBytesAsync(bePath, beBytes);
        var loadedBe = await DocumentStorage.ReadAsync(bePath);
        Assert.Equal("utf-16be", loadedBe.Encoding);
        Assert.True(loadedBe.HasBom);
        Assert.Equal(text, loadedBe.Text);
        await DocumentStorage.SaveAsync(bePath, loadedBe.Text, loadedBe.HasBom, loadedBe.Baseline, encoding: loadedBe.Encoding);
        Assert.Equal(beBytes, await File.ReadAllBytesAsync(bePath));
    }

    [Fact]
    public async Task ReadAndSave_Gb18030_RoundTripsLosslessly()
    {
        string filePath = Path.Combine(_testDirectory, "gb18030.md");
        byte[] original = [0x23, 0x20, 0xD6, 0xD0, 0xCE, 0xC4, 0x0D, 0x0A]; // "# 中文\r\n"
        await File.WriteAllBytesAsync(filePath, original);

        var loaded = await DocumentStorage.ReadAsync(filePath);
        Assert.Equal("gb18030", loaded.Encoding);
        Assert.False(loaded.HasBom);
        Assert.Equal("# 中文\r\n", loaded.Text);

        byte[] updatedExpected = [0x23, 0x20, 0xD6, 0xD0, 0xCE, 0xC4, 0xA3, 0xAC, 0xC4, 0xAB, 0xB3, 0xD8, 0x0D, 0x0A]; // "# 中文，墨池\r\n"
        await DocumentStorage.SaveAsync(filePath, "# 中文，墨池\r\n", loaded.HasBom, loaded.Baseline, encoding: loaded.Encoding);
        Assert.Equal(updatedExpected, await File.ReadAllBytesAsync(filePath));
    }
}
