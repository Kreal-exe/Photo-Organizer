using System.Globalization;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

namespace PhotoOrganizer.Core;

/// <summary>
/// Interface text. As in the macOS version, the text is written in Russian in the sources; <see cref="L"/> returns its
/// English translation when Windows runs in another language. The translations are the macOS app's own
/// (Resources/en.lproj/Localizable.strings, embedded) plus the few strings that exist only on Windows.
/// </summary>
public static class Strings
{
    static readonly Dictionary<string, string> WindowsEnglish = new()
    {
        ["Показать в Проводнике"] = "Show in File Explorer",
        ["Показать папку в Проводнике"] = "Show the Folder in File Explorer",
        ["Переместить в Корзину"] = "Move to Recycle Bin",
        ["Поиск по лицу"] = "Search by Face",
        ["Перетащите сюда фото с лицом человека — найдутся все снимки, где он есть.\nИли щёлкните фото правой кнопкой → «Найти этого человека»."] = "Drop a photo of a person here to find every picture they are in.\nOr right-click a photo → “Find This Person”.",
        ["Найти этого человека"] = "Find This Person",
        ["Этот человек — самые похожие в начале"] = "This person — most alike first",
        ["На этом фото не нашлось лица."] = "No face was found in this photo.",
        ["Сначала загрузите модель лиц — «Настройки»."] = "Download the face model first — see Settings.",
        ["Лица ещё распознаются — повторите поиск, когда анализ пройдёт дальше."] = "Faces are still being recognised — search again when the analysis has got further.",
        ["Ничего похожего не нашлось."] = "Nothing alike was found.",
        ["Выбрать фото…"] = "Choose a Photo…",
        ["Модели"] = "Models",
        ["Люди и лица"] = "People and Faces",
        ["Группировать фото по людям"] = "Group photos by person",
        ["Детектор лиц"] = "Face detector",
        ["Модель лиц"] = "Face model",
        ["Загрузить"] = "Download",
        ["Удалить модель"] = "Delete Model",
        ["Загрузка…"] = "Downloading…",
        ["Загружено"] = "Downloaded",
        ["Не загружено"] = "Not downloaded",
        ["Указать папку с моделью…"] = "Use a Model Folder…",
        ["Модели скачиваются с Hugging Face один раз и дальше работают без интернета. Фото никуда не отправляются."] = "Models are downloaded from Hugging Face once and then work offline. Photos are never uploaded.",
        ["Находит лица и точки глаз и рта (YuNet, OpenCV)."] = "Finds faces with their eyes and mouth (YuNet, OpenCV).",
        ["Где хранятся"] = "Stored in",
        ["Открыть"] = "Open",
        ["Готово"] = "Done",
        ["Не удалось загрузить модель"] = "Could not download the model",
        ["В этой папке нет нужных файлов модели"] = "This folder does not contain the model's files",
        ["Ускорение: %s"] = "Acceleration: %s",
        ["Распознавание лиц"] = "Face recognition",
        ["Настройки"] = "Settings",
        ["О программе"] = "About",
        ["Выход"] = "Exit",
        ["Вид"] = "View",
        ["Правка"] = "Edit",
        ["Справка"] = "Help",
        ["Повторить"] = "Redo",
        ["Отменить"] = "Undo",
        ["Нечего отменять"] = "Nothing to undo",
        ["Выбрать всё"] = "Select All",
        ["Найти"] = "Find",
        ["Выберите папку с фото и видео"] = "Choose a folder with photos and videos",
        ["Файлы ещё не загружены из облака: дата взята из файла, на дубликаты не проверялись"] = "Not downloaded from the cloud yet: the date comes from the file, not checked for duplicates",
        ["Ничего не найдено"] = "Nothing found",
        ["Год"] = "Year",
        ["Месяц"] = "Month",
        ["День"] = "Day",
        ["Точность"] = "Precision",
        ["Только год"] = "Year only",
        ["Год и месяц"] = "Year and month",
        ["Полная дата"] = "Full date",
        ["Задать дату"] = "Set Date",
        ["Убрать дату"] = "Remove Date",
        ["Дата будет запомнена для этих файлов; сами файлы не изменяются."] = "The date is remembered for these files; the files themselves are not changed.",
        ["Выбрано: %s"] = "Selected: %s",
        ["Сохранить"] = "Save",
        ["Отмена"] = "Cancel",
        ["Фото и видео сортируются по дате съёмки и раскладываются по папкам — на этом компьютере, ничего никуда не загружая."] = "Photos and videos are sorted by the real capture date and moved into folders — on this computer, with nothing uploaded.",
        ["В Корзине: %s. Вернуть можно из Корзины."] = "In the Recycle Bin: %s. They can be restored from there.",
        ["В каждом наборе останется один файл: оригинал у точных копий и версия с наибольшим разрешением у пережатых. Освободится %s."] = "One file of every set stays: the original of exact copies and the highest-resolution version of recompressed ones. %s will be freed.",
        ["У каждой миниатюры в папке есть оригинал большего размера — он останется. Освободится %s."] = "Every thumbnail has a larger original in the folder, which stays. %s will be freed.",
        ["Видео не воспроизводится"] = "The video can't be played",
        ["Включите «Группировать фото по людям» в настройках — тогда лица этой папки будут распознаны и поиск заработает."] = "Turn on “Group photos by person” in Settings — the faces of this folder will be recognised and the search will work.",
        ["ГБ"] = "GB",
        ["МБ"] = "MB",
        ["КБ"] = "KB",
        ["Готово: %s %s."] = "Done: %s %s.",
        ["Дубликатов нет"] = "No duplicates",
        ["Имя файла"] = "File name",
        ["Поиск по имени файла и папки"] = "Search by file or folder name",
        ["Лиц на фото: %s"] = "Faces in the photo: %s",
        ["Модель лиц не загружена — «Настройки»"] = "The face model is not downloaded — see Settings",
        ["Назад к сетке"] = "Back to the Grid",
        ["Открыть «%s»"] = "Open “%s”",
        ["Папка будет создана внутри «%s»; можно указать вложенную: «Люди/Мама»."] = "The folder will be created inside “%s”; it can be nested: “People/Mum”.",
        ["Пауза / воспроизведение"] = "Pause / Play",
        ["Файл не читается"] = "The file can't be read",
        ["в облаке"] = "in the cloud",
        ["лицензия"] = "license",        ["Перетащите сюда фото с лицом человека — найдутся все снимки, где он есть.\nИли щёлкните фото правой кнопкой → «Найти этого человека»."] =
            "Drop a photo of a person here to find every picture they are in.\nOr right-click a photo → “Find This Person”.",
        ["Ускорение"] = "Acceleration",
        ["Видеокарта (DirectML)"] = "Graphics card (DirectML)",
        ["Процессор"] = "Processor",
        ["Считать на видеокарте"] = "Use the graphics card",
        ["Модель лиц собирается из весов ArcFace при первой загрузке."] = "The face model is assembled from the ArcFace weights when it is first downloaded.",
        ["Название папки"] = "Folder name",
        ["Ок"] = "OK",
        ["Имя"] = "Name",
        ["Видео"] = "Videos",
        ["Пересканировать"] = "Rescan",
        ["Ничего не найдено по запросу «%@»."] = "Nothing found for “%@”.",
        ["Поиск идёт только в выбранном разделе — выберите «Медиатека», чтобы искать везде."] = "Only the selected section is searched — choose Library to search everything.",
        ["Распознавание ещё идёт — найдётся больше, когда оно закончится."] = "Recognition is still running — more will be found when it is done.",
        ["Модель ещё загружается. Если закрыть настройки, загрузка остановится."] = "A model is still downloading. Closing Settings stops the download.",
        ["Закрыть настройки?"] = "Close Settings?",
        ["Поиск похожих копий…"] = "Looking for similar copies…",
        ["Типы"] = "Types",
        ["Добавить ещё папку — разобрать несколько папок вместе"] = "Add another folder — sort several folders together",
        ["Выберите папку с фото и видео (можно несколько)"] = "Choose a folder of photos and videos (or several)",
        ["Добавить папку к разбору"] = "Add a Folder to Sort",
        ["Показать в Проводнике"] = "Show in File Explorer",
        ["Убрать из разбора"] = "Remove from Sorting",
        ["Добавить папку…"] = "Add Folder…",
        ["%@ и ещё %@"] = "%@ + %@",
        ["папка"] = "folder",
        ["папки"] = "folders",
        ["папок"] = "folders",
        ["Щёлкните, чтобы показать папки или убрать одну из разбора"] = "Click to show the folders or remove one from sorting",
        ["Файлы из %@ будут сложены в одну папку. Выберите, куда, как группировать файлы и как назвать папки."] = "The files of %@ will be put into one folder. Choose where, how to group the files and how to name the folders.",
        ["Выберите, куда сложить файлы, как их группировать и как назвать папки."] = "Choose where to put the files, how to group them and how to name the folders.",
        ["Изменить…"] = "Change…",
        ["Куда сложить файлы"] = "Where to Put the Files",
        ["Куда сложить:"] = "Put into:",
        ["Раскладывать:"] = "Organize by:",
        ["По датам"] = "Date",
        ["По типам"] = "Type",
        ["По людям"] = "Person",
        ["По форматам"] = "Format",
        ["Внутри — по датам"] = "Date folders inside",
        ["Скриншоты — в папку:"] = "Screenshots go to:",
        ["Одна папка, даты внутри"] = "One folder, dates inside",
        ["Внутри папки каждой даты"] = "Inside the folder of each date",
        ["Записи экрана"] = "Screen Recordings",
        ["Анимации"] = "Animations",
        ["Панорамы"] = "Panoramas",
        ["Фото"] = "Photos",
        ["Без расширения"] = "No Extension",
        ["По типам: скриншоты, записи экрана, WhatsApp, Telegram, видео, анимации, панорамы, RAW, фото. По людям: фото, где узнан ровно один названный человек, — в папку с его именем, остальное по датам. По форматам: JPEG, HEIC, PNG, MOV…"] = "Type: screenshots, screen recordings, WhatsApp, Telegram, videos, animations, panoramas, RAW, photos. Person: photos in which exactly one named person was recognised go to a folder with their name, the rest by date. Format: JPEG, HEIC, PNG, MOV…",
        ["Скриншоты"] = "Screenshots",
        ["Дубликаты — в папку:"] = "Duplicates into a folder:",
        ["Не переносить дубликаты"] = "Leave duplicates where they are",
        ["Точные копии, уменьшенные и пережатые версии и миниатюры остаются где были: раскладывается только один файл каждого снимка — оригинал или лучшая версия."] = "Exact copies, smaller or recompressed versions and thumbnails stay where they are: only one file of each picture — the original or the best version — is organized.",
        ["Медиа"] = "Media",
        ["Отмечено — в медиатеке и раскладывается; без галочки — скрыто и остаётся на месте"] = "Ticked: in the library and organized; unticked: hidden and left where it is",
        ["Год из папки Google Takeout"] = "Year of the Google Takeout folder",
        ["Коллажи"] = "Collages",
        ["Открытки, мемы, рисунки, документы — то, что не фотография. Без галочки остаются на месте."] = "Postcards, memes, drawings, documents — whatever is not a photograph. Unticked, they stay where they are.",
        ["Коллажи, рамки, анимации, фильмы и правки, которые сделал Google Фото. Без галочки остаются на месте."] = "Collages, frames, animations, movies and edits made by Google Photos. Unticked, they stay where they are.",
        ["Что раскладывать:"] = "Organize:",
        ["Показать оригинал"] = "Show Original",
        ["Картинки"] = "Pictures",
        ["Разложить…"] = "Arrange…",
        ["Разложить"] = "Arrange",
        ["Сложить показанные файлы в одну папку — всё вместе или по годам, месяцам, дням"] = "Put the files shown into one folder — all together, or by year, month or day",
        ["Разложить по папке"] = "Arrange into a Folder",
        ["%@ будут перемещены в папку внутри «%@». Потом общая раскладка по датам эту папку не трогает."] = "%@ will be moved into a folder inside “%@”. Organizing by date leaves that folder alone afterwards.",
        ["Внутри папки"] = "Inside the folder",
        ["Все файлы вместе"] = "All files together",

        ["Перенесено из папки: %@."] = "Moved out of the folder: %@.",
        ["Перемещение в Корзину…"] = "Moving to the Trash…",
        ["Перемещение в Корзину: %@ из %@"] = "Moving to the Trash: %@ of %@",
        ["Проверьте год: число от 1900 до текущего."] = "Check the year: a number from 1900 to this year.",

        ["Переместить"] = "Move",
        ["Копировать"] = "Copy",
        ["Скопировать"] = "Copy",
        ["Переместить — оригиналы переезжают в новые папки. Копировать — оригиналы остаются на месте, в папках появляются их копии."] = "Move — the originals go to the new folders. Copy — the originals stay where they are and the folders get copies of them.",
        ["Будет скопировано %@ из %@ в %@."] = "%@ of %@ will be copied into %@.",
        ["Будет скопировано %@ из %@"] = "%@ of %@ will be copied",
        [" Оригиналы остаются на месте; копии ничего не перезаписывают, уже скопированные файлы пропускаются. Отменить — ⌘Z."] = " The originals stay where they are; copies never overwrite anything, files already copied are skipped. Undo with ⌘Z.",
        ["Копирование файлов…"] = "Copying files…",
        ["Копирование файлов: %@ из %@"] = "Copying files: %@ of %@",
        ["скопирован"] = "copied",
        ["скопировано"] = "copied",
        ["Не все файлы удалось скопировать"] = "Some files could not be copied",
        ["после копирования размер файла не совпал — проверьте копию вручную"] = "the size differs after copying — check the copy by hand",
        ["Копии перемещены в Корзину: %@."] = "Copies moved to the Recycle Bin: %@.",
        ["Не все копии удалось убрать"] = "Some copies could not be removed",
        ["копия изменилась или исчезла — оставлена как есть"] = "the copy changed or disappeared — left as it is",
        ["не удалось переместить в Корзину"] = "could not be moved to the Recycle Bin",
        [" Уже были скопированы раньше: %@."] = " Already copied before: %@.",
    };

