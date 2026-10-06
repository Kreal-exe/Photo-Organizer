using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using PhotoOrganizer.Core;
using static PhotoOrganizer.Core.Strings;

namespace PhotoOrganizer.UI;

/// <summary>A dialog in the app's style: a heading, content and buttons at the bottom.</summary>
public class Dialog : Window
{
    protected readonly StackPanel Body = new() { Margin = new Thickness(22, 20, 22, 20) };
    protected readonly DockPanel Footer = new() { Margin = new Thickness(0, 14, 0, 0), LastChildFill = false };

    public Dialog(Window owner, string title, double width)
    {
        Owner = owner;
        Title = title;
        Width = width;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;
        Theme.StyleTitleBar(this);
        Content = Body;
    }

    protected void Heading(string text) => Body.Children.Add(new TextBlock { Text = text, Style = (Style)FindResource("Heading"), Margin = new Thickness(0, 0, 0, 4) });

    protected TextBlock Note(string text, string style = "Hint", double bottom = 10)
    {
        var block = new TextBlock { Text = text, Margin = new Thickness(0, 0, 0, bottom) };
        Ui.Styled(block, style);
        block.TextWrapping = TextWrapping.Wrap;
        Body.Children.Add(block);
        return block;
    }

    protected Button AddButton(string text, Action click, bool primary = false, bool left = false)
    {
        var button = Ui.TextButton(text, click, primary);
        button.Margin = left ? new Thickness(0, 0, 8, 0) : new Thickness(8, 0, 0, 0);
        button.MinWidth = 90;
        DockPanel.SetDock(button, left ? Dock.Left : Dock.Right);
        // Right-docked buttons are added right to left: the first one ends up rightmost.
        Footer.Children.Add(button);
        if (primary) button.IsDefault = true;
        return button;
    }

    protected void Finish() => Body.Children.Add(Footer);
}

/// <summary>Asks for one line of text: a folder name, a person's name.</summary>
public sealed class PromptDialog : Dialog
{
    readonly TextBox _field = new() { Height = 32 };

    public PromptDialog(Window owner, string title, string message, string text) : base(owner, title, 460)
    {
        Heading(title);
        Note(message);
        _field.Text = text;
        Body.Children.Add(_field);
        AddButton(L("Ок"), () => DialogResult = true, primary: true);
        AddButton(L("Отмена"), () => DialogResult = false).IsCancel = true;
        Finish();
        Loaded += (_, _) => { _field.Focus(); _field.SelectAll(); };
    }

    public static string? Ask(Window owner, string title, string message, string text = "")
    {
        var dialog = new PromptDialog(owner, title, message, text);
        return dialog.ShowDialog() == true ? dialog._field.Text : null;
    }
}

/// <summary>Gives the selected files a date by hand: a whole date, or only the month or the year when that is all that is known.</summary>
public sealed class DateDialog : Dialog
{
    public const int Remove = 2;
    readonly ComboBox _precision = new(), _month = new();
    readonly TextBox _year = new() { Width = 120, Height = 30 }, _day = new() { Width = 120, Height = 30 };
    public int Outcome { get; private set; }

    public DateDialog(Window owner, List<PhotoItem> items) : base(owner, L("Задать дату"), 420)
    {
        var dated = items.FirstOrDefault(i => !i.Undated);
        DateTime start = dated?.Date ?? items.FirstOrDefault()?.FileDate ?? DateTime.Now;
        Heading(L("Задать дату"));
        Note(F("Выбрано: %@", FilesDetail(items.Count)), "Secondary", 14);
        foreach (string p in new[] { L("Полная дата"), L("Год и месяц"), L("Только год") }) _precision.Items.Add(p);
        _precision.SelectedIndex = 0;
        foreach (string m in new[] { "Январь", "Февраль", "Март", "Апрель", "Май", "Июнь", "Июль", "Август", "Сентябрь", "Октябрь", "Ноябрь", "Декабрь" }) _month.Items.Add(L(m));
        _month.SelectedIndex = start.Month - 1;
        _year.Text = start.Year.ToString();
        _day.Text = start.Day.ToString();
        _precision.SelectionChanged += (_, _) =>
        {
            _month.IsEnabled = _precision.SelectedIndex < 2;
            _day.IsEnabled = _precision.SelectedIndex < 1;
        };
        var form = new Grid();
        form.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(110) });
        form.ColumnDefinitions.Add(new ColumnDefinition());
        int row = 0;
        foreach (var (label, control) in new (string, FrameworkElement)[] { (L("Точность"), _precision), (L("Год"), _year), (L("Месяц"), _month), (L("День"), _day) })
        {
            form.RowDefinitions.Add(new RowDefinition { Height = new GridLength(38) });
            var text = new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center };
            Grid.SetRow(text, row);
            control.HorizontalAlignment = HorizontalAlignment.Left;
            control.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetRow(control, row);
            Grid.SetColumn(control, 1);
            form.Children.Add(text);
            form.Children.Add(control);
            row++;
        }
        Body.Children.Add(form);
        Note(L("Дата будет запомнена для этих файлов; сами файлы не изменяются."), bottom: 0).Margin = new Thickness(0, 10, 0, 0);
        var problem = Note("", "Secondary", 0);
        problem.Visibility = Visibility.Collapsed;
        problem.SetResourceReference(TextBlock.ForegroundProperty, "BadgePink");
        _year.TextChanged += (_, _) => { problem.Visibility = Visibility.Collapsed; _year.ClearValue(Control.BorderBrushProperty); };
        AddButton(L("Сохранить"), () =>
        {
            if (Result() != null)
            {
                Outcome = 1;
                DialogResult = true;
                return;
            }
            // An impossible year: shown, not silently ignored.
            problem.Text = L("Проверьте год: число от 1900 до текущего.");
            problem.Visibility = Visibility.Visible;
            _year.SetResourceReference(Control.BorderBrushProperty, "BadgePink");
            _year.Focus();
            _year.SelectAll();
        }, primary: true);
        AddButton(L("Отмена"), () => DialogResult = false).IsCancel = true;
        var remove = AddButton(L("Убрать дату"), () => { Outcome = Remove; DialogResult = true; }, left: true);
        remove.Visibility = items.Any(i => i.DateSource == DateSource.Manual) ? Visibility.Visible : Visibility.Collapsed;
        Finish();
    }

    /// <summary>(date, precision): noon of the day, or of the first day of the month / year for a less precise date.</summary>
    public (DateTime Date, Precision Precision)? Result()
    {
        if (!int.TryParse(_year.Text, out int year) || year < 1900 || year > DateTime.Now.Year) return null;
        var precision = (Precision)_precision.SelectedIndex;
        int month = precision < Precision.Year ? _month.SelectedIndex + 1 : 1;
        int day = precision == Precision.Day && int.TryParse(_day.Text, out int d) ? Math.Clamp(d, 1, DateTime.DaysInMonth(year, month)) : 1;
        return (new DateTime(year, month, day, 12, 0, 0), precision);
    }
}

