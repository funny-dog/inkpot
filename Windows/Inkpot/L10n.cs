using System.Globalization;
using System.Resources;

namespace Inkpot;

internal static class L10n
{
    internal static string Language { get; } = CultureInfo.CurrentUICulture.Name.StartsWith("zh", StringComparison.OrdinalIgnoreCase) ? "zh-Hans" : "en";
    private static readonly ResourceManager Resources = new("Inkpot.Strings.Resources", typeof(L10n).Assembly);
    internal static string Text(string key) => Resources.GetString(key, CultureInfo.GetCultureInfo(Language)) ?? key;
}
