using System.Runtime.InteropServices;

namespace Inkpot;

internal static class FontCatalog
{
    private static (string[] All, string[] Mono)? cached;
    internal static string[] Families(bool code)
    {
        if (cached is null)
        {
            var all = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var mono = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            nint context = GetDC(0);
            try
            {
                var font = new LogFont { CharSet = 1, FaceName = "" };
                FontCallback callback = (description, metric, _, _) =>
                {
                    string? name = Marshal.PtrToStructure<LogFont>(description).FaceName;
                    if (!string.IsNullOrEmpty(name) && !name.StartsWith('@'))
                    { all.Add(name); if ((Marshal.ReadByte(metric, 55) & 1) == 0) mono.Add(name); }
                    return 1;
                };
                EnumFontFamiliesEx(context, ref font, callback, 0, 0);
                GC.KeepAlive(callback);
            }
            finally { ReleaseDC(0, context); }
            cached = (all.Order(StringComparer.CurrentCultureIgnoreCase).ToArray(), mono.Order(StringComparer.CurrentCultureIgnoreCase).ToArray());
        }
        return code ? cached.Value.Mono : cached.Value.All;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private struct LogFont
    {
        internal int Height, Width, Escapement, Orientation, Weight;
        internal byte Italic, Underline, StrikeOut, CharSet, OutPrecision, ClipPrecision, Quality, PitchAndFamily;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] internal string FaceName;
    }
    private delegate int FontCallback(nint description, nint metric, uint type, nint parameter);
    [DllImport("user32.dll")] private static extern nint GetDC(nint window);
    [DllImport("user32.dll")] private static extern int ReleaseDC(nint window, nint context);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode, EntryPoint = "EnumFontFamiliesExW")]
    private static extern int EnumFontFamiliesEx(nint context, ref LogFont font, FontCallback callback, nint parameter, uint flags);
}
