using System.Globalization;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using static PhotoOrganizer.Core.Strings;

namespace PhotoOrganizer.Core;

/// <summary>
/// Downloads a VK photo album in original size through the VK API (photos.get) with the user's own access token (see
/// VkLoginWindow). Files are named by their position in the album: 001.jpg, 002.jpg, … Existing files are never
/// overwritten, so an interrupted download can be resumed.
/// </summary>
public sealed partial class VkAlbum(string link, string accessToken, string folder, bool newestFirst)
{
    const string ApiVersion = "5.199";
    const int PageSize = 1000;   // the API's maximum per request

    static readonly HttpClient Client = new() { Timeout = TimeSpan.FromMinutes(5) };
    readonly CancellationTokenSource _cancel = new();

    public void Cancel() => _cancel.Cancel();

    // --- The token ----------------------------------------------------------------------------------------------

    /// <summary>The token is kept encrypted for this Windows user (DPAPI), in the app's data folder.</summary>
    static string TokenPath => AppData.File("vk-token");

    public static string? SavedToken
    {
        get
        {
            try
            {
                byte[] data = ProtectedData.Unprotect(File.ReadAllBytes(TokenPath), null, DataProtectionScope.CurrentUser);
                string token = Encoding.UTF8.GetString(data).Trim();
                return token.Length > 0 ? token : null;
            }
            catch (Exception e) when (e is IOException or CryptographicException or UnauthorizedAccessException)
            {
                return null;
            }
        }
        set
        {
            try
            {
                if (string.IsNullOrWhiteSpace(value)) File.Delete(TokenPath);
                else File.WriteAllBytes(TokenPath, ProtectedData.Protect(Encoding.UTF8.GetBytes(value.Trim()), null, DataProtectionScope.CurrentUser));
            }
            catch (Exception e) when (e is IOException or CryptographicException or UnauthorizedAccessException)
            {
            }
        }
    }

    // --- Links, sizes, names ------------------------------------------------------------------------------------

    [GeneratedRegex(@"album(-?\d+)_(\d+)")]
    private static partial Regex AlbumPattern();

    /// <summary>
    /// vk.ru / vk.com / m.vk.com links like ".../album123456_000". `album` is what the API wants: "saved", "wall",
    /// "profile" for the service albums (ids 000, 00, 0) or the album's number.
    /// </summary>
    public static (string Owner, string Album)? ParseAlbumUrl(string link)
    {
        var match = AlbumPattern().Match(link);
        if (!match.Success) return null;
        string number = match.Groups[2].Value;
        string album = number switch { "0" => "profile", "00" => "wall", "000" => "saved", _ => number };
        return (match.Groups[1].Value, album);
    }

    /// <summary>The service albums are listed newest first by VK, ordinary albums in their own order.</summary>
    public static bool IsServiceAlbum(string link) => ParseAlbumUrl(link) is { } parsed && parsed.Album is "saved" or "wall" or "profile";

    /// <summary>The largest version of a photo as returned by photos.get with photo_sizes=1.</summary>
    public static string? OriginalUrl(JsonElement photo)
    {
        if (photo.TryGetProperty("orig_photo", out var original) && original.ValueKind == JsonValueKind.Object
            && original.TryGetProperty("url", out var url) && url.ValueKind == JsonValueKind.String) return url.GetString();
        // Otherwise the largest of the listed sizes. Old photos come without dimensions; for those the size type tells
        // the order (w is the largest, s the smallest).
        const string typeOrder = "smxopqryzw";
        string? best = null;
        long bestArea = -1;
        int bestRank = -1;
        if (!photo.TryGetProperty("sizes", out var sizes) || sizes.ValueKind != JsonValueKind.Array) return null;
        foreach (var size in sizes.EnumerateArray())
        {
            if (!size.TryGetProperty("url", out var sizeUrl) || sizeUrl.ValueKind != JsonValueKind.String) continue;
            long width = size.TryGetProperty("width", out var w) && w.ValueKind == JsonValueKind.Number ? w.GetInt64() : 0;
            long height = size.TryGetProperty("height", out var h) && h.ValueKind == JsonValueKind.Number ? h.GetInt64() : 0;
            string type = size.TryGetProperty("type", out var t) && t.ValueKind == JsonValueKind.String ? t.GetString()! : "";
            int rank = type.Length > 0 ? typeOrder.IndexOf(type, StringComparison.Ordinal) : -1;
            if (width * height > bestArea || (width * height == bestArea && rank > bestRank))
            {
                (best, bestArea, bestRank) = (sizeUrl.GetString(), width * height, rank);
            }
        }
        return best;
    }

    /// <summary>"0007.png": `index` starts at 1; at least three digits, more when the album needs them.</summary>
    public static string FileName(int index, int count, string url)
    {
        int digits = Math.Max(3, count.ToString(CultureInfo.InvariantCulture).Length);
        string extension = Path.GetExtension(new Uri(url).AbsolutePath).TrimStart('.').ToLowerInvariant();
        if (extension.Length is 0 or > 5) extension = "jpg";
        return index.ToString(new string('0', digits), CultureInfo.InvariantCulture) + "." + extension;
    }

    // --- Downloading --------------------------------------------------------------------------------------------

    sealed class VkException(string message) : Exception(message);

