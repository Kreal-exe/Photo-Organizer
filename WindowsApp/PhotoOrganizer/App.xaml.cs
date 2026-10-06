using System.Windows;
using System.Windows.Threading;
using PhotoOrganizer.Core;

namespace PhotoOrganizer;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += OnUnhandledException;
        UI.Theme.Apply(Resources);
        var window = new UI.MainWindow();
        MainWindow = window;
        window.Show();
        var folders = e.Args.Where(Directory.Exists).ToList();
        window.LoadFolders(folders.Count > 0 ? folders : UI.MainWindow.UnfinishedFolders);
    }

    /// <summary>An error the app did not expect: written to crash.log and shown, instead of the window just vanishing.</summary>
    void OnUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        try
        {
            File.AppendAllText(AppData.File("crash.log"), $"{DateTime.Now:s} {e.Exception}\n\n");
        }
        catch (IOException)
        {
        }
        MessageBox.Show(e.Exception.Message, "Photo Organizer", MessageBoxButton.OK, MessageBoxImage.Error);
        e.Handled = true;
    }
}
