namespace Inkpot.Workspace;

internal sealed record FileTreeEntry(string Path, bool IsDirectory)
{
    internal string Name => System.IO.Path.GetFileName(Path);
    public override string ToString() => Name;
}

internal static class FileTree
{
    // 只枚举当前层，展开时再读取子目录；不跟随链接或目录联接。
    internal static FileTreeEntry[] ReadDirectory(string path)
    {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("不能将链接或目录联接作为文件树目录打开。");
        return new DirectoryInfo(path).EnumerateFileSystemInfos()
            .Where(item => (item.Attributes & (FileAttributes.Hidden | FileAttributes.System | FileAttributes.ReparsePoint)) == 0)
            .Where(item => item is DirectoryInfo || new[] { ".md", ".markdown", ".txt" }.Contains(item.Extension, StringComparer.OrdinalIgnoreCase))
            .Select(item => new FileTreeEntry(item.FullName, item is DirectoryInfo))
            .OrderByDescending(item => item.IsDirectory)
            .ThenBy(item => item.Name, Comparer<string>.Create(CompareNames)).ToArray();
    }

    internal static int CompareNames(string? left, string? right)
    {
        left ??= "";
        right ??= "";
        int first = 0, second = 0;
        while (first < left.Length && second < right.Length)
        {
            if (char.IsAsciiDigit(left[first]) && char.IsAsciiDigit(right[second]))
            {
                int leftStart = first, rightStart = second;
                while (first < left.Length && char.IsAsciiDigit(left[first])) first++;
                while (second < right.Length && char.IsAsciiDigit(right[second])) second++;
                var leftNumber = left.AsSpan(leftStart, first - leftStart).TrimStart('0');
                var rightNumber = right.AsSpan(rightStart, second - rightStart).TrimStart('0');
                int comparison = leftNumber.Length.CompareTo(rightNumber.Length);
                if (comparison == 0) comparison = leftNumber.SequenceCompareTo(rightNumber);
                if (comparison != 0) return comparison;
            }
            else
            {
                int comparison = char.ToUpperInvariant(left[first++]).CompareTo(char.ToUpperInvariant(right[second++]));
                if (comparison != 0) return comparison;
            }
        }
        int remaining = (left.Length - first).CompareTo(right.Length - second);
        return remaining != 0 ? remaining : StringComparer.Ordinal.Compare(left, right);
    }
}
