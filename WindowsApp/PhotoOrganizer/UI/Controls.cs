using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using PhotoOrganizer.Core;

namespace PhotoOrganizer.UI;

/// <summary>
/// Joined buttons, one of which is selected ("По годам | По месяцам | По дням"). Segments may carry a count
/// ("Все 4 239") in bolder text; a segment with a count of 0 can't be chosen.
/// </summary>
public sealed class SegmentedControl : Border
{
    readonly StackPanel _panel = new() { Orientation = Orientation.Horizontal };
    readonly List<Border> _segments = [];
    readonly List<(TextBlock Title, TextBlock Count)> _texts = [];
    int _selected;
    bool[] _enabled = [];

    public event Action<int>? Changed;

    public SegmentedControl(string[] titles, double height = 30)
    {
        Height = height;
        CornerRadius = new CornerRadius(7);
        Padding = new Thickness(2);
        SetResourceReference(BackgroundProperty, "Segment");
        Child = _panel;
        _enabled = titles.Select(_ => true).ToArray();
        for (int i = 0; i < titles.Length; i++)
        {
            int index = i;
            var title = new TextBlock { Text = titles[i], VerticalAlignment = VerticalAlignment.Center };
            var count = new TextBlock { FontWeight = FontWeights.SemiBold, Margin = new Thickness(6, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed };
            var content = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
            content.Children.Add(title);
            content.Children.Add(count);
            var segment = new Border { Padding = new Thickness(12, 0, 12, 0), CornerRadius = new CornerRadius(5.5), Child = content, Cursor = Cursors.Hand, Background = Brushes.Transparent };
            segment.MouseLeftButtonUp += (_, _) => Select(index, notify: true);
            segment.MouseEnter += (_, _) => Paint();
            segment.MouseLeave += (_, _) => Paint();
            _segments.Add(segment);
            _texts.Add((title, count));
            _panel.Children.Add(segment);
        }
        Paint();
    }

    public int Selected
    {
        get => _selected;
        set
        {
            _selected = value;
            Paint();
        }
    }

    public void SetCounts(long[] counts)
    {
        for (int i = 0; i < counts.Length && i < _texts.Count; i++)
        {
            _texts[i].Count.Text = Strings.Number(counts[i]);
            _texts[i].Count.Visibility = Visibility.Visible;
            _enabled[i] = counts[i] > 0 || i == _selected;
        }
        Paint();
    }

    void Select(int index, bool notify)
    {
        if (!_enabled[index] || index == _selected) return;
        _selected = index;
        Paint();
        if (notify) Changed?.Invoke(index);
    }

    void Paint()
    {
        for (int i = 0; i < _segments.Count; i++)
        {
            var segment = _segments[i];
            if (i == _selected)
            {
                segment.SetResourceReference(Border.BackgroundProperty, "SegmentSelected");
                segment.SetResourceReference(Border.BorderBrushProperty, "CellBorder");
                segment.BorderThickness = new Thickness(0.8);
            }
            else
            {
                segment.Background = segment.IsMouseOver && _enabled[i] ? new SolidColorBrush(Color.FromArgb(70, 128, 128, 128)) : Brushes.Transparent;
                segment.BorderThickness = new Thickness(0);
            }
            foreach (var text in new[] { _texts[i].Title, _texts[i].Count })
            {
                text.SetResourceReference(TextBlock.ForegroundProperty, _enabled[i] ? "Text" : "Tertiary");
            }
            segment.Cursor = _enabled[i] ? Cursors.Hand : Cursors.Arrow;
        }
    }
}

/// <summary>Small helpers for building the interface in code.</summary>
public static class Ui
{
    public static TextBlock Glyph(string name, double size, string brush = "Secondary")
    {
        var text = new TextBlock
        {
            Text = Theme.Glyphs.GetValueOrDefault(name, name),
            FontFamily = new FontFamily(Theme.IconFont),
            FontSize = size,
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        text.SetResourceReference(TextBlock.ForegroundProperty, brush);
        return text;
    }

    public static Button IconButton(string glyph, string tooltip, Action click)
    {
        var button = new Button { Content = Theme.Glyphs.GetValueOrDefault(glyph, glyph), ToolTip = tooltip };
        button.SetResourceReference(FrameworkElement.StyleProperty, "IconButton");
        button.Click += (_, _) => click();
        return button;
    }

    public static Button TextButton(string text, Action click, bool primary = false)
    {
        var button = new Button { Content = text };
        if (primary) button.SetResourceReference(FrameworkElement.StyleProperty, "Primary");
        button.Click += (_, _) => click();
        return button;
    }

    public static TextBlock Text(string text, string? style = null, double? size = null, FontWeight? weight = null)
    {
        var block = new TextBlock { Text = text, TextTrimming = TextTrimming.CharacterEllipsis };
        Styled(block, style);
        if (size is { } s) block.FontSize = s;
        if (weight is { } w) block.FontWeight = w;
        return block;
    }

    /// <summary>"Secondary": grey text; "Hint": small grey text that wraps.</summary>
    public static void Styled(TextBlock block, string? style)
    {
        if (style == null) return;
        block.SetResourceReference(TextBlock.ForegroundProperty, "Secondary");
        if (style != "Hint") return;
        block.FontSize = 12;
        block.TextWrapping = TextWrapping.Wrap;
        block.TextTrimming = TextTrimming.None;
    }

    public static Border Bar(string background, Thickness border)
    {
        var bar = new Border { BorderThickness = border };
        bar.SetResourceReference(Border.BackgroundProperty, background);
        bar.SetResourceReference(Border.BorderBrushProperty, "Separator");
        return bar;
    }
}
