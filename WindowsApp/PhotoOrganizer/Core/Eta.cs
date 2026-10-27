using System.Diagnostics;
using static PhotoOrganizer.Core.Strings;

namespace PhotoOrganizer.Core;

/// <summary>
/// How long a long task has left, at the speed of the last minute and a half (files looked at before go by at once and
/// would make it look much faster than it is): "осталось ≈ 1 ч 20 мин". The same on the Mac.
/// </summary>
public sealed class Eta
{
    readonly Stopwatch _clock = Stopwatch.StartNew();
    readonly Queue<(double Seconds, double Done)> _samples = new();

    /// <summary>The text for `done` of `total` (any unit: files, or files and parts of one); empty until it is known.</summary>
    public string Text(double done, double total)
    {
        double now = _clock.Elapsed.TotalSeconds;
        // A jump (the files known from before) starts the measure anew.
        if (_samples.Count > 0 && done < _samples.Last().Done) _samples.Clear();
        _samples.Enqueue((now, done));
        while (_samples.Count > 2 && now - _samples.Peek().Seconds > 90) _samples.Dequeue();
        var (since, from) = _samples.Peek();
        double span = now - since, rate = span > 0 ? (done - from) / span : 0;
        if (span < 10 || rate <= 0 || done >= total) return "";
        return F("осталось ≈ %@", Duration((total - done) / rate));
    }

    /// <summary>"1 ч 20 мин", "12 мин", "меньше минуты".</summary>
    public static string Duration(double seconds)
    {
        if (seconds < 60) return L("меньше минуты");
        long minutes = (long)Math.Round(seconds / 60);
        return minutes < 60 ? F("%@ мин", minutes) : F("%@ ч %@ мин", minutes / 60, minutes % 60);
    }
}