    static Dictionary<string, string>? _english;

    /// <summary>Settable for the tests, which check the sources' own language.</summary>
    public static bool IsRussian { get; set; } = DetectRussian();

    [DllImport("kernel32.dll")]
    static extern ushort GetUserDefaultUILanguage();

    static bool DetectRussian()
    {
        string? forced = Environment.GetEnvironmentVariable("PHOTO_ORGANIZER_LANG");
        if (!string.IsNullOrEmpty(forced)) return forced.StartsWith("ru", StringComparison.OrdinalIgnoreCase);
        try
        {
            if (Settings.Shared.GetString("language") is { } chosen) return chosen == "ru";
        }
        catch (Exception)
        {
            // No settings yet: the system's language.
        }
        try { return (GetUserDefaultUILanguage() & 0x3FF) == 0x19; }
        catch { return CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "ru"; }
    }

    static string Unescape(string text) => Regex.Replace(text, @"\\(.)", m => m.Groups[1].Value switch
    {
        "n" => "\n",
        "t" => "\t",
        var other => other,
    });

    /// <summary>The macOS strings print with %@, %ld and %s; here every placeholder becomes {0}, {1}, … for string.Format.</summary>
    public static string ToFormat(string text)
    {
        if (!text.Contains('%')) return text;
        int index = 0;
        string escaped = text.Replace("{", "{{").Replace("}", "}}").Replace("%%", "\u0001");
        string result = Regex.Replace(escaped, @"%0?\d*(?:\.\d+)?(?:@|ld|lu|d|s|f)", _ => "{" + index++ + "}");
        return result.Replace("\u0001", "%");
    }

