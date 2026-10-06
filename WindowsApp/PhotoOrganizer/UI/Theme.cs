using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using Microsoft.Win32;

namespace PhotoOrganizer.UI;

/// <summary>Colours that follow the macOS app's look, in the light or dark Windows theme, with the Windows accent colour.</summary>
public static class Theme
{
    public static bool Dark { get; private set; }

    static bool AppsUseDarkTheme()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        return key?.GetValue("AppsUseLightTheme") is int light && light == 0;
    }

    static Color Accent()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\DWM");
        if (key?.GetValue("AccentColor") is int abgr)
        {
            var color = Color.FromRgb((byte)(abgr & 0xFF), (byte)((abgr >> 8) & 0xFF), (byte)((abgr >> 16) & 0xFF));
            // A grey accent would make selections invisible.
            int max = Math.Max(color.R, Math.Max(color.G, color.B)), min = Math.Min(color.R, Math.Min(color.G, color.B));
            if (max - min > 40) return color;
        }
        return Color.FromRgb(0x0A, 0x84, 0xFF);
    }

    static Color Hex(string hex) => (Color)ColorConverter.ConvertFromString(hex);

    static void Set(ResourceDictionary resources, string key, Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        resources[key] = brush;
        resources[key + "Color"] = color;
    }

    public static Color Get(string key) => (Color)Application.Current.Resources[key + "Color"];
    public static Brush Brush(string key) => (Brush)Application.Current.Resources[key];

    public static void Apply(ResourceDictionary resources)
    {
        Dark = AppsUseDarkTheme();
        var accent = Accent();
        Set(resources, "Accent", accent);
        Set(resources, "AccentHover", Mix(accent, Colors.White, 0.12));
        Set(resources, "AccentText", Colors.White);
        if (Dark)
        {
            Set(resources, "Window", Hex("#1E1E1E"));
            Set(resources, "Sidebar", Hex("#2A2A2C"));
            Set(resources, "Toolbar", Hex("#2C2C2E"));
            Set(resources, "Text", Hex("#F2F2F2"));
            Set(resources, "Secondary", Hex("#A1A1A6"));
            Set(resources, "Tertiary", Hex("#6E6E73"));
            Set(resources, "Separator", Hex("#3A3A3C"));
            Set(resources, "Selection", Hex("#464649"));
            Set(resources, "Hover", Hex("#3A3A3D"));
            Set(resources, "Cell", Hex("#2C2C2E"));
            Set(resources, "CellBorder", Color.FromArgb(28, 255, 255, 255));
            Set(resources, "Control", Hex("#3A3A3C"));
            Set(resources, "ControlHover", Hex("#48484A"));
            Set(resources, "ControlPressed", Hex("#545456"));
            Set(resources, "Field", Hex("#1C1C1E"));
            Set(resources, "Segment", Hex("#3A3A3C"));
            Set(resources, "SegmentSelected", Hex("#636366"));
        }
        else
        {
            Set(resources, "Window", Hex("#FFFFFF"));
            Set(resources, "Sidebar", Hex("#EBEBEB"));
            Set(resources, "Toolbar", Hex("#F3F3F3"));
            Set(resources, "Text", Hex("#1D1D1F"));
            Set(resources, "Secondary", Hex("#6E6E73"));
            Set(resources, "Tertiary", Hex("#A1A1A6"));
            Set(resources, "Separator", Hex("#D9D9D9"));
            Set(resources, "Selection", Hex("#D4D4D6"));
            Set(resources, "Hover", Hex("#E0E0E2"));
            Set(resources, "Cell", Hex("#ECECEE"));
            Set(resources, "CellBorder", Color.FromArgb(22, 0, 0, 0));
            Set(resources, "Control", Hex("#FFFFFF"));
            Set(resources, "ControlHover", Hex("#F5F5F5"));
            Set(resources, "ControlPressed", Hex("#E6E6E6"));
            Set(resources, "Field", Hex("#FFFFFF"));
            Set(resources, "Segment", Hex("#E3E3E5"));
            Set(resources, "SegmentSelected", Hex("#FFFFFF"));
        }
        Set(resources, "BadgeOrange", Hex("#FF9500"));
        Set(resources, "BadgePurple", Hex("#AF52DE"));
        Set(resources, "BadgeGreen", Hex("#34C759"));
        Set(resources, "BadgePink", Hex("#FF2D55"));
    }

    static Color Mix(Color a, Color b, double amount) => Color.FromRgb(
        (byte)(a.R + (b.R - a.R) * amount), (byte)(a.G + (b.G - a.G) * amount), (byte)(a.B + (b.B - a.B) * amount));

    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);

    /// <summary>A dark title bar for the dark theme (Windows 10 20H1 and later).</summary>
    /// <summary>
    /// The app's window style and a title bar that follows the theme. Implicit styles only reach the exact type, and
    /// every window here is a subclass of Window, so App.xaml's Window style is attached by hand.
    /// </summary>
    public static void StyleTitleBar(Window window)
    {
        window.SetResourceReference(FrameworkElement.StyleProperty, typeof(Window));
        window.SourceInitialized += (_, _) =>
        {
            int dark = Dark ? 1 : 0;
            var handle = new WindowInteropHelper(window).Handle;
            if (DwmSetWindowAttribute(handle, 20, ref dark, sizeof(int)) != 0) DwmSetWindowAttribute(handle, 19, ref dark, sizeof(int));
        };
    }

    public const string IconFont = "Segoe Fluent Icons, Segoe MDL2 Assets";

    // Glyphs of Segoe Fluent Icons (Windows 11) / Segoe MDL2 Assets (Windows 10), standing in for SF Symbols.
    public static readonly Dictionary<string, string> Glyphs = new()
    {
        ["library"] = "", ["calendar"] = "", ["calendar-clock"] = "", ["calendar-warning"] = "",
        ["search"] = "", ["folder"] = "", ["refresh"] = "", ["open-external"] = "",
        ["duplicates"] = "", ["thumbnails"] = "", ["person"] = "", ["face-search"] = "",
        ["settings"] = "", ["chevron-down"] = "", ["chevron-right"] = "", ["play"] = "",
        ["pause"] = "", ["back"] = "", ["forward"] = "", ["zoom-in"] = "", ["zoom-out"] = "",
        ["photo"] = "", ["video"] = "",
        ["object-search"] = "", ["photo-search"] = "", ["map"] = "", ["tag"] = "", ["explicit"] = "",
        ["add"] = "", ["viewfinder"] = "", ["download"] = "",
    };
}
