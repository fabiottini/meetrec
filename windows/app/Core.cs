// Shared pieces of the Windows app: paths, UI strings (same JSON locales as the macOS app),
// config.json, small app state, and running meet.py with the bundled Python.

using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace MeetRec;

static class Paths
{
    public static readonly string AppDir = AppContext.BaseDirectory.TrimEnd('\\');
    static readonly string Roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
    static readonly string Local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
    public static readonly string ConfDir = Path.Combine(Roaming, "MeetRec");
    public static string DefaultConfigFile => Path.Combine(ConfDir, "config.json");

    /// the settings file: MEETREC_CONFIG_FILE, else the file named by "config_file" in the default one
    /// (`meet config use <file>`, Settings > System > Use another file), else the default
    public static string ConfigFile
    {
        get
        {
            var e = Environment.GetEnvironmentVariable("MEETREC_CONFIG_FILE");
            if (!string.IsNullOrEmpty(e)) return Shell.ExpandPath(e);
            try
            {
                if (JsonNode.Parse(File.ReadAllText(DefaultConfigFile, Encoding.UTF8))?["config_file"]?.GetValue<string>() is { Length: > 0 } p)
                    return Shell.ExpandPath(p);
            }
            catch { }
            return DefaultConfigFile;
        }
    }
    public static readonly string DataDir = Path.Combine(Local, "MeetRec");           // tools and models (setup)
    public static readonly string StateDir = Path.Combine(DataDir, "state");
    public static readonly string StateFile = Path.Combine(StateDir, "current.json");
    public static readonly string AppLog = Path.Combine(StateDir, "app.log");
    public static readonly string AppState = Path.Combine(StateDir, "app.json");

    /// meet.py next to the exe (the zip), or MEETREC_SCRIPT (dev runs)
    public static string Script => Environment.GetEnvironmentVariable("MEETREC_SCRIPT") ?? Path.Combine(AppDir, "meet.py");
    /// the recorder, a separate exe next to MeetRec.exe (windows/capture)
    public static string Capture => Path.Combine(AppDir, "meetrec-capture.exe");

    /// the embedded Python in the zip; otherwise the py launcher or python on PATH
    public static string? Python()
    {
        var bundled = Path.Combine(AppDir, "python", "python.exe");
        if (File.Exists(bundled)) return bundled;
        foreach (var name in new[] { "python.exe", "py.exe" })
            foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'))
            {
                try
                {
                    var p = Path.Combine(dir.Trim(), name);
                    if (dir.Length > 0 && File.Exists(p) && !p.Contains("WindowsApps")) return p;   // skip the Store stub
                }
                catch { }
            }
        return null;
    }

    public static string? Which(string exe)
    {
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'))
        {
            try { var p = Path.Combine(dir.Trim(), exe); if (dir.Length > 0 && File.Exists(p)) return p; } catch { }
        }
        return null;
    }
}

/// UI strings: locales/<code>.json next to the exe + %APPDATA%\MeetRec\locales\<code>.json (overrides)
static class I18n
{
    static readonly Dictionary<string, Dictionary<string, string>> cache = new();
    static string[] Dirs => new[] { Path.Combine(Paths.AppDir, "locales"), Path.Combine(Paths.ConfDir, "locales") };
    public static string Lang = "en";

    static Dictionary<string, string> Read(string file)
    {
        var d = new Dictionary<string, string>();
        try
        {
            if (JsonNode.Parse(File.ReadAllText(file, Encoding.UTF8)) is JsonObject o)
                foreach (var kv in o) if (kv.Value is JsonValue v && v.TryGetValue<string>(out var s)) d[kv.Key] = s;
        }
        catch { }
        return d;
    }

    public static Dictionary<string, string> Table(string code)
    {
        if (cache.TryGetValue(code, out var t)) return t;
        t = new();
        foreach (var dir in Dirs)
            foreach (var kv in Read(Path.Combine(dir, code + ".json"))) t[kv.Key] = kv.Value;
        return cache[code] = t;
    }

