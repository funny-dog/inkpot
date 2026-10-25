using Inkpot.Workspace;

namespace Inkpot.Tests;

public sealed class FileTreeTests
{
    [Fact]
    public void ListsOnlyImmediateTextFilesAndDirectoriesInNaturalOrder()
    {
        string directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            Directory.CreateDirectory(Path.Combine(directory, "子目录"));
            File.WriteAllText(Path.Combine(directory, "子目录", "嵌套.md"), "子文档");
            foreach (string name in new[] { "文档10.md", "文档2.MD", "笔记.txt", "说明.markdown", "image.png", "隐藏.md" })
                File.WriteAllText(Path.Combine(directory, name), "中文");
            File.SetAttributes(Path.Combine(directory, "隐藏.md"), FileAttributes.Hidden);
            var entries = FileTree.ReadDirectory(directory);
            Assert.True(entries[0].IsDirectory);
            Assert.Equal("子目录", entries[0].Name);
            Assert.Equal(5, entries.Length);
            Assert.True(Array.FindIndex(entries, entry => entry.Name == "文档2.MD") < Array.FindIndex(entries, entry => entry.Name == "文档10.md"));
            Assert.DoesNotContain(entries, entry => entry.Name is "隐藏.md" or "嵌套.md" or "image.png");
        }
        finally { Directory.Delete(directory, true); }
    }

    [Theory]
    [InlineData("2.md", "10.md")]
    [InlineData("99999999999999999999.md", "100000000000000000000.md")]
    [InlineData("a2.md", "A10.md")]
    public void NaturalOrderDoesNotOverflow(string first, string second)
    {
        Assert.True(FileTree.CompareNames(first, second) < 0);
        Assert.True(FileTree.CompareNames(second, first) > 0);
        Assert.Equal(0, FileTree.CompareNames(first, first));
    }

    [Fact]
    public void MissingDirectoryIsAnError() => Assert.ThrowsAny<IOException>(() => FileTree.ReadDirectory(Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"))));
}
