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
        ["Показать папку в Проводнике"] = "Show the folder in File Explorer",
        ["Переместить в Корзину"] = "Move to Recycle Bin",
        ["Найти этого человека"] = "Find this person",
        ["Этот человек — самые похожие в начале"] = "This person — most alike first",
        ["Загрузить"] = "Download",
        ["Удалить модель"] = "Delete model",
        ["Загрузка…"] = "Downloading…",
        ["Загружено"] = "Downloaded",
        ["Не загружено"] = "Not downloaded",
        ["Указать папку с моделью…"] = "Use a model folder…",
        ["Находит лица и точки глаз и рта (YuNet, OpenCV)."] = "Finds faces with their eyes and mouth (YuNet, OpenCV).",
        ["Открыть"] = "Open",
        ["Готово"] = "Done",
        ["Не удалось загрузить модель"] = "Could not download the model",
        ["В этой папке нет нужных файлов модели"] = "This folder does not contain the model's files",
        ["Настройки"] = "Settings",
        ["Отменить"] = "Undo",
        ["Выбрать всё"] = "Select All",
        ["Найти"] = "Find",
        ["Файлы ещё не загружены из облака: дата взята из файла, на дубликаты не проверялись"] = "Not downloaded from the cloud yet: the date comes from the file, not checked for duplicates",
        ["Год"] = "Year",
        ["Месяц"] = "Month",
        ["День"] = "Day",
        ["Точность"] = "Precision",
        ["Только год"] = "Year only",
        ["Год и месяц"] = "Year and month",
        ["Полная дата"] = "Full date",
        ["Задать дату"] = "Set date",
        ["Убрать дату"] = "Remove date",
        ["Дата будет запомнена для этих файлов; сами файлы не изменяются."] = "The date is remembered for these files; the files themselves are not changed.",
        ["Выбрано: %s"] = "Selected: %s",
        ["Сохранить"] = "Save",
        ["Отмена"] = "Cancel",
        ["В Корзине: %s. Вернуть можно из Корзины."] = "In the Recycle Bin: %s. They can be restored from there.",
        ["Видео не воспроизводится"] = "The video can't be played",
        ["ГБ"] = "GB",
        ["МБ"] = "MB",
        ["КБ"] = "KB",
        ["Готово: %s %s."] = "Done: %s %s.",
        ["Дубликатов нет"] = "No duplicates",
        ["Лиц на фото: %s"] = "Faces in the photo: %s",
        ["Модель лиц не загружена — «Настройки»"] = "The face model is not downloaded — see Settings",
        ["Назад к сетке"] = "Back to the grid",
        ["Папка будет создана внутри «%s»; можно указать вложенную: «Люди/Мама»."] = "The folder will be created inside “%s”; it can be nested: “People/Mum”.",
        ["Пауза / воспроизведение"] = "Pause / Play",
        ["в облаке"] = "in the cloud",
        ["лицензия"] = "license",
        ["Видеокарта (DirectML)"] = "Graphics card (DirectML)",
        ["Процессор"] = "Processor",
        ["Считать на видеокарте"] = "Use the graphics card",
        ["Название папки"] = "Folder name",
        ["Ок"] = "OK",
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
        ["Убрать из разбора"] = "Remove from sorting",
        ["Добавить папку…"] = "Add folder…",
        ["%@ и ещё %@"] = "%@ + %@",
        ["папка"] = "folder",
        ["папки"] = "folders",
        ["папок"] = "folders",
        ["Щёлкните, чтобы показать папки или убрать одну из разбора"] = "Click to show the folders or remove one from sorting",
        ["Файлы из %@ будут сложены в одну папку. Выберите, куда, как группировать файлы и как назвать папки."] = "The files of %@ will be put into one folder. Choose where, how to group the files and how to name the folders.",
        ["Выберите, куда сложить файлы, как их группировать и как назвать папки."] = "Choose where to put the files, how to group them and how to name the folders.",
        ["Изменить…"] = "Change…",
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
        ["Удалить дубликаты"] = "Remove duplicates",
        ["Файлы:"] = "Files:",
        ["Названия папок:"] = "Folder names:",
        ["Скриншоты:"] = "Screenshots:",
        ["Дубликаты:"] = "Duplicates:",
        ["Миниатюры:"] = "Thumbnails:",
        ["В отдельную папку"] = "In a folder of their own",
        ["Неотмеченное — удалить в Корзину"] = "Move the unticked to the Recycle Bin",
        ["Без галочки неотмеченные виды остаются на месте. С ней — уходят в Корзину (при переносе; при копировании ничего не удаляется), их можно вернуть оттуда."] = "Unticked, the kinds not ticked stay where they are. Ticked, they go to the Recycle Bin (when moving; copying removes nothing), from where they can be put back.",
        ["Удалить в Корзину"] = "Move to the Recycle Bin",
        ["Иначе — в папку:"] = "Otherwise into:",
        ["Уменьшенные копии других фото уходят в Корзину, только если их большая версия остаётся."] = "Smaller copies of other photos go to the Recycle Bin, only while their larger version stays.",
        [" В Корзину: %@."] = " To the Recycle Bin: %@.",
        [" Что уже лежит в «%@», остаётся как есть; из других папок добавляется только то, чего в ней нет, а копии того, что в ней есть, идут в Корзину."] = " What is already in “%@” stays as it is; from the other folders only what it lacks is added, and copies of what it has go to the Recycle Bin.",
        ["Точные копии и уменьшенные или пережатые версии снимка при переносе уходят в Корзину (при копировании — не копируются): раскладывается только оригинал или лучшая версия. Копия удаляется, только если её оригинал остаётся."] = "Exact copies and smaller or recompressed versions of a picture go to the Recycle Bin when the files are moved (when copied, they are not copied): only the original or the best version is organized. A copy is removed only while its original stays.",
        [" Дубликаты в Корзину: %@."] = " Duplicates to the Recycle Bin: %@.",
        ["Медиа"] = "Media",
        ["Отмечено — в медиатеке и раскладывается; без галочки — скрыто и остаётся на месте"] = "Ticked: in the library and organized; unticked: hidden and left where it is",
        ["Год из названия папки"] = "Year from the folder name",
        ["Коллажи"] = "Collages",
        ["Открытки, мемы, рисунки, документы — то, что не фотография. Без галочки остаются на месте."] = "Postcards, memes, drawings, documents — whatever is not a photograph. Unticked, they stay where they are.",
        ["Коллажи, рамки, анимации, фильмы и правки, которые сделал Google Фото. Без галочки остаются на месте."] = "Collages, frames, animations, movies and edits made by Google Photos. Unticked, they stay where they are.",
        ["Что раскладывать:"] = "Organize:",
        ["Показать оригинал"] = "Show original",
        ["Картинки"] = "Pictures",
        ["Сложить показанные файлы в одну папку — всё вместе или по годам, месяцам, дням"] = "Put the files shown into one folder — all together, or by year, month or day",
        ["Разложить по папке"] = "Arrange into a folder",
        ["%@ будут перемещены в папку внутри «%@». Потом общая раскладка по датам эту папку не трогает."] = "%@ will be moved into a folder inside “%@”. Organizing by date leaves that folder alone afterwards.",
        ["Внутри папки"] = "Inside the folder",
        ["Все файлы вместе"] = "All files together",

        ["Перенесено из папки: %@."] = "Moved out of the folder: %@.",

        ["Переместить"] = "Move",
        ["Копировать"] = "Copy",
        ["Скопировать"] = "Copy",
        ["Переместить — оригиналы переезжают в новые папки. Копировать — оригиналы остаются на месте, в папках появляются их копии."] = "Move — the originals go to the new folders. Copy — the originals stay where they are and the folders get copies of them.",
        ["Будет скопировано %@ из %@"] = "%@ of %@ will be copied",
        ["Копирование файлов…"] = "Copying files…",
        ["Копирование файлов: %@ из %@"] = "Copying files: %@ of %@",
        ["скопирован"] = "copied",
        ["скопировано"] = "copied",
        ["Копии перемещены в Корзину: %@."] = "Copies moved to the Recycle Bin: %@.",
        ["не удалось переместить в Корзину"] = "could not be moved to the Recycle Bin",

        // Windows calls it the Recycle Bin, and its shortcuts use Ctrl.
        ["Перемещение в Корзину…"] = "Moving to the Recycle Bin…",
        ["Перемещение в Корзину: %@ из %@"] = "Moving to the Recycle Bin: %@ of %@",
        ["Не все файлы удалось переместить в Корзину"] = "Some files could not be moved to the Recycle Bin",
        ["Переместить %@ в Корзину?"] = "Move %@ to the Recycle Bin?",
        ["Переместить в Корзину все копии, оставив в каждом наборе оригинал или файл лучшего качества"] = "Move every copy to the Recycle Bin, keeping the original or the best-quality file of each set",
        ["Переместить в Корзину все миниатюры, у которых есть оригинал большего размера"] = "Move every thumbnail that has a larger original to the Recycle Bin",
        ["У каждой миниатюры в папке есть оригинал большего размера — он останется. Освободится %@. Файлы попадут в Корзину, откуда их можно вернуть."] =
            "Every thumbnail has a larger original in the folder, and the original stays. %@ will be freed. The files go to the Recycle Bin, from where they can be put back.",
        ["В каждом наборе останется один файл: оригинал у точных копий и версия с наибольшим разрешением (при равном — с большим размером файла) у похожих. Освободится %@. Файлы попадут в Корзину, откуда их можно вернуть."] =
            "One file stays in every set: the original of exact copies, and the version with the highest resolution (the larger file when equal) of look-alike ones. %@ will be freed. The files go to the Recycle Bin, from where they can be put back.",
        ["Готово: %@ %@. Отменить — ⌘Z"] = "Done: %@ %@. Undo with Ctrl+Z",
        [" Оригиналы остаются на месте; копии ничего не перезаписывают, уже скопированные файлы пропускаются. Отменить — ⌘Z."] = " The originals stay where they are; copies never overwrite anything, and files copied before are skipped. Undo with Ctrl+Z.",
        [" Оригиналы перемещаются, а не копируются; ничего не перезаписывается, удалённое можно вернуть из Корзины. Отменить перенос — ⌘Z."] = " The originals are moved, not copied; nothing is overwritten, and what goes to the Recycle Bin can be put back from it. Undo the move — ⌘Z.",
        [" Оригиналы перемещаются, а не копируются; ничего не удаляется и не перезаписывается. Отменить — ⌘Z."] = " The originals are moved, not copied; nothing is deleted or overwritten. Undo with Ctrl+Z.",
        ["Перетащите сюда фото предмета, места или сцены (или вставьте его — ⌘V). Приложение опишет его словами, а потом найдёт в открытой папке файлы с тем же описанием и расставит их по внешнему сходству."] =
            "Drop a photo of an object, a place or a scene here (or paste one with Ctrl+V). The app describes it in words, then finds files in the open folder with the same description and orders them by how alike they look.",

        ["Одинаковые файлы собраны по папкам, в которых они лежат. Для каждой группы выберите папку, которая останется, — копии из остальных папок будут перемещены в Корзину."] =
            "Identical files are grouped by the folders they are in. For each group choose the folder that stays — the copies in the other folders will be moved to the Recycle Bin.",
        ["В Корзину: %@, освободится %@. Вернуть можно из Корзины."] = "To the Recycle Bin: %@, %@ freed. They can be put back from the Recycle Bin.",
        ["В папке «%@» не останется ничего, кроме этих копий, — она уйдёт в Корзину целиком."] = "Nothing but these copies is in “%@” — the whole folder will go to the Recycle Bin.",

        // Only on Windows.
        ["Модель распознавания объектов не запустилась"] = "The object recognition model did not start",
        ["Распознаёт, что изображено на фото, и сравнивает фото по виду: поиск по словам, по фото и по предметам."] = "Recognises what photos show and compares how they look: search by words, by photo and by object.",
        ["Модель распознавания объектов не загружена — «Настройки»."] = "The object recognition model is not downloaded — see Settings.",
        ["Загрузка модели распознавания…"] = "Downloading the recognition model…",
        ["Щёлкните, чтобы переименовать папку"] = "Click to rename the folder",
        ["Распознаёт модель MobileCLIP на этом компьютере (на видеокарте, если она есть). После анализа ищите через поле поиска в окне («море», «собака», «документ») или по образцу — «Поиск по фото» и «Поиск по объектам» в боковой панели."] =
            "The MobileCLIP model recognises it on this computer (on the graphics card, if there is one). After the analysis, search with the search field (“sea”, “dog”, “document”) or by example — “Search by Photo” and “Search by Object” in the sidebar.",
        ["Лица находит модель YuNet, а отличает людей друг от друга модель ArcFace — та же, что в версии для Mac. Группе можно дать имя двойным щелчком в боковой панели, а её файлы — переместить в отдельную папку. Пока только фото, без видео."] =
            "The YuNet model finds faces and the ArcFace model — the same as in the Mac version — tells people apart. Double-click a group in the sidebar to name it; its files can be moved to a folder of their own. Photos only for now, no videos.",
        ["Модели хранятся в общем кэше Hugging Face (%@) и работают на этом компьютере — файлы никуда не отправляются."] =
            "The models are kept in the shared Hugging Face cache (%@) and run on this computer — no files are sent anywhere.",
        ["VK не даёт программам читать альбомы без входа, а доступ к фото через свои приложения разработчиков (dev.vk.com) почти никому не выдаёт. Поэтому приложение открывает vk.ru в своём окне: вы входите как обычно, и загрузка идёт от вашего имени, тем же способом, каким сайт VK показывает вам ваши фото. Пароль приложение не видит; доступ хранится зашифрованным для вашей учётной записи Windows и отправляется только в VK. Это не официальный способ VK — если VK его изменит, загрузка перестанет работать."] =
            "VK does not let programs read albums without signing in, and hardly ever grants photo access to developer apps (dev.vk.com). So the app opens vk.ru in a window of its own: you sign in as usual, and the download runs on your behalf, the same way the VK site shows you your photos. The app never sees the password; the access is stored encrypted for your Windows account and is sent only to VK. This is not an official VK method — if VK changes it, downloading stops working.",
        ["Необязательная функция. Модели загружаются с Hugging Face в общий кэш %@ и работают на этом компьютере — файлы никуда не отправляются. Модели ошибаются: пляжные, детские фото и живопись могут попасть в находки, поэтому приложение только показывает их, а что с ними делать, решаете вы."] =
            "An optional feature. The models are downloaded from Hugging Face into the shared cache %@ and run on this computer — no files are sent anywhere. The models make mistakes: beach photos, photos of children and paintings may be among the finds, so the app only shows them, and what to do with them is up to you.",
        ["Карта не открылась: "] = "The map did not open: ",
        ["Карта не загрузилась — нужен интернет: карта берётся с OpenStreetMap."] = "The map did not load — it needs the internet: the map comes from OpenStreetMap.",
        ["Искать этого человека по лицу"] = "Search for this person by face",
        ["Размер строк и лиц в боковой панели"] = "Size of the rows and faces in the sidebar",
        ["Показать или скрыть боковую панель"] = "Show or hide the sidebar",
        ["ответ не читается"] = "the reply can't be read",
        ["Проверьте дату: она не может быть позже сегодняшнего дня."] = "Check the date: it can't be later than today.",
        ["Альбом VK ещё скачивается. Если закрыть настройки, загрузка остановится."] = "A VK album is still downloading. Closing Settings stops the download.",
        ["Не удалось выйти: сохранённый доступ не удаляется из папки данных приложения."] = "Could not sign out: the saved access can't be removed from the app's data folder.",
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
