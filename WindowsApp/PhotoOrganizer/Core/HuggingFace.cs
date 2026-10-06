using System.Net.Http;
using System.Text.Json;

namespace PhotoOrganizer.Core;

/// <summary>One downloadable model of the built-in catalogue.</summary>
public sealed class Model(string key, string repo, string[] files, string title, string summary, string license, long byteSize)
{
    /// <summary>Also the settings key of a folder chosen by hand.</summary>
    public string Key { get; } = key;
    public string Repo { get; } = repo;
    public string[] Files { get; } = files;
    public string Title { get; } = title;
    public string Summary { get; } = summary;
    public string License { get; } = license;
    public long ByteSize { get; } = byteSize;

    public string Url => $"{HuggingFace.Endpoint}/{Repo}";

    public string? CustomFolder
    {
        get
        {
            string? folder = Settings.Shared.GetString($"modelFolder.{Key}");
            return folder != null && HuggingFace.HasFiles(folder, Files) ? folder : null;
        }
    }

    /// <summary>Where the model's files are: a folder chosen by hand, or the cached snapshot; null when not downloaded.</summary>
    public string? Folder => CustomFolder ?? HuggingFace.SnapshotFolder(Repo, Files);

    public string? File(string name) => Folder is { } folder ? Path.Combine(folder, name.Replace('/', '\\')) : null;

    public bool Ready => Folder != null;
}

/// <summary>
/// Reads and fills the standard Hugging Face hub cache (%USERPROFILE%\.cache\huggingface\hub, or wherever HF_HUB_CACHE /
/// HF_HOME point), in the layout huggingface_hub uses on Windows without symlinks, so models downloaded here are visible
/// to other tools and vice versa.
/// </summary>
public static class HuggingFace
{
    public static string Endpoint => (Environment.GetEnvironmentVariable("HF_ENDPOINT") ?? "https://huggingface.co").TrimEnd('/');

    public static string CacheDirectory =>
        Environment.GetEnvironmentVariable("HF_HUB_CACHE") is { Length: > 0 } cache ? cache
        : Environment.GetEnvironmentVariable("HF_HOME") is { Length: > 0 } home ? Path.Combine(home, "hub")
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".cache", "huggingface", "hub");

    public static string RepoDirectory(string repo) => Path.Combine(CacheDirectory, "models--" + repo.Replace("/", "--"));

    public static bool HasFiles(string folder, IEnumerable<string> files) =>
        files.All(name => System.IO.File.Exists(Path.Combine(folder, name.Replace('/', '\\'))));

    /// <summary>The cached snapshot that contains every one of `files` (the one refs/main points to first), or null.</summary>
    public static string? SnapshotFolder(string repo, string[] files)
    {
        string root = RepoDirectory(repo), snapshots = Path.Combine(root, "snapshots");
        var candidates = new List<string>();
        try { candidates.Add(System.IO.File.ReadAllText(Path.Combine(root, "refs", "main")).Trim()); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        if (!Directory.Exists(snapshots)) return null;
        candidates.AddRange(Directory.GetDirectories(snapshots).Select(Path.GetFileName).OfType<string>().Order());
        foreach (string commit in candidates)
        {
            string folder = Path.Combine(snapshots, commit);
            if (commit.Length > 0 && HasFiles(folder, files)) return folder;
        }
        return null;
    }

    public static void Remove(string repo)
    {
        try { Directory.Delete(RepoDirectory(repo), recursive: true); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    static readonly HttpClient Client = new(new SocketsHttpHandler { AutomaticDecompression = System.Net.DecompressionMethods.All })
    {
        DefaultRequestHeaders = { { "User-Agent", "PhotoOrganizer-Windows/1.0" } },
        Timeout = TimeSpan.FromMinutes(30),
    };

    /// <summary>Downloads the files of `model` into the cache; `progress(received, total)` is called as they arrive.</summary>
    public static async Task<string> DownloadAsync(Model model, IProgress<(long Received, long Total)>? progress, CancellationToken token)
    {
        string commit;
        using (var response = await Client.GetAsync($"{Endpoint}/api/models/{model.Repo}/revision/main", token))
        {
            response.EnsureSuccessStatusCode();
            using var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync(token));
            commit = json.RootElement.GetProperty("sha").GetString()!;
        }
        string root = RepoDirectory(model.Repo), folder = Path.Combine(root, "snapshots", commit);
        long received = 0, total = model.ByteSize;
        foreach (string name in model.Files)
        {
            string target = Path.Combine(folder, name.Replace('/', '\\'));
            if (System.IO.File.Exists(target))
            {
                received += new FileInfo(target).Length;
                continue;
            }
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            string partial = target + ".incomplete";
            using (var response = await Client.GetAsync($"{Endpoint}/{model.Repo}/resolve/{commit}/{name}", HttpCompletionOption.ResponseHeadersRead, token))
            {
                response.EnsureSuccessStatusCode();
                await using var input = await response.Content.ReadAsStreamAsync(token);
                await using var output = System.IO.File.Create(partial);
                var buffer = new byte[1 << 16];
                int read;
                while ((read = await input.ReadAsync(buffer, token)) > 0)
                {
                    await output.WriteAsync(buffer.AsMemory(0, read), token);
                    received += read;
                    progress?.Report((received, Math.Max(total, received)));
                }
            }
            System.IO.File.Move(partial, target, overwrite: true);
        }
        Directory.CreateDirectory(Path.Combine(root, "refs"));
        await System.IO.File.WriteAllTextAsync(Path.Combine(root, "refs", "main"), commit, token);
        return folder;
    }
}
