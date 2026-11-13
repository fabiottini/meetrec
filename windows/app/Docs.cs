// --render-docs <dir>: PNG images of the tray menu and the dialogs with demo data, for the README
// and to look at the Windows UI from CI.

using System.Drawing.Imaging;
using System.Text.Json.Nodes;
using static MeetRec.L;

namespace MeetRec;

static class Docs
{
    static readonly List<JsonObject> DemoCands = new()
    {
        new JsonObject { ["label"] = "10:00–10:45  Weekly product sync (Microsoft · work)" },
        new JsonObject { ["label"] = "10:30–11:00  Design review (Google · personal)" },
    };

    /// every dialog, built with demo data and not shown
    public static List<(string name, Func<Form> make)> Dialogs() => new()
    {
        ("which-meeting", () => Flows.EventForm(DemoCands, out _)),
        ("manual-event", () => Flows.ManualEventForm(new JsonObject
            { ["started_at"] = "2026-11-12T10:00:00+01:00", ["stopped_at"] = "2026-11-12T10:42:00+01:00" }, out _)),
        ("keep-audio", () => new Alert(T("keep_audio_title"), T("keep_audio_info", ("check", "note 4 KB, transcript 212 lines")))
            .Buttons(false, T("keep_audio"), T("delete_audio"))),
        ("consent", () => new Alert(T("consent_title"), T("consent_text_win")).Buttons(true, T("consent_ok"), T("cancel"))),
    };

    static void Save(Control c, string file)
    {
        using var b = new Bitmap(c.Width, c.Height);
        c.DrawToBitmap(b, new Rectangle(Point.Empty, c.Size));
        b.Save(file, ImageFormat.Png);
        Console.WriteLine("  " + file);
    }

    public static int Render(string dir)
    {
        Directory.CreateDirectory(dir);
        var app = new TrayApp(show: false);
        // tray icons: idle (dark and light taskbar), recording at two levels, recorder stopped, muted
        using (var strip = new Bitmap(6 * 40, 40))
        using (var g = Graphics.FromImage(strip))
        {
            g.Clear(Color.FromArgb(32, 32, 32));
            var icons = new[] { Icons.Glyph(32, null, null, dark: true), Icons.Glyph(32, null, null, muted: true, dark: true),
                                Icons.Glyph(32, Color.FromArgb(0xE5, 0x39, 0x35), -40), Icons.Glyph(32, Color.FromArgb(0xE5, 0x39, 0x35), -12),
                                Icons.Glyph(32, Color.FromArgb(0xF5, 0x8A, 0x00), null) };
            for (int i = 0; i < icons.Length; i++) g.DrawImage(icons[i], 4 + i * 40, 4);
            g.FillRectangle(Brushes.White, 200, 0, 40, 40);
            g.DrawImage(Icons.Glyph(32, null, null, dark: false), 204, 4);
            strip.Save(Path.Combine(dir, "win-tray-icons.png"), ImageFormat.Png);
        }
        foreach (var (name, recording) in new[] { ("win-menu", false), ("win-menu-recording", true) })
        {
            app.DocsRecording = recording ? DateTimeOffset.Now.AddMinutes(-12).AddSeconds(-34) : null;
            app.LastNote = @"C:\Notes\Meetings\2026-11\2026-11-12 - Weekly product sync.md";
            app.BuildMenu();
            app.Menu.Show(new Point(40, 40));
            Application.DoEvents();
            Save(app.Menu, Path.Combine(dir, name + ".png"));
            app.Menu.Close();
        }
        foreach (var (name, make) in Dialogs().Concat(Extras.DocsWindows()))
        {
            using var f = make();
            f.StartPosition = FormStartPosition.Manual;
            f.Location = new Point(20, 20);
            f.Show();
            Application.DoEvents();
            Thread.Sleep(150);
            Application.DoEvents();
            Save(f, Path.Combine(dir, "win-" + name + ".png"));
            f.Close();
        }
        app.Tray.Dispose();
        return 0;
    }
}

static partial class Extras
{
    public static List<(string name, Func<Form> make)> DocsWindows()
    {
        var l = new List<(string, Func<Form>)>();
        MoreDocs(l);
        return l;
    }
    static partial void MoreDocs(List<(string, Func<Form>)> list);
}