    /// <summary>One page of photos.get.</summary>
    async Task<JsonElement> Page(int offset, string owner, string album, CancellationToken token)
    {
        string query = string.Join("&", new Dictionary<string, string>
        {
            ["owner_id"] = owner, ["album_id"] = album, ["rev"] = newestFirst ? "1" : "0", ["photo_sizes"] = "1",
            ["count"] = PageSize.ToString(CultureInfo.InvariantCulture), ["offset"] = offset.ToString(CultureInfo.InvariantCulture),
            ["access_token"] = accessToken, ["v"] = ApiVersion,
        }.Select(p => $"{p.Key}={Uri.EscapeDataString(p.Value)}"));
        string text;
        try
        {
            text = await Client.GetStringAsync("https://api.vk.ru/method/photos.get?" + query, token);
        }
        catch (HttpRequestException e)
        {
            throw new VkException(F("VK не ответил: %@", e.Message));
        }
        using var reply = JsonDocument.Parse(text);
        if (reply.RootElement.TryGetProperty("error", out var failure))
        {
            int code = failure.TryGetProperty("error_code", out var c) ? c.GetInt32() : 0;
            string message = failure.TryGetProperty("error_msg", out var m) ? m.GetString() ?? "" : "";
            throw new VkException(code switch
            {
                5 or 15 or 1116 => F("VK не пустил к альбому (ошибка %ld: %@). Скорее всего, вход устарел — нажмите «Выйти», затем «Войти в VK…» и попробуйте снова.", code, message),
                14 => L("VK требует ввести капчу. Откройте vk.ru в браузере, пройдите проверку и попробуйте позже."),
                _ => F("VK вернул ошибку %ld: %@", code, message),
            });
        }
        return reply.RootElement.TryGetProperty("response", out var response) ? response.Clone() : default;
    }

    /// <summary>Lists the album, then downloads it four files at a time. Returns (success, a message for the user).</summary>
    public async Task<(bool Success, string Message)> Run(IProgress<(int Done, int Total)> progress)
    {
        var cancel = _cancel.Token;
        if (ParseAlbumUrl(link) is not { } parsed) return (false, L("Это не ссылка на альбом. Нужна ссылка вида https://vk.ru/album123_456."));
        if (string.IsNullOrWhiteSpace(accessToken)) return (false, L("Сначала войдите в VK."));
        try
        {
            Directory.CreateDirectory(folder);
            // The whole list first: the numbering has to be known before the first file is named.
            var photos = new List<string?>();
            int total = int.MaxValue;
            while (photos.Count < total && !cancel.IsCancellationRequested)
            {
                var page = await Page(photos.Count, parsed.Owner, parsed.Album, cancel);
                total = page.ValueKind == JsonValueKind.Object && page.TryGetProperty("count", out var count) ? count.GetInt32() : 0;
                var items = page.ValueKind == JsonValueKind.Object && page.TryGetProperty("items", out var list) ? list.EnumerateArray().ToList() : [];
                if (items.Count == 0) break;
                photos.AddRange(items.Select(OriginalUrl));
                await Task.Delay(350, cancel);   // the API allows three requests a second
            }
            if (photos.Count == 0) return (true, L("В альбоме нет фотографий."));
            int done = 0, saved = 0, skipped = 0, failed = 0;
            using var slots = new SemaphoreSlim(4);
            var tasks = photos.Select(async (url, index) =>
            {
                await slots.WaitAsync(cancel);
                try
                {
                    string? file = url == null ? null : Path.Combine(folder, FileName(index + 1, photos.Count, url));
                    if (file == null) Interlocked.Increment(ref failed);
                    else if (File.Exists(file)) Interlocked.Increment(ref skipped);   // already there from an earlier run
                    else if (await Download(url!, file, cancel)) Interlocked.Increment(ref saved);
                    else Interlocked.Increment(ref failed);
                }
                finally
                {
                    slots.Release();
                    progress.Report((Interlocked.Increment(ref done), photos.Count));
                }
            }).ToList();
            try
            {
                await Task.WhenAll(tasks);
            }
            catch (OperationCanceledException)
            {
            }
            var parts = new List<string> { F("Скачано: %@", Number(saved)) };
            if (skipped > 0) parts.Add(F("уже были: %@", Number(skipped)));
            if (failed > 0) parts.Add(F("не удалось: %@", Number(failed)));
            if (cancel.IsCancellationRequested) parts.Add(L("остановлено — нажмите «Скачать» ещё раз, чтобы продолжить"));
            return (failed == 0 && !cancel.IsCancellationRequested, string.Join(", ", parts) + ".");
        }
        catch (OperationCanceledException)
        {
            return (false, L("Загрузка отменена."));
        }
        catch (Exception e) when (e is VkException or IOException or UnauthorizedAccessException or JsonException)
        {
            return (false, e.Message);
        }
    }

    /// <summary>
    /// Written under a temporary name first, so a half-written file is never mistaken for a finished one, then renamed
    /// without replacing anything already there.
    /// </summary>
    static async Task<bool> Download(string url, string file, CancellationToken cancel)
    {
        string partial = Path.Combine(Path.GetDirectoryName(file)!, "." + Path.GetFileName(file) + ".part");
        try
        {
            using (var response = await Client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, cancel))
            {
                if (!response.IsSuccessStatusCode) return false;
                await using var output = File.Create(partial);
                await response.Content.CopyToAsync(output, cancel);
            }
            if (new FileInfo(partial).Length == 0) return false;
            File.Move(partial, file, overwrite: false);
            return true;
        }
        catch (Exception e) when (e is HttpRequestException or IOException or UnauthorizedAccessException or TaskCanceledException)
        {
            try { File.Delete(partial); } catch (IOException) { }
            if (e is TaskCanceledException && cancel.IsCancellationRequested) throw new OperationCanceledException(cancel);
            return false;
        }
    }
}
