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
    public void ParsesOutlineAndExportResponsesWithoutLosingHeadingHierarchy()
    {
        var outline = Assert.IsType<OutlineMessage>(HostMessage.Parse("{\"outline\":true,\"generation\":2,\"revision\":4,\"headings\":[{\"id\":7,\"level\":2,\"title\":\"中文标题\"}],\"active\":7}"));
        Assert.Equal(new Heading(7, 2, "中文标题"), Assert.Single(outline.Headings!)); Assert.Equal(7, outline.Active);
        Assert.Equal("<html>中文</html>", Assert.IsType<ResponseMessage>(HostMessage.Parse("{\"response\":true,\"requestId\":4,\"value\":\"<html>中文</html>\"}")).Value);
    }

    [Fact]
    public void ParsesOutlineAndActiveOnlyUpdatesWithoutLosingHeadings()
    {
        var message = Assert.IsType<OutlineMessage>(HostMessage.Parse("""
            {"outline":true,"generation":2,"revision":3,"headings":[{"id":0,"from":0,"to":5,"level":1,"title":"标题"}],"active":0}
            """));
        Assert.Equal(new Heading(0, 1, "标题"), Assert.Single(message.Headings!));
        Assert.Equal(0, message.Active);
        var update = Assert.IsType<OutlineMessage>(HostMessage.Parse("""
            {"outline":true,"generation":2,"revision":3,"active":null}
            """));
        Assert.Null(update.Headings);
        Assert.Null(update.Active);
    }

    [Theory]
    [InlineData("{\"id\":0,\"from\":0,\"to\":5,\"level\":7,\"title\":\"x\"}")]
    [InlineData("{\"id\":-1,\"from\":0,\"to\":5,\"level\":1,\"title\":\"x\"}")]
    [InlineData("{\"id\":0,\"from\":5,\"to\":0,\"level\":1,\"title\":\"x\"}")]
    [InlineData("{\"id\":0,\"from\":0,\"to\":5,\"level\":1,\"title\":null}")]
    public void RejectsInvalidOutlineHeadings(string heading)
        => Assert.Null(HostMessage.Parse("{\"outline\":true,\"generation\":2,\"revision\":0,\"active\":null,\"headings\":[" + heading + "]}"));

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
