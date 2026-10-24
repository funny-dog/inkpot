using Inkpot.Bridge;
using Inkpot.Storage;

namespace Inkpot.Tests;

public sealed class BridgeTests
{
    [Fact]
    public void ParsesReadySnapshotAndShortcut()
    {
        Assert.IsType<ReadyMessage>(HostMessage.Parse("{\"ready\":true}"));
        var response = Assert.IsType<ResponseMessage>(HostMessage.Parse("{\"response\":true,\"requestId\":3,\"snapshot\":{\"text\":\"中文\\r\\n尾\",\"revision\":2}}"));
        Assert.Equal(new EditorSnapshot("中文\r\n尾", 2), response.Snapshot);
        Assert.Equal(3, response.RequestId);
        Assert.Equal(new ShortcutMessage(7, "save"), HostMessage.Parse("{\"shortcut\":\"save\",\"generation\":7}"));
    }

    [Theory]
    [InlineData("null")]
    [InlineData("[]")]
    [InlineData("{")]
    [InlineData("{\"ready\":\"true\"}")]
    [InlineData("{\"changed\":true,\"generation\":-1}")]
    [InlineData("{\"changed\":true,\"generation\":1,\"revision\":-1}")]
    public void InvalidMessagesCannotUpdateState(string json) => Assert.Null(HostMessage.Parse(json));

    [Fact]
    public async Task SavedBaselineMatchesDiskAndCanBeUsedForNextSave()
    {
        string directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            string path = Path.Combine(directory, "测试.md");
            var saved = await DocumentStorage.SaveAsync(path, "中文\r\n尾", true, null);
            Assert.Equal(saved, (await DocumentStorage.ReadAsync(path)).Baseline);
            var next = await DocumentStorage.SaveAsync(path, "修改\r\n尾", true, saved);
            Assert.Equal(next, (await DocumentStorage.ReadAsync(path)).Baseline);
        }
        finally { Directory.Delete(directory, true); }
    }
}
