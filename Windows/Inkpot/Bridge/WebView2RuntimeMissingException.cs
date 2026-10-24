namespace Inkpot.Bridge;

using System;

/// <summary>
/// 未检测到可用的 WebView2 运行时时抛出，由界面提示用户下载安装。
/// </summary>
public class WebView2RuntimeMissingException : Exception
{
    public WebView2RuntimeMissingException(Exception? innerException) : base("未检测到 WebView2 运行时。", innerException)
    {
    }
}
