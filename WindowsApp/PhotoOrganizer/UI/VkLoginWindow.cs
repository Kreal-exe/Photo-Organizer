using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;
using PhotoOrganizer.Core;
using static PhotoOrganizer.Core.Strings;

namespace PhotoOrganizer.UI;

/// <summary>
/// A small browser window in which the user signs in to vk.ru themselves. Once signed in, the app asks VK's web site —
/// inside that same signed-in page — for the access token the site itself uses to read the user's data, and keeps it.
/// The app never sees the password; the sign-in is remembered by this window's browser storage.
/// </summary>
public sealed class VkLoginWindow : Window
{
    /// <summary>
    /// Runs inside the signed-in vk.ru page and asks VK for the token its own web version uses — the request carries the
    /// page's cookies and origin exactly as when vk.ru does it — then hands the reply back to the app.
    /// </summary>
    const string TokenScript = """
        (async () => {
          for (const host of ['https://login.vk.ru', 'https://login.vk.com']) {
            try {
              const reply = await fetch(host + '/?act=web_token', { method: 'POST', credentials: 'include',
                headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: 'version=1&app_id=6287487' });
              const text = await reply.text();
              if (text.includes('access_token')) { window.chrome.webview.postMessage(text); return; }
            } catch (error) {}
          }
          window.chrome.webview.postMessage('');
        })();
        """;

    readonly WebView2 _web = new();
    readonly TextBlock _hint = new() { TextWrapping = TextWrapping.Wrap, FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
    bool _asking, _quietly;

    /// <summary>Called once a token has been obtained and saved, with the user id (may be empty).</summary>
    public event Action<string>? SignedIn;

    /// <summary>The browser storage of the sign-in, kept apart from the map's.</summary>
    static string BrowserData => Path.Combine(AppData.Directory, "WebView2-vk");

    public VkLoginWindow(Window owner)
    {
        Owner = owner;
        Title = L("Вход в VK");
        Width = 520;
        Height = Math.Min(680, SystemParameters.WorkArea.Height - 40);
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Theme.StyleTitleBar(this);
        _hint.Text = L("Войдите в свой аккаунт VK — логин и пароль вводятся на странице VK, приложение их не видит. Когда войдёте, окно закроется само; если нет — нажмите «Готово».");
        _hint.SetResourceReference(TextBlock.ForegroundProperty, "Secondary");
        var done = Ui.TextButton(L("Готово"), () => AskForToken(quietly: false), primary: true);
        done.Margin = new Thickness(10, 0, 0, 0);
        var bar = new DockPanel { Margin = new Thickness(14, 10, 14, 10) };
        DockPanel.SetDock(done, Dock.Right);
        bar.Children.Add(done);
        bar.Children.Add(_hint);
        var root = new DockPanel();
        DockPanel.SetDock(bar, Dock.Top);
        root.Children.Add(bar);
        root.Children.Add(_web);
        Content = root;
        Loaded += async (_, _) => await Start();
    }

    async Task Start()
    {
        try
        {
            var environment = await CoreWebView2Environment.CreateAsync(null, BrowserData);
            await _web.EnsureCoreWebView2Async(environment);
        }
        catch (Exception e)
        {
            _hint.Text = e.Message;
            return;
        }
        _web.CoreWebView2.NavigationCompleted += (_, _) =>
        {
            if (LooksSignedIn(_web.Source)) AskForToken(quietly: true);
        };
        _web.CoreWebView2.WebMessageReceived += (_, e) => TokenArrived(e.TryGetWebMessageAsString());
        _web.CoreWebView2.Navigate("https://vk.ru/");
    }

    /// <summary>Pages a signed-out visitor sees; anywhere else on vk.ru means the user is in.</summary>
    static bool LooksSignedIn(Uri? url)
    {
        if (url == null || !(url.Host.EndsWith("vk.ru") || url.Host.EndsWith("vk.com"))) return false;
        if (url.Host.StartsWith("id.") || url.Host.StartsWith("login.") || url.Host.StartsWith("oauth.")) return false;
        string path = url.AbsolutePath;
        return path.Length > 1 && !path.StartsWith("/login") && !path.StartsWith("/join") && !path.StartsWith("/challenge");
    }

    async void AskForToken(bool quietly)
    {
        if (_asking || _web.CoreWebView2 == null) return;
        _asking = true;
        _quietly = quietly;
        await _web.CoreWebView2.ExecuteScriptAsync(TokenScript);
    }

    /// <summary>Finds "access_token" (and "user_id") anywhere in a JSON reply.</summary>
    static void Find(JsonElement element, ref string? token, ref string userId)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            foreach (var property in element.EnumerateObject())
            {
                if (property.Name == "access_token" && property.Value.ValueKind == JsonValueKind.String) token = property.Value.GetString();
                else if (property.Name == "user_id") userId = property.Value.ToString();
                Find(property.Value, ref token, ref userId);
            }
        }
        else if (element.ValueKind == JsonValueKind.Array)
        {
            foreach (var value in element.EnumerateArray()) Find(value, ref token, ref userId);
        }
    }

    void TokenArrived(string reply)
    {
        _asking = false;
        string? token = null;
        string userId = "";
        try
        {
            if (reply.Length > 0)
            {
                using var json = JsonDocument.Parse(reply);
                Find(json.RootElement, ref token, ref userId);
            }
        }
        catch (JsonException)
        {
        }
        if (string.IsNullOrEmpty(token))
        {
            if (!_quietly)
            {
                _hint.Text = L("Не получилось получить доступ. Убедитесь, что вы вошли (видна ваша лента или страница), и нажмите «Готово» ещё раз.");
                _hint.Foreground = System.Windows.Media.Brushes.IndianRed;
            }
            return;
        }
        VkAlbum.SavedToken = token;
        Close();
        SignedIn?.Invoke(userId);
    }

    /// <summary>Forgets the sign-in: the saved token and this window's cookies.</summary>
    public static void SignOut()
    {
        VkAlbum.SavedToken = null;
        try { Directory.Delete(BrowserData, recursive: true); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}
