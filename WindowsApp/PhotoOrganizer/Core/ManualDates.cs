using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace PhotoOrganizer.Core;

/// <summary>Dates the user set by hand, remembered per file (not per path) so they survive moves on the same disk.</summary>
public static class ManualDates
{
    static string Store => AppData.File("dates.json");
    static readonly Lock Gate = new();

    static JsonObject Load()
    {
        try
        {
            return JsonNode.Parse(File.ReadAllText(Store)) as JsonObject ?? [];
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            return [];
        }
    }

    static bool Apply(PhotoItem item, JsonNode? entry)
    {
        if (entry?["t"]?.GetValue<string>() is not { } text
            || !DateTime.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.None, out var date)) return false;
        item.Date = date;
        item.ManualPrecision = (Precision)(entry["p"]?.GetValue<int>() ?? 0);
        item.DateSource = DateSource.Manual;
        return true;
    }

    public static void ApplyTo(IEnumerable<PhotoItem> items)
    {
        JsonObject dates;
        lock (Gate) dates = Load();
        if (dates.Count == 0) return;
        foreach (var item in items)
        {
            if (AppData.FileKey(item.Path) is { } key && dates.TryGetPropertyValue(key, out var entry))
            {
                try { Apply(item, entry); }
                catch (Exception e) when (e is InvalidOperationException or FormatException) { }
            }
        }
    }

    /// <summary>Gives `items` the date; null forgets the date set by hand.</summary>
    public static void SetDate(DateTime? date, Precision precision, IEnumerable<PhotoItem> items)
    {
        lock (Gate)
        {
            var dates = Load();
            foreach (var item in items)
            {
                if (AppData.FileKey(item.Path) is not { } key) continue;
                if (date is { } d)
                {
                    var entry = new JsonObject { ["t"] = d.ToString("yyyy-MM-ddTHH:mm:ss", CultureInfo.InvariantCulture), ["p"] = (int)precision };
                    dates[key] = entry;
                    Apply(item, entry);
                }
                else
                {
                    dates.Remove(key);
                    if (item.DateSource == DateSource.Manual)
                    {
                        item.Date = item.FileDate ?? item.Date;
                        item.DateSource = DateSource.File;
                    }
                }
            }
            AppData.WriteAtomically(Store, dates.ToJsonString());
        }
    }
}