    public static List<(string code, string name)> Available()
    {
        var codes = new SortedSet<string>();
        foreach (var dir in Dirs)
            if (Directory.Exists(dir))
                foreach (var f in Directory.GetFiles(dir, "*.json")) codes.Add(Path.GetFileNameWithoutExtension(f));
        return codes.Select(c => (c, Table(c).GetValueOrDefault("_language_name", c))).ToList();
    }

    public static void Reload() => cache.Clear();

    public static void Init()
    {
        var l = Config.Str("ui_language", "");
        if (l.Length > 0) { Lang = l; return; }
        var sys = System.Globalization.CultureInfo.CurrentUICulture.TwoLetterISOLanguageName;
        Lang = Available().Any(a => a.code == sys) ? sys : "en";
    }
}

static class Config
{
    public static JsonObject Load()
    {
        try { return JsonNode.Parse(File.ReadAllText(Paths.ConfigFile, Encoding.UTF8)) as JsonObject ?? new(); }
        catch { return new(); }
    }

    public static void Save(JsonObject o)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Paths.ConfigFile)!);
        var sorted = new JsonObject();
        foreach (var kv in o.OrderBy(k => k.Key, StringComparer.Ordinal)) sorted[kv.Key] = kv.Value?.DeepClone();
        var tmp = Paths.ConfigFile + ".tmp";
        File.WriteAllText(tmp, sorted.ToJsonString(new JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false));
        File.Move(tmp, Paths.ConfigFile, true);
    }

    public static string Str(string key, string def)
    {
        try { return Load()[key]?.GetValue<string>() ?? def; } catch { return def; }
    }

    public static bool Bool(string key, bool def)
    {
        try { return Load()[key]?.GetValue<bool>() ?? def; } catch { return def; }
    }
}

/// what the app remembers between runs (not settings): last note, consent shown
static class AppState
{
    public static JsonObject Load()
    {
        try { return JsonNode.Parse(File.ReadAllText(Paths.AppState, Encoding.UTF8)) as JsonObject ?? new(); }
        catch { return new(); }
    }

    public static void Set(string key, JsonNode? value)
    {
        var o = Load();
        o[key] = value;
        Directory.CreateDirectory(Paths.StateDir);
        File.WriteAllText(Paths.AppState, o.ToJsonString(), new UTF8Encoding(false));
    }
}

static class Log
{
    static readonly object gate = new();
    public static void Append(string s)
    {
        lock (gate)
        {
            try { Directory.CreateDirectory(Paths.StateDir); File.AppendAllText(Paths.AppLog, s, new UTF8Encoding(false)); } catch { }
        }
    }
}

/// meet.py runner: output lines and the result come back on the UI thread
static class Meet
{
    public static SynchronizationContext? Ui;

    static void Post(Action a)
    {
        if (Ui != null) Ui.Post(_ => a(), null); else a();
    }

