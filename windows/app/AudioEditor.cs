// Audio editor (waveform, select parts to remove): comes in a later step; until then the
// "review audio" options are disabled.

using System.Globalization;

namespace MeetRec;

static class AudioEditor
{
    public static bool Available => false;

    /// null = cancelled; otherwise the parts to cut, in seconds
    public static List<(double start, double end)>? Open(string dir) => null;

    public static string Ranges(List<(double start, double end)> cuts) =>
        string.Join(",", cuts.Select(c => string.Format(CultureInfo.InvariantCulture, "{0:F2}-{1:F2}", c.start, c.end)));
}