/// <summary>How to organize: grouping, folder names, and a preview where every folder can be renamed.</summary>
public sealed class OrganizeDialog : Dialog
{
    readonly Plan _plan;
    readonly Action _onChange;
    readonly ComboBox _scheme = new(), _year = new(), _month = new(), _day = new();
    readonly CheckBox _nested = new(), _duplicates = new(), _tiny = new();
    readonly TextBox _duplicatesField = new() { Width = 220, Height = 30 }, _tinyField = new() { Width = 220, Height = 30 };
    // Grouped by day, a library makes thousands of folders: only the rows on screen are made.
    readonly PreviewList _preview = new();
    readonly TextBlock _summary = new() { TextWrapping = TextWrapping.Wrap, FontSize = 12 };
    readonly Button _reset;
    readonly Button _confirm;
    bool _updating;

    public OrganizeDialog(Window owner, Plan plan, Action onChange) : base(owner, L("Разложить по папкам"), 660)
    {
        _plan = plan;
        _onChange = onChange;
        Heading(L("Разложить по папкам"));
        Note(F("Папки будут созданы внутри «%@». Выберите, как группировать файлы и как назвать папки.", Path.GetFileName(plan.Root.TrimEnd('\\'))), "Secondary", 16);

        Fill(_scheme, L("По годам"), L("По месяцам"), L("По дням"));
        Fill(_year, "2024", L("2024 год"));
        Fill(_month, "2024-03", L("2024-03 Март"), L("03 Март"), L("Март 2024"));
        Fill(_day, "2024-03-15", "15", L("15 марта"));
        _nested.Content = L("Вкладывать папки друг в друга (год → месяц → день)");
        _duplicates.Content = L("Дубликаты — в папку:");
        _tiny.Content = L("Миниатюры — в папку:");
        foreach (var box in new[] { _nested, _duplicates, _tiny }) box.Click += (_, _) => OptionChanged();
        foreach (var field in new[] { _duplicatesField, _tinyField })
        {
            field.LostFocus += (_, _) => OptionChanged();
            field.KeyDown += (_, e) => { if (e.Key == Key.Enter) { OptionChanged(); e.Handled = true; } };
        }

        var form = new Grid { Margin = new Thickness(0, 0, 0, 14) };
        form.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Auto) });
        form.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var rows = new (FrameworkElement Label, FrameworkElement Control)[]
        {
            (Label(L("Группировать:")), _scheme), (Label(L("Название года:")), _year), (Label(L("Название месяца:")), _month),
            (Label(L("Название дня:")), _day), (new Border(), _nested), (_duplicates, _duplicatesField), (_tiny, _tinyField),
        };
        for (int i = 0; i < rows.Length; i++)
        {
            form.RowDefinitions.Add(new RowDefinition { Height = new GridLength(38) });
            rows[i].Label.HorizontalAlignment = HorizontalAlignment.Right;
            rows[i].Label.VerticalAlignment = VerticalAlignment.Center;
            rows[i].Label.Margin = new Thickness(0, 0, 10, 0);
            rows[i].Control.HorizontalAlignment = HorizontalAlignment.Left;
            rows[i].Control.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetRow(rows[i].Label, i);
            Grid.SetRow(rows[i].Control, i);
            Grid.SetColumn(rows[i].Control, 1);
            form.Children.Add(rows[i].Label);
            form.Children.Add(rows[i].Control);
        }
        Body.Children.Add(form);

        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 6) };
        _reset = Ui.TextButton(L("Сбросить названия"), () => { _plan.RemoveCustomNames(); PlanChanged(); });
        _reset.Padding = new Thickness(10, 3, 10, 3);
        DockPanel.SetDock(_reset, Dock.Right);
        header.Children.Add(_reset);
        header.Children.Add(new TextBlock { Text = L("Что получится"), FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        Body.Children.Add(header);

        var table = new Border { BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(6), Height = 230 };
        table.SetResourceReference(Border.BorderBrushProperty, "Separator");
        var tableBody = new DockPanel();
        var columns = new Grid { Margin = new Thickness(10, 5, 14, 5) };
        columns.ColumnDefinitions.Add(new ColumnDefinition());
        columns.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var folderHeader = Ui.Text(L("Папка"), "Secondary", 12);
        var countHeader = Ui.Text(L("Файлов"), "Secondary", 12);
        Grid.SetColumn(countHeader, 1);
        columns.Children.Add(folderHeader);
        columns.Children.Add(countHeader);
        var headerBar = Ui.Bar("Toolbar", new Thickness(0, 0, 0, 1));
        headerBar.CornerRadius = new CornerRadius(6, 6, 0, 0);
        headerBar.Child = columns;
        DockPanel.SetDock(headerBar, Dock.Top);
        tableBody.Children.Add(headerBar);
        _preview.MakeRow = PreviewRow;
        tableBody.Children.Add(_preview);
        table.Child = tableBody;
        Body.Children.Add(table);
        Note(L("Щёлкните по названию, чтобы переименовать папку (можно с вложенностью: «Отпуск/Море»). Одинаковые названия объединят папки, пустое вернёт исходное."), bottom: 0)
            .Margin = new Thickness(0, 6, 0, 0);

        _summary.SetResourceReference(TextBlock.ForegroundProperty, "Secondary");
        _summary.MaxWidth = 380;
        DockPanel.SetDock(_summary, Dock.Left);
        Footer.Children.Add(_summary);
        _confirm = AddButton(L("Разложить"), () => { if (_plan.PendingItems.Count > 0) DialogResult = true; }, primary: true);
        AddButton(L("Отмена"), () => DialogResult = false).IsCancel = true;
        Finish();
        Refresh();
    }

    static TextBlock Label(string text) => new() { Text = text };

    void Fill(ComboBox combo, params string[] titles)
    {
        foreach (string title in titles) combo.Items.Add(title);
        combo.SelectionChanged += (_, _) => OptionChanged();
    }

    void Refresh()
    {
        _updating = true;
        _scheme.SelectedIndex = (int)_plan.Scheme;
        _year.SelectedIndex = (int)_plan.YearStyle;
        _month.SelectedIndex = (int)_plan.MonthStyle;
        _day.SelectedIndex = (int)_plan.DayStyle;
        _month.IsEnabled = _plan.Scheme >= Scheme.YearMonth;
        _day.IsEnabled = _plan.Scheme >= Scheme.YearMonthDay;
        _nested.IsChecked = _plan.Nested;
        _nested.IsEnabled = _plan.Scheme != Scheme.Year;
        _duplicates.IsChecked = _plan.SeparateDuplicates;
        _duplicatesField.Text = _plan.DuplicatesFolderName;
        _duplicatesField.IsEnabled = _plan.SeparateDuplicates;
        _tiny.IsChecked = _plan.SeparateTiny;
        _tinyField.Text = _plan.TinyFolderName;
        _tinyField.IsEnabled = _plan.SeparateTiny;
        _reset.Visibility = _plan.HasCustomNames ? Visibility.Visible : Visibility.Collapsed;
        _preview.ItemsSource = _plan.Groups.Select((group, index) => new PreviewItem(group, index)).ToList();
        int pending = _plan.PendingItems.Count;
        string what = pending > 0
            ? F("Будет перемещено %@ из %@ в %@.", Number(pending), Number(_plan.Items.Count), Count(_plan.Groups.Count, L("папку"), L("папки"), L("папок")))
            : L("Все файлы уже лежат на своих местах.");
        _summary.Text = what + L(" Оригиналы перемещаются, а не копируются; ничего не удаляется и не перезаписывается. Отменить — ⌘Z.").Replace("⌘Z", "Ctrl+Z");
        _confirm.IsEnabled = pending > 0;
        _updating = false;
    }

    sealed record PreviewItem(Group Group, int Index);

    /// <summary>A list that makes its rows as they scroll into view and reuses them.</summary>
    sealed class PreviewList : ListBox
    {
        public Func<Group, int, UIElement>? MakeRow;

        public PreviewList()
        {
            Background = Brushes.Transparent;
            BorderThickness = new Thickness(0);
            Padding = new Thickness(0);
            VirtualizingPanel.SetIsVirtualizing(this, true);
            VirtualizingPanel.SetVirtualizationMode(this, VirtualizationMode.Recycling);
            ScrollViewer.SetHorizontalScrollBarVisibility(this, ScrollBarVisibility.Disabled);
            // Plain rows: no selection highlight, the folder name inside takes the clicks.
            var row = new Style(typeof(ListBoxItem));
            row.Setters.Add(new Setter(TemplateProperty, new ControlTemplate(typeof(ListBoxItem)) { VisualTree = new FrameworkElementFactory(typeof(ContentPresenter)) }));
            row.Setters.Add(new Setter(FocusableProperty, false));
            row.Setters.Add(new Setter(HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch));
            ItemContainerStyle = row;
        }

        protected override void PrepareContainerForItemOverride(DependencyObject element, object item)
        {
            base.PrepareContainerForItemOverride(element, item);
            if (element is ListBoxItem container && item is PreviewItem preview && MakeRow != null)
            {
                container.Content = MakeRow(preview.Group, preview.Index);
            }
        }
    }

    UIElement PreviewRow(Group group, int index)
    {
        var row = new Grid { Height = 28, Margin = new Thickness(0) };
        if (index % 2 == 1) row.SetResourceReference(BackgroundProperty, "Toolbar");
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(30) });
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(70) });
        row.Children.Add(Ui.Glyph("folder", 14, "Accent"));
        // The folder name is edited in place: click, type, Enter.
        var name = new TextBox { Text = group.Folder.Replace('/', '\\'), BorderThickness = new Thickness(0), Background = Brushes.Transparent, Padding = new Thickness(0), VerticalAlignment = VerticalAlignment.Center, ToolTip = L("Щёлкните, чтобы переименовать папку") };
        void Commit()
        {
            string typed = name.Text.Replace('\\', '/');
            if (_updating || typed == group.Folder) return;
            _plan.SetCustomName(typed, group);
            PlanChanged();
        }
        name.LostFocus += (_, _) => Commit();
        name.KeyDown += (_, e) => { if (e.Key == Key.Enter) { Commit(); e.Handled = true; } };
        Grid.SetColumn(name, 1);
        row.Children.Add(name);
        var count = Ui.Text(Number(group.Items.Count), "Secondary");
        count.HorizontalAlignment = HorizontalAlignment.Right;
        count.VerticalAlignment = VerticalAlignment.Center;
        count.Margin = new Thickness(0, 0, 12, 0);
        Grid.SetColumn(count, 2);
        row.Children.Add(count);
        return row;
    }

    void PlanChanged()
    {
        _plan.Rebuild();
        _plan.SaveOptions();
        Dispatcher.BeginInvoke(Refresh);
        _onChange();
    }

    void OptionChanged()
    {
        if (_updating) return;
        _plan.Scheme = (Scheme)Math.Max(0, _scheme.SelectedIndex);
        _plan.YearStyle = (YearStyle)Math.Max(0, _year.SelectedIndex);
        _plan.MonthStyle = (MonthStyle)Math.Max(0, _month.SelectedIndex);
        _plan.DayStyle = (DayStyle)Math.Max(0, _day.SelectedIndex);
        _plan.Nested = _nested.IsChecked == true;
        _plan.SeparateDuplicates = _duplicates.IsChecked == true;
        _plan.SeparateTiny = _tiny.IsChecked == true;
        _plan.DuplicatesFolderName = _duplicatesField.Text;
        _plan.TinyFolderName = _tinyField.Text;
        PlanChanged();
    }
}