    public static ProcessStartInfo StartInfo(IEnumerable<string> args)
    {
        var py = Paths.Python() ?? "python.exe";
        var psi = new ProcessStartInfo(py)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = Paths.AppDir,
        };
        psi.ArgumentList.Add(Paths.Script);
        foreach (var a in args) psi.ArgumentList.Add(a);
        psi.Environment["PYTHONUNBUFFERED"] = "1";
        psi.Environment["PYTHONUTF8"] = "1";
        if (File.Exists(Paths.Capture)) psi.Environment["MEETREC_CAPTURE"] = Paths.Capture;
        // tools downloaded by the setup come first
        psi.Environment["PATH"] = Path.Combine(Paths.DataDir, "bin") + ";" + Environment.GetEnvironmentVariable("PATH");
        return psi;
    }

    /// input: written to stdin (API keys travel this way, never in the arguments)
    public static Process? Run(IEnumerable<string> args, Action<int, string> done, Action<string>? onLine = null, string? input = null)
    {
        var list = args.ToList();
        var psi = StartInfo(list);
        var output = new StringBuilder();
        var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
        int open = 2;
        void Line(string? l)
        {
            if (l == null)
            {
                if (Interlocked.Decrement(ref open) == 0)
                {
                    // Not here: WaitForExit() waits for the output readers to finish, and this code runs
                    // inside a reader, so it would wait for itself forever (the callbacks never came).
                    Task.Run(() =>
                    {
                        p.WaitForExit();
                        var code = p.ExitCode;
                        string all; lock (output) all = output.ToString();
                        Post(() => done(code, all));
                    });
                }
                return;
            }
            lock (output) output.Append(l).Append('\n');
            Log.Append(l + "\n");
            if (onLine != null) Post(() => onLine(l));
        }
        p.OutputDataReceived += (_, e) => Line(e.Data);
        p.ErrorDataReceived += (_, e) => Line(e.Data);
        try
        {
            Log.Append($"[app] meet {string.Join(' ', list)}\n");
            p.Start();
            if (input != null) p.StandardInput.WriteLine(input);
            p.StandardInput.Close();
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            return p;
        }
        catch (Exception e)
        {
            Post(() => done(-1, $"cannot run meet.py with {psi.FileName}: {e.Message}"));
            return null;
        }
    }

    /// last line of the output: where meet.py prints JSON
    public static string LastLine(string output) =>
        output.Split('\n', StringSplitOptions.RemoveEmptyEntries).LastOrDefault()?.Trim() ?? "";

    public static JsonNode? LastJson(string output)
    {
        try { return JsonNode.Parse(LastLine(output)); } catch { return null; }
    }

    /// the folder after a marker in the output ("recording folder -> C:\...")
    public static string? DirFrom(string output, string marker)
    {
        foreach (var l in output.Split('\n').Reverse())
        {
            int i = l.IndexOf(marker, StringComparison.Ordinal);
            if (i >= 0) return l[(i + marker.Length)..].Trim();
        }
        return null;
    }

    /// synchronous, for the self test
    public static (int code, string output) RunSync(params string[] args)
    {
        var p = Process.Start(StartInfo(args))!;
        p.StandardInput.Close();
        var err = p.StandardError.ReadToEndAsync();
        var outp = p.StandardOutput.ReadToEnd();
        p.WaitForExit();
        return (p.ExitCode, outp + err.Result);
    }
}

static class Shell
{
    public static void Open(string target)
    {
        try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); }
        catch (Exception e) { Log.Append($"[app] cannot open {target}: {e.Message}\n"); }
    }

    /// the note: in Obsidian when the Markdown is in Obsidian style, otherwise with the default app
    public static void OpenNote(string path)
    {
        if (Config.Str("md_style", "plain") == "obsidian" && path.EndsWith(".md", StringComparison.OrdinalIgnoreCase))
            Open("obsidian://open?path=" + Uri.EscapeDataString(path));
        else Open(path);
    }

    static readonly string Home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    /// ~ and %VARS% / $VARS in paths from config.json (the same file works on every computer)
    public static string ExpandPath(string p)
    {
        if (string.IsNullOrEmpty(p)) return p;
        if (p == "~" || p.StartsWith("~/") || p.StartsWith("~\\")) p = Home + p[1..];
        p = Environment.ExpandEnvironmentVariables(p);
        p = System.Text.RegularExpressions.Regex.Replace(p, @"\$([A-Za-z_][A-Za-z0-9_]*)", m => Environment.GetEnvironmentVariable(m.Groups[1].Value) ?? m.Value);
        return Path.GetFullPath(p.Replace('/', '\\'));
    }

    /// paths under your home are saved as ~/…, so config.json can be copied to another computer
    public static string PortablePath(string p)
    {
        if (string.IsNullOrWhiteSpace(p)) return "";
        var full = ExpandPath(p.Trim());
        return full.StartsWith(Home + "\\", StringComparison.OrdinalIgnoreCase) ? "~/" + full[(Home.Length + 1)..].Replace('\\', '/') : full;
    }

    public static bool PidAlive(int pid)
    {
        try { using var p = Process.GetProcessById(pid); return !p.HasExited; }
        catch { return false; }
    }
}
