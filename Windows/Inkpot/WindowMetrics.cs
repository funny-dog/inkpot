using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;

namespace Inkpot;

internal static class WindowMetrics
{
    internal static void Resize(Window window, int width, int height)
    {
        double scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(window)) / 96.0;
        var area = DisplayArea.GetFromWindowId(window.AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        int physicalWidth = Math.Min(area.Width, (int)(width * scale)), physicalHeight = Math.Min(area.Height, (int)(height * scale));
        window.AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(area.X + (area.Width - physicalWidth) / 2,
            area.Y + (area.Height - physicalHeight) / 2, physicalWidth, physicalHeight));
    }
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint window);
}