/// <summary>
/// Settings, in three tabs as on the Mac: General (language, how dates are found), Recognition (what is in the pictures,
/// faces) and Nudity. Models are downloaded from Hugging Face or picked from a folder.
/// </summary>
public sealed class SettingsDialog : Window
{
    public static bool GroupsFaces => Settings.Shared.Get("groupsFaces", false);
    readonly List<ModelRow> _rows = [];
    readonly ContentControl _page = new();
    readonly StackPanel _tabs = new() { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
    readonly List<(Border Tab, UIElement Page)> _pages = [];
    readonly ContentControl _nudityModelHost = new();
    readonly TextBlock _thresholdLabel = new() { Width = 50, VerticalAlignment = VerticalAlignment.Center };

    public SettingsDialog(Window owner)
    {
        Owner = owner;
        Title = L("Настройки");
        Width = 640;
        SizeToContent = SizeToContent.Height;
        // Never taller than the screen: the tab scrolls instead.
        MaxHeight = SystemParameters.WorkArea.Height - 40;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;
        Theme.StyleTitleBar(this);
        var bar = Ui.Bar("Toolbar", new Thickness(0, 0, 0, 1));
        bar.Child = _tabs;
        bar.Padding = new Thickness(0, 6, 0, 6);
        var root = new DockPanel();
        DockPanel.SetDock(bar, Dock.Top);
        root.Children.Add(bar);
        root.Children.Add(new ScrollViewer { Content = _page, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                                             HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled });
        Content = root;
        AddTab(L("Основные"), "settings", General());
        AddTab(L("Распознавание"), "object-search", Recognition());
        AddTab(L("Нагота"), "explicit", Nudity());
        AddTab("VK", "download", Vk());
        Select(Math.Clamp(Settings.Shared.Get("settingsTab", 0), 0, _pages.Count - 1));
        // Closing stops a model download: asked first, so that it never happens unnoticed.
        Closing += (_, e) =>
        {
            if (_rows.Any(r => r.Downloading)
                && MessageBox.Show(this, L("Модель ещё загружается. Если закрыть настройки, загрузка остановится."), L("Закрыть настройки?"),
                                   MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK)
            {
                e.Cancel = true;
                return;
            }
            foreach (var row in _rows) row.Cancel();
        };
    }

    void AddTab(string title, string glyph, UIElement page)
    {
        int index = _pages.Count;
        var content = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
        content.Children.Add(Ui.Glyph(glyph, 18));
        content.Children.Add(new TextBlock { Text = title, FontSize = 11.5, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 3, 0, 0) });
        var tab = new Border { Child = content, Padding = new Thickness(14, 5, 14, 5), Margin = new Thickness(3, 0, 3, 0), CornerRadius = new CornerRadius(6), Cursor = Cursors.Hand, Background = Brushes.Transparent };
        tab.MouseLeftButtonUp += (_, _) => Select(index);
        _tabs.Children.Add(tab);
        _pages.Add((tab, page));
    }

    void Select(int index)
    {
        Settings.Shared.Set("settingsTab", index);
        for (int i = 0; i < _pages.Count; i++)
        {
            if (i == index) _pages[i].Tab.SetResourceReference(Border.BackgroundProperty, "Selection");
            else _pages[i].Tab.Background = Brushes.Transparent;
        }
        _page.Content = _pages[index].Page;
    }

    static StackPanel Pane() => new() { Margin = new Thickness(24, 18, 24, 22) };

    static TextBlock Heading(string text) => new() { Text = text, FontWeight = FontWeights.SemiBold, FontSize = 14, Margin = new Thickness(0, 6, 0, 8) };

    static TextBlock Note(string text)
    {
        var block = new TextBlock { Text = text, Margin = new Thickness(0, 4, 0, 10) };
        Ui.Styled(block, "Hint");
        return block;
    }

    static UIElement Separator()
    {
        var line = new Border { Height = 1, Margin = new Thickness(0, 8, 0, 8) };
        line.SetResourceReference(Border.BackgroundProperty, "Separator");
        return line;
    }

    static string Cache => HuggingFace.CacheDirectory;

    UIElement General()
    {
        var pane = Pane();
        pane.Children.Add(Heading(L("Язык")));
        var language = new ComboBox { HorizontalAlignment = HorizontalAlignment.Left };
        foreach (string title in new[] { L("Как в системе"), L("Русский"), "English" }) language.Items.Add(title);
        language.SelectedIndex = Settings.Shared.GetString("language") switch { "ru" => 1, "en" => 2, _ => 0 };
        var note = Note("");
        language.SelectionChanged += (_, _) =>
        {
            Settings.Shared.Set("language", language.SelectedIndex switch { 1 => "ru", 2 => "en", _ => null });
            note.Text = L("Язык сменится, когда приложение будет открыто заново.");
        };
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(new TextBlock { Text = L("Язык:"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) });
        row.Children.Add(language);
        pane.Children.Add(row);
        pane.Children.Add(note);
        pane.Children.Add(Heading(L("Сканирование")));
        pane.Children.Add(Note(L("Дата съёмки берётся из метаданных файла; если её нет — из имени файла (20220909_145141.mp4), из соседних кадров той же серии " +
                                 "(IMG_0667 → IMG_0669) или из названия папки с годом («Photos from 2018»). Дата создания файла — только в последнюю очередь.")));
        pane.Children.Add(Note(L("Миниатюры — это уменьшенные копии других фото папки, хотя бы вдвое меньше оригинала. " +
                                 "Маленькая картинка, у которой нет большой версии, миниатюрой не считается.")));
        return pane;
    }

    UIElement Recognition()
    {
        var pane = Pane();
        pane.Children.Add(Heading(L("Объекты")));
        var objects = new CheckBox { Content = L("Распознавать, что изображено на фото и видео"), IsChecked = Analyzer.AnalyzesObjects };
        objects.Click += (_, _) =>
        {
            Analyzer.AnalyzesObjects = objects.IsChecked == true;
            if (objects.IsChecked == true) _rows.FirstOrDefault(r => r.Model == Recognizer.Model)?.StartDownload();
        };
        pane.Children.Add(objects);
        pane.Children.Add(Note(L("Распознаёт модель MobileCLIP на этом компьютере (на видеокарте, если она есть). После анализа ищите через поле поиска в окне («море», «собака», " +
                                 "«документ») или по образцу — «Поиск по фото» и «Поиск по объектам» в боковой панели.")));
        pane.Children.Add(AddModel(Recognizer.Model));
        var reset = Ui.TextButton(L("Распознать заново…"), () =>
        {
            if (MessageBox.Show(this, L("Забыть сохранённые результаты распознавания и проанализировать файлы ещё раз"), L("Распознать заново…").TrimEnd('…'),
                                MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK) return;
            RecognitionStore.Shared.Clear();
        });
        reset.HorizontalAlignment = HorizontalAlignment.Left;
        reset.Padding = new Thickness(10, 3, 10, 3);
        reset.ToolTip = L("Забыть сохранённые результаты распознавания и проанализировать файлы ещё раз");
        pane.Children.Add(reset);
        pane.Children.Add(Separator());
        pane.Children.Add(Heading(L("Лица")));
        var faces = new CheckBox { Content = L("Находить лица и группировать фото по людям"), IsChecked = GroupsFaces };
        faces.Click += (_, _) =>
        {
            Settings.Shared.Set("groupsFaces", faces.IsChecked == true);
            if (faces.IsChecked == true) foreach (var model in FaceEngine.Models) _rows.FirstOrDefault(r => r.Model == model)?.StartDownload();
        };
        pane.Children.Add(faces);
        pane.Children.Add(Note(L("Лица находит модель YuNet, а отличает людей друг от друга модель ArcFace — та же, что в версии для Mac. " +
                                 "Группе можно дать имя двойным щелчком в боковой панели, а её файлы — переместить в отдельную папку. Пока только фото, без видео.")));
        foreach (var model in FaceEngine.Models) pane.Children.Add(AddModel(model));
        pane.Children.Add(Separator());
        var gpu = new CheckBox { Content = L("Считать на видеокарте"), IsChecked = FaceEngine.UseGpu };
        gpu.Click += (_, _) =>
        {
            FaceEngine.UseGpu = gpu.IsChecked == true;
            FaceEngine.Reset();
            Recognizer.Reset();
            NudityClassifier.Reset();
        };
        pane.Children.Add(gpu);
        pane.Children.Add(Note(F("Модели хранятся в общем кэше Hugging Face (%@) и работают на этом компьютере — файлы никуда не отправляются.", Cache)));
        return pane;
    }

    // --- VK -----------------------------------------------------------------------------------------------------------

    readonly TextBox _vkLink = new() { Width = 360, Height = 30 };
    readonly TextBlock _vkFolder = new() { VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 300, Margin = new Thickness(10, 0, 0, 0) };
    readonly TextBlock _vkAccount = new() { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 0, 0) };
    readonly Button _vkLogin = new(), _vkDownload = new(), _vkReveal = new();
    readonly CheckBox _vkNewest = new() { IsChecked = true, Margin = new Thickness(0, 4, 0, 10) };
    readonly ProgressBar _vkProgress = new() { Width = 200, Visibility = Visibility.Collapsed, Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock _vkStatus = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 10, 0, 0) };
    VkAlbum? _vkRunning;