    static Dictionary<string, string> LoadEnglish()
    {
        var table = new Dictionary<string, string>();
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("Localizable.strings");
        if (stream != null)
        {
            using var reader = new StreamReader(stream, Encoding.UTF8);
            string text = Regex.Replace(reader.ReadToEnd(), @"/\*.*?\*/", "", RegexOptions.Singleline);
            foreach (Match m in Regex.Matches(text, @"""((?:[^""\\]|\\.)*)""\s*=\s*""((?:[^""\\]|\\.)*)""\s*;"))
            {
                table[ToFormat(Unescape(m.Groups[1].Value))] = ToFormat(Unescape(m.Groups[2].Value));
            }
        }
        foreach (var (key, value) in WindowsEnglish) table[ToFormat(key)] = ToFormat(value);
        return table;
    }

    /// <summary>The interface text in the app's language. Placeholders may be written the macOS way (%@, %ld).</summary>
    public static string L(string russian)
    {
        string key = ToFormat(russian);
        if (IsRussian) return key;
        _english ??= LoadEnglish();
        return _english.TryGetValue(key, out var english) ? english : key;
    }

    /// <summary>L() then string.Format.</summary>
    public static string F(string russian, params object[] args) => string.Format(L(russian), args);

    /// <summary>1 файл / 2 файла / 5 файлов; in English `one` for 1 and `many` otherwise. Pass each form through L().</summary>
    public static string Plural(long n, string one, string few, string many)
    {
        if (!IsRussian) return n == 1 ? one : many;
        long mod10 = n % 10, mod100 = n % 100;
        if (mod10 == 1 && mod100 != 11) return one;
        if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return few;
        return many;
    }

    /// <summary>`n` with thousands separators (a no-break space in Russian, a comma in English).</summary>
    public static string Number(long n) => n.ToString("#,0", CultureInfo.InvariantCulture).Replace(",", IsRussian ? " " : ",");

    public static string Count(long n, string one, string few, string many) => $"{Number(n)} {Plural(n, one, few, many)}";

    public static string FilesDetail(long n) => Count(n, L("файл"), L("файла"), L("файлов"));

    // --- Dates ------------------------------------------------------------------------------------------------------

    static readonly string[] RuMonths = ["январь", "февраль", "март", "апрель", "май", "июнь", "июль", "август", "сентябрь", "октябрь", "ноябрь", "декабрь"];
    static readonly string[] RuMonthsGenitive = ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"];
    static readonly string[] RuMonthsShort = ["янв.", "февр.", "мар.", "апр.", "мая", "июн.", "июл.", "авг.", "сент.", "окт.", "нояб.", "дек."];
    static readonly string[] RuWeekdays = ["воскресенье", "понедельник", "вторник", "среда", "четверг", "пятница", "суббота"];
    static readonly string[] EnMonths = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

    public static string FormatYear(DateTime date) => date.Year.ToString("0000");

    /// <summary>"май 2019 г." / "May 2019".</summary>
    public static string FormatMonth(DateTime date) =>
        IsRussian ? $"{RuMonths[date.Month - 1]} {date.Year} г." : $"{EnMonths[date.Month - 1]} {date.Year}";

    /// <summary>"12 мар. 2019 г." / "Mar 12, 2019", or the long form with the time.</summary>
    public static string FormatDay(DateTime date, bool withTime = false)
    {
        if (IsRussian)
        {
            return withTime ? $"{date.Day} {RuMonthsGenitive[date.Month - 1]} {date.Year} г., {date:HH\\:mm}"
                            : $"{date.Day} {RuMonthsShort[date.Month - 1]} {date.Year} г.";
        }
        return withTime ? $"{EnMonths[date.Month - 1]} {date.Day}, {date.Year} at {date:HH\\:mm}"
                        : $"{EnMonths[date.Month - 1][..3]} {date.Day}, {date.Year}";
    }

    /// <summary>Section title of a day: "воскресенье, 14 июля 2019 г." / "Sunday, July 14, 2019".</summary>
    public static string FormatDayLong(DateTime date) =>
        IsRussian ? $"{RuWeekdays[(int)date.DayOfWeek]}, {date.Day} {RuMonthsGenitive[date.Month - 1]} {date.Year} г."
                  : $"{date.DayOfWeek}, {EnMonths[date.Month - 1]} {date.Day}, {date.Year}";

    public static string Capitalized(string text) => text.Length == 0 ? text : char.ToUpper(text[0]) + text[1..];

    public static string Size(long bytes) => bytes >= 1_000_000_000 ? $"{bytes / 1e9:0.0} {L("ГБ")}"
        : bytes >= 1_000_000 ? $"{bytes / 1e6:0} {L("МБ")}" : $"{bytes / 1e3:0} {L("КБ")}";
}
