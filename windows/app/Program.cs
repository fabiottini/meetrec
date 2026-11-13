// MeetRec for Windows: tray app in front of meet.py (bundled with an embedded Python in the zip).
//
//   MeetRec.exe                       the tray app (one instance)
//   MeetRec.exe <audio file>          import that file (e.g. "Open with")
//   MeetRec.exe --capture ...         the recorder (see windows/capture), started by meet.py
//   MeetRec.exe --self-test           checks for CI: Python, meet.py, recorder, locales, menus, dialogs
//   MeetRec.exe --render-docs <dir>   PNG images of the menu and dialogs, with demo data

using System.Text.Json.Nodes;
using static MeetRec.L;

namespace MeetRec;

static class Program
{
    public static readonly (string tag, string key)[] VoiceProfiles =
        { ("none", "voice_none"), ("p1", "voice_p1"), ("p2", "voice_p2"), ("p3", "voice_p3"), ("p4", "voice_p4") };

    public static string Version
    {
        get
        {
            try { return File.ReadAllText(Path.Combine(Paths.AppDir, "VERSION")).Trim(); } catch { return "dev"; }
        }
    }

    [STAThread]
    static int Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "--capture") return MeetRec.Capture.Program.Main(args[1..]);
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        I18n.Init();
        if (args.Length > 0 && args[0] == "--self-test") return SelfTest.Run();
        if (args.Length > 1 && args[0] == "--render-docs") return Docs.Render(args[1]);

        using var single = new Mutex(true, @"Local\MeetRec.TrayApp", out bool first);
        if (!first)
        {
            // already running: hand over a file to import through a small drop file, otherwise nothing to do
            if (args.Length > 0 && File.Exists(args[0]))
            {
                Directory.CreateDirectory(Paths.StateDir);
                File.WriteAllText(Path.Combine(Paths.StateDir, "import.request"), Path.GetFullPath(args[0]));
            }
            return 0;
        }
        Meet.Ui = new WindowsFormsSynchronizationContext();
        SynchronizationContext.SetSynchronizationContext(Meet.Ui);
        var app = new TrayApp();
        Extras.Attach(app);
        if (args.Length > 0 && File.Exists(args[0])) app.ImportFile(Path.GetFullPath(args[0]));
        Application.Run(app);
        return 0;
    }
}

/// hooks for the parts that come in their own files (settings, setup, levels, call watcher)
static partial class Extras
{
    public static void Attach(TrayApp app)
    {
        // import requests from a second instance ("Open with" while the app runs)
        var t = new System.Windows.Forms.Timer { Interval = 1000 };
        var req = Path.Combine(Paths.StateDir, "import.request");
        t.Tick += (_, _) =>
        {
            if (!File.Exists(req)) return;
            var f = File.ReadAllText(req).Trim();
            File.Delete(req);
            if (File.Exists(f)) app.ImportFile(f);
        };
        t.Start();
        AttachMore(app);
    }

    static partial void AttachMore(TrayApp app);
}

static class SelfTest
{
    static int fails;

    static void Check(string name, bool ok, string info = "")
    {
        Console.WriteLine((ok ? "OK   " : "FAIL ") + name + (info.Length > 0 ? $"  ({info})" : ""));
        if (!ok) fails++;
    }

    public static int Run()
    {
        // a WinExe has no console of its own: run it with the output redirected (CI does)
        Console.SetOut(new StreamWriter(Console.OpenStandardOutput()) { AutoFlush = true });
        Console.WriteLine($"MeetRec {Program.Version} self test in {Paths.AppDir}");
        var py = Paths.Python();
        Check("python found", py != null, py ?? "");
        Check("meet.py found", File.Exists(Paths.Script), Paths.Script);
        Check("recorder found", File.Exists(Paths.Capture), Paths.Capture);
        Check("locales", I18n.Table("en").Count > 100 && I18n.Table("it").Count == I18n.Table("en").Count,
              $"en {I18n.Table("en").Count}, it {I18n.Table("it").Count}");
        Check("all UI keys translated", T("start_recording") != "start_recording" && T("win_start_failed_hint") != "win_start_failed_hint");
        var (code, outp) = Meet.RunSync("--version");
        Check("meet --version", code == 0 && outp.StartsWith("MeetRec"), outp.Trim());
        (code, outp) = Meet.RunSync("accounts", "--json");
        Check("meet accounts --json", code == 0 && Meet.LastJson(outp) is JsonObject, Meet.LastLine(outp));
        (code, outp) = Meet.RunSync("mics");
        Check("meet mics (recorder --list-mics)", code == 0, outp.Trim().Replace("\n", " | "));

        Meet.Ui = null;
        var app = new TrayApp(show: false);
        app.BuildMenu();
        Check("idle menu", app.Menu.Items.Count >= 8, $"{app.Menu.Items.Count} items");
        app.DocsRecording = DateTimeOffset.Now.AddMinutes(-12);
        app.BuildMenu();
        Check("recording menu", app.Menu.Items.Cast<ToolStripItem>().Any(i => i.Text == T("stop_and_process")));
        app.Refresh();
        Check("tray icon drawn", app.Tray.Icon != null);
        foreach (var (name, make) in Docs.Dialogs())
        {
            try { using var f = make(); f.CreateControl(); Check($"dialog {name}", true); }
            catch (Exception e) { Check($"dialog {name}", false, e.Message); }
        }
        Extras.SelfTestMore(Check);
        app.Tray.Dispose();
        Console.WriteLine(fails == 0 ? "ALL OK" : $"{fails} FAILED");
        return fails == 0 ? 0 : 1;
    }
}

static partial class Extras
{
    public static void SelfTestMore(Action<string, bool, string> check) => SelfTestParts(check);
    static partial void SelfTestParts(Action<string, bool, string> check);
}