    UIElement Vk()
    {
        var pane = Pane();
        pane.Children.Add(Heading(L("Скачать альбом VK")));
        pane.Children.Add(Note(L("Скачивает все фото альбома в оригинальном размере и называет их по порядку в альбоме: 001.jpg, 002.jpg… " +
                                 "Уже скачанные файлы пропускаются, так что прерванную загрузку можно продолжить.")));
        _vkLink.Text = Settings.Shared.GetString("vkLink") ?? "";
        _vkLink.TextChanged += (_, _) =>
        {
            Settings.Shared.Set("vkLink", _vkLink.Text);
            // VK lists the service albums newest first and ordinary albums in their own order.
            if (VkAlbum.ParseAlbumUrl(_vkLink.Text) != null) _vkNewest.IsChecked = VkAlbum.IsServiceAlbum(_vkLink.Text);
        };
        var choose = Ui.TextButton(L("Выбрать…"), () =>
        {
            var dialog = new Microsoft.Win32.OpenFolderDialog { Title = L("Сохранить в:") };
            if (dialog.ShowDialog(this) != true) return;
            Settings.Shared.Set("vkFolder", dialog.FolderName);
            RefreshVk();
        });
        _vkLogin.Click += (_, _) =>
        {
            if (VkAlbum.SavedToken != null)
            {
                VkLoginWindow.SignOut();
                Settings.Shared.Set("vkUserID", null);
                RefreshVk();
                return;
            }
            var login = new VkLoginWindow(this);
            login.SignedIn += userId =>
            {
                Settings.Shared.Set("vkUserID", userId);
                _vkStatus.Text = L("Вход выполнен. Вставьте ссылку на альбом и нажмите «Скачать».");
                _vkStatus.Foreground = Brushes.SeaGreen;
                RefreshVk();
            };
            login.Show();
        };
        var form = new Grid { Margin = new Thickness(0, 4, 0, 8) };
        form.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        form.ColumnDefinitions.Add(new ColumnDefinition());
        var folderRow = new StackPanel { Orientation = Orientation.Horizontal };
        folderRow.Children.Add(choose);
        folderRow.Children.Add(_vkFolder);
        var accountRow = new StackPanel { Orientation = Orientation.Horizontal };
        accountRow.Children.Add(_vkLogin);
        accountRow.Children.Add(_vkAccount);
        var rows = new (string Label, FrameworkElement Control)[] { (L("Ссылка на альбом:"), _vkLink), (L("Сохранить в:"), folderRow), (L("Аккаунт:"), accountRow) };
        for (int i = 0; i < rows.Length; i++)
        {
            form.RowDefinitions.Add(new RowDefinition { Height = new GridLength(40) });
            var label = new TextBlock { Text = rows[i].Label, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 0, 10, 0) };
            Grid.SetRow(label, i);
            rows[i].Control.HorizontalAlignment = HorizontalAlignment.Left;
            rows[i].Control.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetRow(rows[i].Control, i);
            Grid.SetColumn(rows[i].Control, 1);
            form.Children.Add(label);
            form.Children.Add(rows[i].Control);
        }
        pane.Children.Add(form);
        pane.Children.Add(Note(L("VK не даёт программам читать альбомы без входа, а доступ к фото через свои приложения разработчиков (dev.vk.com) почти никому не выдаёт. " +
                                 "Поэтому приложение открывает vk.ru в своём окне: вы входите как обычно, и загрузка идёт от вашего имени, тем же способом, каким сайт VK показывает вам ваши фото. " +
                                 "Пароль приложение не видит; доступ хранится зашифрованным для вашей учётной записи Windows и отправляется только в VK. " +
                                 "Это не официальный способ VK — если VK его изменит, загрузка перестанет работать.")));
        _vkNewest.Content = L("Нумеровать с самых новых (так VK показывает «Сохранённые фотографии»)");
        pane.Children.Add(_vkNewest);
        _vkDownload.Click += (_, _) => VkDownload();
        _vkReveal.Content = L("Показать в Проводнике");
        _vkReveal.Margin = new Thickness(8, 0, 0, 0);
        _vkReveal.Click += (_, _) =>
        {
            if (Settings.Shared.GetString("vkFolder") is { } folder && Directory.Exists(folder))
                Process.Start(new ProcessStartInfo("explorer.exe", $"\"{folder}\"") { UseShellExecute = true });
        };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        buttons.Children.Add(_vkDownload);
        buttons.Children.Add(_vkReveal);
        buttons.Children.Add(_vkProgress);
        pane.Children.Add(buttons);
        _vkStatus.SetResourceReference(TextBlock.ForegroundProperty, "Text");
        pane.Children.Add(_vkStatus);
        Closing += (_, _) => _vkRunning?.Cancel();
        RefreshVk();
        return pane;
    }

    void RefreshVk()
    {
        string? folder = Settings.Shared.GetString("vkFolder");
        _vkFolder.Text = folder ?? L("папка не выбрана");
        _vkFolder.SetResourceReference(TextBlock.ForegroundProperty, "Secondary");
        bool signedIn = VkAlbum.SavedToken != null;
        string? userId = Settings.Shared.GetString("vkUserID");
        _vkAccount.Text = signedIn ? (string.IsNullOrEmpty(userId) ? L("вход выполнен") : F("вход выполнен (id%@)", userId)) : L("вход не выполнен");
        if (signedIn) _vkAccount.Foreground = Brushes.SeaGreen; else _vkAccount.SetResourceReference(TextBlock.ForegroundProperty, "Secondary");
        _vkLogin.Content = signedIn ? L("Выйти") : L("Войти в VK…");
        _vkDownload.IsEnabled = signedIn || _vkRunning != null;
        _vkDownload.Content = _vkRunning != null ? L("Остановить") : L("Скачать");
        _vkReveal.Visibility = folder != null ? Visibility.Visible : Visibility.Collapsed;
        _vkProgress.Visibility = _vkRunning != null ? Visibility.Visible : Visibility.Collapsed;
    }

    async void VkDownload()
    {
        if (_vkRunning != null)
        {
            _vkRunning.Cancel();
            return;
        }
        if (Settings.Shared.GetString("vkFolder") is not { } folder)
        {
            _vkStatus.Text = L("Сначала выберите папку, куда сохранять.");
            return;
        }
        var album = new VkAlbum(_vkLink.Text.Trim(), VkAlbum.SavedToken ?? "", folder, _vkNewest.IsChecked == true);
        _vkRunning = album;
        _vkProgress.IsIndeterminate = true;
        _vkStatus.SetResourceReference(TextBlock.ForegroundProperty, "Text");
        _vkStatus.Text = L("Получаем список фотографий…");
        RefreshVk();
        var progress = new Progress<(int Done, int Total)>(p =>
        {
            if (_vkRunning != album) return;
            _vkProgress.IsIndeterminate = false;
            _vkProgress.Maximum = Math.Max(1, p.Total);
            _vkProgress.Value = p.Done;
            _vkStatus.Text = F("Скачивание: %lu из %lu", p.Done, p.Total);
        });
        var (success, message) = await album.Run(progress);
        _vkRunning = null;
        _vkStatus.Text = message;
        _vkStatus.Foreground = success ? Brushes.SeaGreen : Brushes.IndianRed;
        RefreshVk();
    }

    UIElement Nudity()
    {
        var pane = Pane();
        pane.Children.Add(Heading(L("Распознавание наготы")));
        var enabled = new CheckBox { Content = L("Искать откровенные фото и видео"), IsChecked = NudityClassifier.Enabled };
        enabled.Click += (_, _) =>
        {
            NudityClassifier.Enabled = enabled.IsChecked == true;
            if (enabled.IsChecked == true) (_nudityModelHost.Content as ModelRow)?.StartDownload();
        };
        pane.Children.Add(enabled);
        var model = new ComboBox { MinWidth = 380 };
        foreach (var option in NudityClassifier.Models)
        {
            model.Items.Add($"{option.Model.Title} · {Strings.Size(option.Model.ByteSize)}{(option == NudityClassifier.Models[0] ? L(" (рекомендуется)") : "")}");
        }
        model.SelectedIndex = Array.IndexOf(NudityClassifier.Models, NudityClassifier.Selected);
        model.SelectionChanged += (_, _) =>
        {
            Settings.Shared.Set("nudityModel", NudityClassifier.Models[model.SelectedIndex].Model.Repo);
            NudityClassifier.Reset();
            ShowNudityModel();
        };
        var modelRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 10, 0, 6) };
        modelRow.Children.Add(new TextBlock { Text = L("Модель:"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) });
        modelRow.Children.Add(model);
        pane.Children.Add(modelRow);
        pane.Children.Add(_nudityModelHost);
        ShowNudityModel();
        var threshold = new Slider { Minimum = 0.1, Maximum = 0.95, Width = 220, Value = NudityClassifier.Threshold, VerticalAlignment = VerticalAlignment.Center };
        threshold.ValueChanged += (_, _) =>
        {
            NudityClassifier.Threshold = threshold.Value;
            _thresholdLabel.Text = $"{threshold.Value * 100:0} %";
        };
        _thresholdLabel.Text = $"{threshold.Value * 100:0} %";
        var thresholdRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 8),
                                            ToolTip = L("Файл попадает в «Откровенные», если модель уверена не меньше чем на столько. Ниже порог — больше находок и больше ложных.") };
        thresholdRow.Children.Add(new TextBlock { Text = L("Порог:"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) });
        thresholdRow.Children.Add(threshold);
        _thresholdLabel.Margin = new Thickness(10, 0, 0, 0);
        thresholdRow.Children.Add(_thresholdLabel);
        pane.Children.Add(thresholdRow);
        pane.Children.Add(Note(F("Необязательная функция. Модели загружаются с Hugging Face в общий кэш %@ и работают на этом компьютере — файлы никуда не отправляются. " +
                                 "Модели ошибаются: пляжные, детские фото и живопись могут попасть в находки, поэтому приложение только показывает их, а что с ними делать, решаете вы.", Cache)));
        return pane;
    }

    void ShowNudityModel()
    {
        if (_nudityModelHost.Content is ModelRow old)
        {
            old.Cancel();
            _rows.Remove(old);
        }
        _nudityModelHost.Content = AddModel(NudityClassifier.Selected.Model);
    }

    ModelRow AddModel(Model model)
    {
        var row = new ModelRow(this, model);
        _rows.Add(row);
        return row;
    }

    sealed class ModelRow : StackPanel
    {
        readonly Window _owner;
        readonly TextBlock _status = Ui.Text("", "Secondary");
        readonly ProgressBar _bar = new() { Visibility = Visibility.Collapsed, Margin = new Thickness(0, 4, 0, 4) };
        readonly Button _action;
        CancellationTokenSource? _download;

        public Model Model { get; }

        public ModelRow(Window owner, Model model)
        {
            _owner = owner;
            Model = model;
            Margin = new Thickness(0, 2, 0, 10);
            var title = new TextBlock { TextWrapping = TextWrapping.Wrap };
            title.Inlines.Add(new Run(model.Title) { FontWeight = FontWeights.SemiBold });
            title.Inlines.Add(new Run($"  · {Strings.Size(model.ByteSize)} · {L("лицензия")}: {model.License}"));
            Children.Add(title);
            var summary = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 12, Margin = new Thickness(0, 2, 0, 0) };
            summary.SetResourceReference(TextBlock.ForegroundProperty, "Secondary");
            summary.Inlines.Add(new Run(model.Summary + " "));
            var link = new Hyperlink(new Run(model.Repo)) { NavigateUri = new Uri(model.Url) };
            link.RequestNavigate += (_, e) => Process.Start(new ProcessStartInfo(e.Uri.ToString()) { UseShellExecute = true });
            summary.Inlines.Add(link);
            Children.Add(summary);
            Children.Add(_bar);
            var buttons = new DockPanel { Margin = new Thickness(0, 4, 0, 0) };
            _action = Ui.TextButton("", Act);
            var folder = Ui.TextButton(L("Указать папку с моделью…"), ChooseFolder);
            folder.Margin = new Thickness(0, 0, 8, 0);
            DockPanel.SetDock(_action, Dock.Right);
            DockPanel.SetDock(folder, Dock.Right);
            buttons.Children.Add(_action);
            buttons.Children.Add(folder);
            _status.VerticalAlignment = VerticalAlignment.Center;
            buttons.Children.Add(_status);
            Children.Add(buttons);
            Refresh();
        }

        static void ResetEngines()
        {
            FaceEngine.Reset();
            Recognizer.Reset();
            NudityClassifier.Reset();
        }

        void Refresh()
        {
            if (_download != null)
            {
                _action.Content = L("Отменить");
                return;
            }
            _bar.Visibility = Visibility.Collapsed;
            if (Model.Folder is { } folder)
            {
                _status.Text = "✓ " + (Model.CustomFolder ?? L("Загружено"));
                _status.ToolTip = folder;
                _action.Content = L("Удалить модель");
            }
            else
            {
                _status.Text = L("Не загружено");
                _status.ToolTip = null;
                _action.Content = L("Загрузить");
            }
        }

        public void Cancel() => _download?.Cancel();
        public bool Downloading => _download != null;

        void Act()
        {
            if (_download != null)
            {
                _download.Cancel();
                return;
            }
            if (Model.Folder != null)
            {
                ResetEngines();
                if (Model.CustomFolder != null) Settings.Shared.Set($"modelFolder.{Model.Key}", null);
                else HuggingFace.Remove(Model.Repo);
                Refresh();
                return;
            }
            StartDownload();
        }

        public async void StartDownload()
        {
            if (_download != null || Model.Folder != null) return;
            _download = new CancellationTokenSource();
            _bar.IsIndeterminate = true;
            _bar.Visibility = Visibility.Visible;
            _status.Text = L("Загрузка…");
            Refresh();
            var progress = new Progress<(long Received, long Total)>(p =>
            {
                _bar.IsIndeterminate = false;
                _bar.Maximum = p.Total;
                _bar.Value = p.Received;
                _status.Text = $"{L("Загрузка…")} {Strings.Size(p.Received)} / {Strings.Size(p.Total)}";
            });
            string? error = null;
            try
            {
                await HuggingFace.DownloadAsync(Model, progress, _download.Token);
            }
            catch (OperationCanceledException)
            {
            }
            catch (Exception e)
            {
                error = e.Message;
            }
            _download = null;
            ResetEngines();
            Refresh();
            if (error != null) MessageBox.Show(_owner, error, L("Не удалось загрузить модель"), MessageBoxButton.OK, MessageBoxImage.Warning);
        }

        void ChooseFolder()
        {
            var dialog = new Microsoft.Win32.OpenFolderDialog { Title = L("Указать папку с моделью…") };
            if (dialog.ShowDialog(_owner) != true) return;
            if (!HuggingFace.HasFiles(dialog.FolderName, Model.Files))
            {
                MessageBox.Show(_owner, string.Join(", ", Model.Files), L("В этой папке нет нужных файлов модели"), MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            Settings.Shared.Set($"modelFolder.{Model.Key}", dialog.FolderName);
            ResetEngines();
            Refresh();
        }
    }
}
