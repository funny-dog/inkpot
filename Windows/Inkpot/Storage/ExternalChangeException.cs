namespace Inkpot.Storage;

using System.IO;

/// <summary>
/// 当目标文件在外部被修改或删除，且未明确授权覆盖时抛出的异常。
/// </summary>
public class ExternalChangeException : IOException
{
    public ExternalChangeException()
    {
    }

    public ExternalChangeException(string? message) : base(message)
    {
    }

    public ExternalChangeException(string? message, Exception? innerException) : base(message, innerException)
    {
    }
}
