using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Win32.SafeHandles;

namespace PhotoOrganizer.Core;

/// <summary>%APPDATA%\Photo Organizer: settings, recognition results, dates set by hand, people's names, the journal.</summary>
public static class AppData
{
    static string? _override;

    public static string Directory
    {
        get
        {
            // PHOTO_ORGANIZER_DATA moves everything elsewhere: a portable copy on a flash drive, or a test run.
            string path = _override ?? (Environment.GetEnvironmentVariable("PHOTO_ORGANIZER_DATA") is { Length: > 0 } chosen ? chosen
                : System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Photo Organizer"));
            System.IO.Directory.CreateDirectory(path);
            return path;
        }
    }

    /// <summary>For the tests: keeps them away from the real data.</summary>
    public static void SetDirectory(string path)
    {
        _override = path;
        Settings.Reset();
    }

    public static string File(string name) => System.IO.Path.Combine(Directory, name);

    /// <summary>Writes through a temporary file, so that a crash never leaves half a file.</summary>
    public static void WriteAtomically(string path, string text)
    {
        string temporary = path + ".tmp";
        System.IO.File.WriteAllText(temporary, text);
        System.IO.File.Move(temporary, path, overwrite: true);
    }

    // --- File identity ------------------------------------------------------------------------------------------

    [StructLayout(LayoutKind.Sequential)]
    struct ByHandleFileInformation
    {
        public uint FileAttributes;
        public long CreationTime, LastAccessTime, LastWriteTime;
        public uint VolumeSerialNumber, FileSizeHigh, FileSizeLow, NumberOfLinks, FileIndexHigh, FileIndexLow;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetFileInformationByHandle(SafeFileHandle file, out ByHandleFileInformation information);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFileW(string name, uint access, FileShare share, IntPtr security, FileMode disposition,
                                             uint flags, IntPtr template);

    const uint ReadAttributes = 0x80;   // FILE_READ_ATTRIBUTES

    /// <summary>
    /// Stays the same when the file is moved or renamed on its disk (volume serial and NTFS file id); changes when it is
    /// edited. The same key the Python version wrote, so its data carries over.
    /// </summary>
    public static string? FileKey(string path)
    {
        // Opened for its attributes only, not for reading: an antivirus scans every file opened for reading, and on a disk
        // of photos that made this take tens of milliseconds a file — minutes for a large folder on every analysis.
        using var handle = CreateFileW(path, ReadAttributes, FileShare.ReadWrite | FileShare.Delete, IntPtr.Zero, FileMode.Open, 0, IntPtr.Zero);
        if (handle.IsInvalid || !GetFileInformationByHandle(handle, out var info)) return null;
        ulong index = ((ulong)info.FileIndexHigh << 32) | info.FileIndexLow;
        ulong size = ((ulong)info.FileSizeHigh << 32) | info.FileSizeLow;
        return $"{info.VolumeSerialNumber}-{index}-{size}";
    }
}

/// <summary>A small JSON file of options, remembered between launches.</summary>
public sealed class Settings
{
    static Settings? _shared;
    static readonly Lock SharedLock = new();
    readonly JsonObject _values;
    readonly string _path;

    Settings()
    {
        _path = AppData.File("settings.json");
        try
        {
            _values = JsonNode.Parse(System.IO.File.ReadAllText(_path)) as JsonObject ?? [];
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            _values = [];
        }
    }

    public static Settings Shared
    {
        get
        {
            lock (SharedLock) return _shared ??= new Settings();
        }
    }

    internal static void Reset()
    {
        lock (SharedLock) _shared = null;
    }

    /// <summary>A stored object (a list, a dictionary…); null when there is none or it can't be read.</summary>
    public T? GetObject<T>(string key) where T : class
    {
        lock (_values)
        {
            try
            {
                return _values[key]?.Deserialize<T>();
            }
            catch (Exception e) when (e is JsonException or InvalidOperationException or NotSupportedException)
            {
                return null;
            }
        }
    }

    public T Get<T>(string key, T fallback)
    {
        lock (_values)
        {
            try
            {
                return _values[key] is { } node ? node.GetValue<T>() : fallback;
            }
            catch (Exception e) when (e is InvalidOperationException or FormatException)
            {
                try { return _values[key]!.Deserialize<T>() ?? fallback; }
                catch { return fallback; }
            }
        }
    }

    public string? GetString(string key) => Get<string?>(key, null);

    public List<string> GetList(string key)
    {
        lock (_values)
        {
            return _values[key] is JsonArray array ? array.Select(n => n?.GetValue<string>() ?? "").ToList() : [];
        }
    }

    public void Set(string key, object? value)
    {
        lock (_values)
        {
            _values[key] = value == null ? null : JsonSerializer.SerializeToNode(value);
            try
            {
                AppData.WriteAtomically(_path, _values.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
            }
            catch (IOException)
            {
            }
        }
    }
}
