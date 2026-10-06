using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;
using PhotoOrganizer.Core;
using static PhotoOrganizer.Core.Strings;

namespace PhotoOrganizer.UI;

/// <summary>
/// The photos that know where they were taken, on a map (OpenStreetMap, in the WebView2 built into Windows): pins
/// gather into numbered clusters, and a click shows the photos of a pin or a cluster in the grid.
/// </summary>
public sealed class MapView : Grid
{
    readonly WebView2 _web = new();
    readonly TextBlock _empty = new() { Text = L("Ни у одного фото или видео здесь нет координат съёмки."), FontSize = 15, FontWeight = FontWeights.Medium,
                                        TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, MaxWidth = 420,
                                        HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Padding = new Thickness(16) };
    List<PhotoItem> _items = [];
    bool _ready;
    Task? _starting;

    public event Action<List<PhotoItem>>? ItemsSelected;

    public MapView()
    {
        Children.Add(_web);
        _empty.SetResourceReference(TextBlock.BackgroundProperty, "Window");
        Children.Add(_empty);
    }

    async Task Start()
    {
        // The browser's data goes next to the app's other data, not next to the program (which may not be writable).
        var environment = await CoreWebView2Environment.CreateAsync(null, Path.Combine(AppData.Directory, "WebView2"));
        await _web.EnsureCoreWebView2Async(environment);
        _web.CoreWebView2.Settings.AreDevToolsEnabled = false;
        _web.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
        _web.CoreWebView2.WebMessageReceived += (_, e) =>
        {
            var indexes = JsonSerializer.Deserialize<int[]>(e.WebMessageAsJson) ?? [];
            var chosen = indexes.Where(i => i >= 0 && i < _items.Count).Select(i => _items[i]).OrderBy(i => i.Date).ToList();
            if (chosen.Count > 0) ItemsSelected?.Invoke(chosen);
        };
        // Served from a local address rather than as a bare string: tile servers want to know which page asks.
        string folder = Path.Combine(AppData.Directory, "map");
        Directory.CreateDirectory(folder);
        File.WriteAllText(Path.Combine(folder, "index.html"), Page());
        _web.CoreWebView2.SetVirtualHostNameToFolderMapping("photo-organizer.map", folder, CoreWebView2HostResourceAccessKind.Allow);
        var loaded = new TaskCompletionSource();
        _web.CoreWebView2.NavigationCompleted += (_, _) => loaded.TrySetResult();
        _web.CoreWebView2.Navigate("https://photo-organizer.map/index.html");
        await loaded.Task;
        _ready = true;
    }

    public async void SetItems(IEnumerable<PhotoItem> items)
    {
        var located = items.Where(i => i.HasLocation).ToList();
        _empty.Visibility = located.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        if (_ready && located.SequenceEqual(_items)) return;
        _items = located;
        try
        {
            _starting ??= Start();
            await _starting;
        }
        catch (Exception e)
        {
            _empty.Text = L("Карта не открылась: ") + e.Message;
            _empty.Visibility = Visibility.Visible;
            return;
        }
        var points = new StringBuilder("[");
        for (int i = 0; i < _items.Count; i++)
        {
            if (i > 0) points.Append(',');
            points.Append(string.Format(CultureInfo.InvariantCulture, "[{0},{1},{2}]", _items[i].Latitude, _items[i].Longitude, _items[i].Video ? 1 : 0));
        }
        points.Append(']');
        await _web.ExecuteScriptAsync($"show({points});");
    }

    static string Page()
    {
        string accent = Theme.Get("Accent").ToString()[3..];   // #AARRGGBB → RRGGBB
        return $$"""
            <!doctype html>
            <html><head><meta charset="utf-8">
            <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
            <link rel="stylesheet" href="https://unpkg.com/leaflet.markercluster@1.5.3/dist/MarkerCluster.css">
            <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
            <script src="https://unpkg.com/leaflet.markercluster@1.5.3/dist/leaflet.markercluster.js"></script>
            <style>
              html, body, #map { margin: 0; height: 100%; font-family: "Segoe UI", sans-serif; }
              .pin { width: 26px; height: 26px; border-radius: 50% 50% 50% 0; transform: rotate(-45deg); background: #ff9500;
                     border: 2px solid white; box-shadow: 0 1px 4px rgba(0,0,0,.4); }
              .cluster { width: 34px; height: 34px; border-radius: 50%; background: #{{accent}}; color: white; font-weight: 600;
                         display: flex; align-items: center; justify-content: center; border: 2px solid white;
                         box-shadow: 0 1px 4px rgba(0,0,0,.4); font-size: 13px; }
            </style></head>
            <body><div id="map"></div>
            <script>
              const map = L.map('map', { zoomControl: true }).setView([30, 0], 2);
              L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          { maxZoom: 19, attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>' }).addTo(map);
              let layer = null;
              function show(points) {
                if (layer) map.removeLayer(layer);
                // Tens of thousands of photos: the markers go in at once and are clustered in chunks, so the page stays responsive.
                layer = L.markerClusterGroup({ showCoverageOnHover: false, zoomToBoundsOnClick: false, chunkedLoading: true,
                  iconCreateFunction: c => L.divIcon({ html: '<div class="cluster">' + c.getChildCount() + '</div>', className: '', iconSize: [34, 34] }) });
                const icon = L.divIcon({ html: '<div class="pin"></div>', className: '', iconSize: [26, 26], iconAnchor: [13, 26] });
                const markers = points.map((p, i) => {
                  const marker = L.marker([p[0], p[1]], { icon });
                  marker.index = i;
                  return marker;
                });
                layer.on('click', e => window.chrome.webview.postMessage([e.layer.index]));
                layer.on('clusterclick', e => window.chrome.webview.postMessage(e.layer.getAllChildMarkers().map(m => m.index)));
                layer.addLayers(markers);
                map.addLayer(layer);
                if (points.length) map.fitBounds(L.latLngBounds(points.map(p => [p[0], p[1]])), { padding: [40, 40], maxZoom: 15 });
              }
            </script></body></html>
            """;
    }
}
