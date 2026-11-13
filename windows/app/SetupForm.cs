// First-run setup for Windows: checks what MeetRec needs and downloads what is missing
// (ffmpeg, whisper.cpp, the models) into %LOCALAPPDATA%\MeetRec, plus vault and calendar accounts.
// Opens by itself when something required is missing, and from the menu ("Setup…").

using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Microsoft.Win32;
using static MeetRec.L;

namespace MeetRec;

sealed class SetupForm : Form
{
    public record CheckItem(string Id, string Title, string Detail, bool Ok, bool Required, string? Action);

    static readonly (string file, string url)[] Models =
    {
        ("ggml-large-v3-turbo.bin", "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"),
        ("ggml-silero-v6.2.0.bin", "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin"),
    };
    const string FfmpegUrl = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip";
    static string Bin => Path.Combine(Paths.DataDir, "bin");
    static string ModelDir => Path.Combine(Paths.DataDir, "models");

    readonly TableLayoutPanel checksTable = new() { ColumnCount = 3, AutoSize = true, Dock = DockStyle.Top };
    readonly FlowLayoutPanel accountsPanel = new() { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false, Dock = DockStyle.Top };
    readonly Label loginMessage = new() { AutoSize = true, MaximumSize = new Size(560, 0) };
    readonly TextBox loginUrl = new() { ReadOnly = true, Width = 440, Visible = false };
    readonly Button copyUrl = new() { AutoSize = true, Visible = false };
    readonly Button cancelLogin = new() { AutoSize = true, Visible = false };
    readonly ProgressBar progress = new() { Width = 220, Visible = false };
    readonly Label busyLabel = new() { AutoSize = true };
    readonly TextBox log = new() { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Height = 110, Dock = DockStyle.Fill, Font = new Font(FontFamily.GenericMonospace, 8.5f) };
    readonly Label status = new() { AutoSize = true, Margin = new Padding(0, 8, 10, 0) };
    readonly List<Button> actionButtons = new();
    List<JsonObject> accounts = new();
    bool googleClient, msClient;
    System.Diagnostics.Process? loginProc;
    bool loginCancelled;
    string? busy;
    public List<CheckItem> Checks = new();

    public SetupForm(bool load = true)
    {
        Text = "MeetRec – Setup";
        Icon = Icons.App;
        Font = SystemFonts.MessageBoxFont;
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        ClientSize = new Size(680, 760);
        var root = new TableLayoutPanel { ColumnCount = 1, Dock = DockStyle.Fill, Padding = new Padding(16, 12, 16, 12) };
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 120));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        var head = new FlowLayoutPanel { AutoSize = true, WrapContents = false };
        head.Controls.Add(new PictureBox { Image = Icons.Glyph(44, Color.FromArgb(0xE5, 0x39, 0x35), null), Size = new Size(48, 48), SizeMode = PictureBoxSizeMode.CenterImage });
        var titles = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true };
        titles.Controls.Add(new Label { Text = T("setup_title"), AutoSize = true, Font = new Font(Font.FontFamily, Font.Size + 4, FontStyle.Bold) });
        titles.Controls.Add(new Label { Text = T("setup_subtitle"), AutoSize = true, ForeColor = SystemColors.GrayText, MaximumSize = new Size(560, 0) });
        head.Controls.Add(titles);
        root.Controls.Add(head);

        checksTable.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 28));
        checksTable.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        checksTable.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var scroll = new Panel { Dock = DockStyle.Fill, AutoScroll = true, BorderStyle = BorderStyle.FixedSingle, Margin = new Padding(0, 8, 0, 8) };
        scroll.Controls.Add(checksTable);
        root.Controls.Add(scroll);

        var cal = new GroupBox { Text = T("cal_title"), AutoSize = true, Dock = DockStyle.Fill, Padding = new Padding(8) };
        var calBody = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false, Dock = DockStyle.Fill };
        calBody.Controls.Add(accountsPanel);
        var addRow = new FlowLayoutPanel { AutoSize = true, WrapContents = false };
        var addMs = new Button { Text = T("cal_add_ms"), AutoSize = true };
        var addG = new Button { Text = T("cal_add_google"), AutoSize = true };
        addMs.Click += (_, _) => AddMicrosoft();
        addG.Click += (_, _) => AddGoogle();
        actionButtons.Add(addMs); actionButtons.Add(addG);
        addRow.Controls.Add(addMs); addRow.Controls.Add(addG);
        calBody.Controls.Add(addRow);
        var loginRow = new FlowLayoutPanel { AutoSize = true, WrapContents = false };
        cancelLogin.Text = T("cancel");
        cancelLogin.Click += (_, _) => CancelLogin();
        loginRow.Controls.Add(loginMessage); loginRow.Controls.Add(cancelLogin);
        calBody.Controls.Add(loginRow);
        var urlRow = new FlowLayoutPanel { AutoSize = true, WrapContents = false };
        copyUrl.Text = T("cal_copy_link");
        copyUrl.Click += (_, _) => { if (loginUrl.Text.Length > 0) Clipboard.SetText(loginUrl.Text); };
        urlRow.Controls.Add(loginUrl); urlRow.Controls.Add(copyUrl);
        calBody.Controls.Add(urlRow);
        cal.Controls.Add(calBody);
        root.Controls.Add(cal);

        var busyRow = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(0, 6, 0, 4) };
        busyRow.Controls.Add(progress); busyRow.Controls.Add(busyLabel);
        root.Controls.Add(busyRow);
        root.Controls.Add(log);

        var bottom = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, AutoSize = true, Dock = DockStyle.Fill, Margin = new Padding(0, 8, 0, 0) };
        var close = new Button { Text = T("setup_close"), AutoSize = true, MinimumSize = new Size(90, 0) };
        close.Click += (_, _) => Close();
        var recheck = new Button { Text = T("setup_recheck"), AutoSize = true };
        recheck.Click += (_, _) => Refresh_();
        actionButtons.Add(recheck);
        bottom.Controls.Add(close); bottom.Controls.Add(status); bottom.Controls.Add(recheck);
        AcceptButton = close;
        root.Controls.Add(bottom);
        Controls.Add(root);
        FormClosed += (_, _) => CancelLogin();
        BuildChecks();
        if (load) Refresh_();
    }

    public bool RequiredMissing => Checks.Any(c => c.Required && !c.Ok);

    // ---------------------------------------------------------------- checks

    static string? Tool(string exe) =>
        File.Exists(Path.Combine(Bin, exe)) ? Path.Combine(Bin, exe) : Paths.Which(exe);

    static string? ModelPath(string file)
    {
        var p = Path.Combine(ModelDir, file);
        return File.Exists(p) ? p : null;
    }

    /// the "let desktop apps access your microphone" switches (user and device)
    public static bool MicAllowed()
    {
        const string k = @"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";
        foreach (var (hive, sub) in new[] { (Registry.CurrentUser, k), (Registry.CurrentUser, k + @"\NonPackaged"), (Registry.LocalMachine, k) })
        {
            try
            {
                using var key = hive.OpenSubKey(sub);
                if (key?.GetValue("Value") as string == "Deny") return false;
            }
            catch { }
        }
        return true;
    }

    static string? Claude()
    {
        var local = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "bin", "claude.exe");
        return Paths.Which("claude.exe") ?? Paths.Which("claude.cmd") ?? (File.Exists(local) ? local : null);
    }

    static bool CliOnPath()
    {
        using var k = Registry.CurrentUser.OpenSubKey("Environment");
        var p = k?.GetValue("Path", "", RegistryValueOptions.DoNotExpandEnvironmentNames) as string ?? "";
        return p.Split(';').Any(d => string.Equals(d.Trim().TrimEnd('\\'), Paths.AppDir, StringComparison.OrdinalIgnoreCase));
    }

    public List<CheckItem> ComputeChecks()
    {
        var vault = Config.Str("vault", "");
        var py = Paths.Python();
        var ff = Tool("ffmpeg.exe");
        var wh = Tool("whisper-cli.exe");
        var model = ModelPath(Models[0].file);
        bool models = model != null && ModelPath(Models[1].file) != null;
        bool mic = MicAllowed();
        var claude = Claude();
        bool cli = CliOnPath();
        return new()
        {
            new("python", "Python 3", py ?? T("setup_win_python_missing"), py != null, true, null),
            new("ffmpeg", "ffmpeg", ff ?? T("setup_win_ffmpeg_detail"), ff != null, true, ff == null ? T("setup_download") : null),
            new("whisper", "whisper.cpp", wh ?? T("setup_win_whisper_detail"), wh != null, true, wh == null ? T("setup_download") : null),
            new("model", T("setup_model"), models ? model! : T("setup_model_missing"), models, true, models ? null : T("setup_download")),
            new("mic", T("setup_mic_permission"), mic ? "OK" : T("setup_win_mic_blocked"), mic, true, mic ? null : T("setup_allow")),
            new("vault", T("setup_vault"), vault.Length == 0 ? T("setup_vault_missing") : vault, vault.Length > 0 && Directory.Exists(vault), true, T("setup_choose")),
            new("calendars", T("cal_title"), accounts.Count == 0 ? T("cal_none") : T("cal_count", ("n", accounts.Count.ToString())),
                accounts.Count > 0 && accounts.All(a => a["ok"]?.GetValue<bool>() == true), false, null),
            new("claude", T("setup_claude"), claude ?? T("setup_claude_detail"), claude != null, false, null),
            new("cli", T("setup_win_cli"), cli ? Paths.AppDir : T("setup_win_cli_detail"), cli, false, cli ? null : T("setup_install")),
        };
    }

    void BuildChecks()
    {
        Checks = ComputeChecks();
        checksTable.SuspendLayout();
        checksTable.Controls.Clear();
        checksTable.RowStyles.Clear();
        actionButtons.RemoveAll(b => b.Tag is string);
        foreach (var c in Checks)
        {
            var mark = new Label
            {
                Text = c.Ok ? "✔" : c.Required ? "✖" : "–", AutoSize = true, Margin = new Padding(6, 6, 0, 0),
                ForeColor = c.Ok ? Color.FromArgb(0x2E, 0x7D, 0x32) : c.Required ? Color.FromArgb(0xC6, 0x28, 0x28) : SystemColors.GrayText,
                Font = new Font(Font.FontFamily, Font.Size + 1, FontStyle.Bold),
            };
            var text = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false, Margin = new Padding(0, 4, 0, 4) };
            text.Controls.Add(new Label { Text = c.Title + (c.Required ? "" : "  · " + T("setup_optional")), AutoSize = true });
            text.Controls.Add(new Label { Text = c.Detail, AutoSize = true, ForeColor = SystemColors.GrayText, MaximumSize = new Size(470, 0), AutoEllipsis = true });
            checksTable.Controls.Add(mark);
            checksTable.Controls.Add(text);
            if (c.Action != null)
            {
                var b = new Button { Text = c.Action, AutoSize = true, Tag = c.Id, Enabled = busy == null, Margin = new Padding(4, 6, 6, 4) };
                b.Click += (_, _) => Run(c.Id);
                actionButtons.Add(b);
                checksTable.Controls.Add(b);
            }
            else checksTable.Controls.Add(new Label { AutoSize = true });
        }
        checksTable.ResumeLayout();
        status.Text = RequiredMissing ? T("setup_missing") : T("setup_ready");
        status.ForeColor = RequiredMissing ? Color.FromArgb(0xE6, 0x51, 0x00) : Color.FromArgb(0x2E, 0x7D, 0x32);
        BuildAccounts();
    }

    void BuildAccounts()
    {
        accountsPanel.Controls.Clear();
        if (accounts.Count == 0)
            accountsPanel.Controls.Add(new Label { Text = T("cal_none_detail"), AutoSize = true, ForeColor = SystemColors.GrayText, MaximumSize = new Size(560, 0) });
        foreach (var a in accounts)
        {
            var row = new FlowLayoutPanel { AutoSize = true, WrapContents = false };
            var provider = a["provider"]?.GetValue<string>() ?? "";
            var label = a["label"]?.GetValue<string>() ?? "";
            var id = a["id"]?.GetValue<string>() ?? "";
            row.Controls.Add(new Label { Text = (provider == "google" ? "Google · " : "Microsoft · ") + (label.Length > 0 ? label : id), AutoSize = true, Margin = new Padding(0, 7, 8, 0) });
            if (a["ok"]?.GetValue<bool>() != true)
                row.Controls.Add(new Label { Text = T("cal_login_needed"), AutoSize = true, ForeColor = Color.FromArgb(0xE6, 0x51, 0x00), Margin = new Padding(0, 7, 8, 0) });
            var rm = new Button { Text = T("cal_remove"), AutoSize = true, Enabled = busy == null };
            rm.Click += (_, _) => Meet.Run(new[] { "account", "remove", id }, (_, o) => { AddLog(o); Refresh_(); });
            row.Controls.Add(rm);
            accountsPanel.Controls.Add(row);
        }
    }

    public void Refresh_()
    {
        Meet.Run(new[] { "accounts", "--json" }, (_, out_) =>
        {
            if (IsDisposed) return;
            var j = Meet.LastJson(out_) as JsonObject;
            accounts = (j?["accounts"] as JsonArray)?.OfType<JsonObject>().ToList() ?? new();
            googleClient = j?["google_client"]?.GetValue<bool>() ?? false;
            msClient = j?["ms_client"]?.GetValue<bool>() ?? false;
            BuildChecks();
        });
        BuildChecks();
    }

    void AddLog(string s)
    {
        if (IsDisposed || s.Length == 0) return;
        log.AppendText(s.Replace("\r", "").Replace("\n", "\r\n") + (s.EndsWith("\n") ? "" : "\r\n"));
    }

    void SetBusy(string? what, double? pct = null)
    {
        busy = what;
        busyLabel.Text = what == null ? "" : what + (pct is double p ? $" {p * 100:F0}%" : "");
        progress.Visible = what != null;
        progress.Style = pct == null ? ProgressBarStyle.Marquee : ProgressBarStyle.Continuous;
        if (pct is double q) progress.Value = (int)Math.Clamp(q * 100, 0, 100);
        foreach (var b in actionButtons) b.Enabled = what == null;
    }

    void Run(string id)
    {
        switch (id)
        {
            case "ffmpeg": _ = InstallFfmpeg(); break;
            case "whisper": _ = InstallWhisper(); break;
            case "model": _ = InstallModels(); break;
            case "mic": Shell.Open("ms-settings:privacy-microphone"); AddLog(T("setup_win_mic_after")); break;
            case "vault": ChooseVault(); break;
            case "cli": InstallCli(); break;
        }
    }

    // ---------------------------------------------------------------- downloads

    static readonly HttpClient http = new(new HttpClientHandler { AllowAutoRedirect = true }) { Timeout = TimeSpan.FromHours(2) };
    static SetupForm() { http.DefaultRequestHeaders.UserAgent.ParseAdd("MeetRec-Setup"); }

    async Task<bool> Download(string url, string dest, string label)
    {
        AddLog("↓ " + url);
        SetBusy(T("setup_downloading", ("file", label)), 0);
        var part = dest + ".part";
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
            using var resp = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
            resp.EnsureSuccessStatusCode();
            var total = resp.Content.Headers.ContentLength ?? 0;
            await using (var src = await resp.Content.ReadAsStreamAsync())
            await using (var fs = File.Create(part))
            {
                var buf = new byte[1 << 20];
                long got = 0; var last = DateTime.MinValue;
                int n;
                while ((n = await src.ReadAsync(buf)) > 0)
                {
                    await fs.WriteAsync(buf.AsMemory(0, n));
                    got += n;
                    if (total > 0 && (DateTime.Now - last).TotalMilliseconds > 200) { SetBusy(busy, (double)got / total); last = DateTime.Now; }
                }
            }
            File.Move(part, dest, true);
            AddLog("✔ " + Path.GetFileName(dest));
            return true;
        }
        catch (Exception e)
        {
            AddLog("✖ " + e.Message);
            try { File.Delete(part); } catch { }
            return false;
        }
    }

    async Task InstallFfmpeg()
    {
        var zip = Path.Combine(Paths.DataDir, "ffmpeg.zip");
        if (await Download(FfmpegUrl, zip, "ffmpeg"))
        {
            SetBusy(T("setup_win_extracting", ("file", "ffmpeg.exe")));
            await Task.Run(() =>
            {
                using var z = ZipFile.OpenRead(zip);
                var e = z.Entries.First(x => x.Name.Equals("ffmpeg.exe", StringComparison.OrdinalIgnoreCase));
                Directory.CreateDirectory(Bin);
                e.ExtractToFile(Path.Combine(Bin, "ffmpeg.exe"), true);
            });
            File.Delete(zip);
        }
        SetBusy(null);
        BuildChecks();
    }

    async Task InstallWhisper()
    {
        SetBusy(T("setup_downloading", ("file", "whisper.cpp")));
        string? url = null;
        try
        {
            var rels = JsonNode.Parse(await http.GetStringAsync("https://api.github.com/repos/ggml-org/whisper.cpp/releases?per_page=20")) as JsonArray;
            foreach (var r in rels!.OfType<JsonObject>())
            {
                var a = (r["assets"] as JsonArray)?.OfType<JsonObject>().FirstOrDefault(x => x["name"]?.GetValue<string>() == "whisper-bin-x64.zip");
                if (a != null) { url = a["browser_download_url"]!.GetValue<string>(); AddLog("whisper.cpp " + r["tag_name"]); break; }
            }
        }
        catch (Exception e) { AddLog("✖ " + e.Message); }
        var zip = Path.Combine(Paths.DataDir, "whisper.zip");
        if (url != null && await Download(url, zip, "whisper.cpp"))
        {
            SetBusy(T("setup_win_extracting", ("file", "whisper-cli.exe")));
            await Task.Run(() =>
            {
                // whisper-cli.exe and the ggml/whisper DLLs next to it, whatever folder the zip uses
                using var z = ZipFile.OpenRead(zip);
                Directory.CreateDirectory(Bin);
                foreach (var e in z.Entries)
                    if (e.Name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) || e.Name.Equals("whisper-cli.exe", StringComparison.OrdinalIgnoreCase))
                        e.ExtractToFile(Path.Combine(Bin, e.Name), true);
            });
            File.Delete(zip);
        }
        SetBusy(null);
        BuildChecks();
    }

    async Task InstallModels()
    {
        foreach (var (file, url) in Models)
        {
            if (ModelPath(file) != null) continue;
            if (!await Download(url, Path.Combine(ModelDir, file), file)) break;
        }
        SetBusy(null);
        BuildChecks();
    }

    // ---------------------------------------------------------------- vault, command line

    void ChooseVault()
    {
        using var d = new FolderBrowserDialog { Description = T("setup_vault_panel"), UseDescriptionForTitle = true };
        if (d.ShowDialog(this) != DialogResult.OK) return;
        var cfg = Config.Load();
        cfg["vault"] = d.SelectedPath;
        Config.Save(cfg);
        BuildChecks();
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, UIntPtr w, string l, uint flags, uint timeout, out UIntPtr result);

    /// meet.cmd is in the app folder: put the folder in the user PATH (new terminals see it)
    void InstallCli()
    {
        using var k = Registry.CurrentUser.CreateSubKey("Environment");
        var p = k.GetValue("Path", "", RegistryValueOptions.DoNotExpandEnvironmentNames) as string ?? "";
        var kind = k.GetValueKind("Path") == RegistryValueKind.ExpandString || p.Length == 0 ? RegistryValueKind.ExpandString : RegistryValueKind.String;
        k.SetValue("Path", (p.Length > 0 && !p.EndsWith(";") ? p + ";" : p) + Paths.AppDir, kind);
        SendMessageTimeout((IntPtr)0xffff, 0x001A, UIntPtr.Zero, "Environment", 2, 3000, out _);   // WM_SETTINGCHANGE
        AddLog(T("setup_win_cli_done", ("path", Paths.AppDir)));
        BuildChecks();
    }

    // ---------------------------------------------------------------- calendar accounts

    void CancelLogin()
    {
        if (loginProc == null || loginProc.HasExited) return;
        loginCancelled = true;
        try { loginProc.Kill(true); } catch { }
    }

    void RunLogin(params string[] args)
    {
        SetBusy(T("cal_logging_in"));
        loginMessage.Text = "";
        loginCancelled = false;
        cancelLogin.Visible = true;
        loginProc = Meet.Run(args, (st, out_) =>
        {
            if (IsDisposed) return;
            SetBusy(null);
            cancelLogin.Visible = loginUrl.Visible = copyUrl.Visible = false;
            loginProc = null;
            if (loginCancelled) loginMessage.Text = T("cal_login_cancelled");
            else loginMessage.Text = st == 0 ? T("logged_in") : T("login_failed") + Meet.LastLine(out_);
            AddLog(string.Join("\n", out_.Split('\n').Where(l => l.StartsWith("[meet]"))));
            Refresh_();
        }, line =>
        {
            if (IsDisposed) return;
            var url = Regex.Match(line, @"https://microsoft\.com/\S+|https://login\.microsoft\S+");
            var code = Regex.Match(line, @"code ([A-Z0-9]+)");
            var g = Regex.Match(line, @"https://accounts\.google\.com/\S+");
            if (url.Success && code.Success)
            {
                Clipboard.SetText(code.Groups[1].Value);
                loginMessage.Text = T("login_code_copied", ("code", code.Groups[1].Value));
                ShowUrl(url.Value);
                Shell.Open(url.Value);
            }
            else if (g.Success)
            {
                loginMessage.Text = T("cal_google_browser");
                ShowUrl(g.Value);
            }
        });
    }

    void ShowUrl(string u)
    {
        loginUrl.Text = u;
        loginUrl.Visible = copyUrl.Visible = true;
    }

    void AddMicrosoft()
    {
        if (msClient) { RunLogin("account", "add", "microsoft"); return; }
        Guides.Microsoft(this, cid => Meet.Run(new[] { "account", "ms-client", cid }, (st, o) =>
        {
            AddLog(o);
            if (st != 0) { System.Media.SystemSounds.Beep.Play(); return; }
            msClient = true;
            RunLogin("account", "add", "microsoft");
        }));
    }

    void AddGoogle()
    {
        if (googleClient) { RunLogin("account", "add", "google"); return; }
        Guides.Google(this, path => Meet.Run(new[] { "account", "google-client", path }, (st, o) =>
        {
            AddLog(o);
            if (st != 0) { System.Media.SystemSounds.Beep.Play(); return; }
            googleClient = true;
            RunLogin("account", "add", "google");
        }));
    }
}

/// step by step guides for your own Google OAuth client and Microsoft app registration (once)
static class Guides
{
    static readonly (string t, string x, string? url)[] GoogleSteps =
    {
        ("g1_title", "g1_text", "https://console.cloud.google.com/projectcreate"),
        ("g2_title", "g2_text", "https://console.cloud.google.com/apis/library/calendar-json.googleapis.com"),
        ("g3_title", "g3_text", "https://console.cloud.google.com/apis/credentials/consent"),
        ("g4_title", "g4_text", "https://console.cloud.google.com/auth/audience"),
        ("g5_title", "g5_text", "https://console.cloud.google.com/apis/credentials"),
        ("g6_title", "g6_text", null),
    };
    static readonly (string t, string x, string? url)[] MicrosoftSteps =
    {
        ("m1_title", "m1_text", "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade"),
        ("m2_title", "m2_text", null), ("m3_title", "m3_text", null), ("m4_title", "m4_text", null), ("m5_title", "m5_text", null),
    };

    public static Form Make(string title, string intro, (string t, string x, string? url)[] steps, Control bottom)
    {
        var f = new Form
        {
            Text = "MeetRec", Icon = Icons.App, Font = SystemFonts.MessageBoxFont, StartPosition = FormStartPosition.CenterScreen,
            ClientSize = new Size(640, 660), FormBorderStyle = FormBorderStyle.Sizable, MinimizeBox = false, MaximizeBox = false,
        };
        var root = new TableLayoutPanel { ColumnCount = 1, Dock = DockStyle.Fill, Padding = new Padding(16) };
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        var head = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false };
        head.Controls.Add(new Label { Text = title, AutoSize = true, Font = new Font(f.Font.FontFamily, f.Font.Size + 4, FontStyle.Bold) });
        head.Controls.Add(new Label { Text = intro, AutoSize = true, MaximumSize = new Size(590, 0), ForeColor = SystemColors.GrayText, Margin = new Padding(3, 4, 3, 8) });
        root.Controls.Add(head);
        var list = new TableLayoutPanel { ColumnCount = 3, AutoSize = true, Dock = DockStyle.Top };
        list.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 34));
        list.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        list.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        for (int i = 0; i < steps.Length; i++)
        {
            var (t, x, url) = steps[i];
            list.Controls.Add(new Label { Text = (i + 1).ToString(), AutoSize = true, Font = new Font(f.Font, FontStyle.Bold), Margin = new Padding(8, 4, 0, 0) });
            var text = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false, Margin = new Padding(0, 2, 0, 10) };
            text.Controls.Add(new Label { Text = L.T(t), AutoSize = true, Font = new Font(f.Font, FontStyle.Bold) });
            text.Controls.Add(new TextBox { Text = L.T(x), ReadOnly = true, BorderStyle = BorderStyle.None, Multiline = true, Width = 470, BackColor = SystemColors.Control,
                                            Height = TextRenderer.MeasureText(L.T(x), f.Font, new Size(470, 0), TextFormatFlags.WordBreak).Height + 6 });
            list.Controls.Add(text);
            if (url != null)
            {
                var b = new Button { Text = L.T("g_open"), AutoSize = true };
                b.Click += (_, _) => Shell.Open(url);
                list.Controls.Add(b);
            }
            else list.Controls.Add(new Label { AutoSize = true });
        }
        var scroll = new Panel { Dock = DockStyle.Fill, AutoScroll = true };
        scroll.Controls.Add(list);
        root.Controls.Add(scroll);
        bottom.Dock = DockStyle.Fill;
        root.Controls.Add(bottom);
        f.Controls.Add(root);
        return f;
    }

    public static Form Microsoft(IWin32Window? owner, Action<string> save, bool show = true)
    {
        var row = new FlowLayoutPanel { AutoSize = true, WrapContents = false };
        var id = new TextBox { Width = 330, PlaceholderText = "00000000-0000-0000-0000-000000000000", Font = new Font(FontFamily.GenericMonospace, 9.5f) };
        var ok = new Button { Text = L.T("m_save"), AutoSize = true, Enabled = false };
        var cancel = new Button { Text = L.T("cancel"), AutoSize = true };
        id.TextChanged += (_, _) => ok.Enabled = id.Text.Trim().Length >= 36;
        row.Controls.Add(cancel); row.Controls.Add(id); row.Controls.Add(ok);
        var f = Make(L.T("m_title"), L.T("m_intro"), MicrosoftSteps, row);
        f.AcceptButton = ok;
        cancel.Click += (_, _) => f.Close();
        ok.Click += (_, _) => { save(id.Text.Trim()); f.Close(); };
        if (show) f.Show(owner);
        return f;
    }

    public static Form Google(IWin32Window? owner, Action<string> save, bool show = true)
    {
        var row = new FlowLayoutPanel { AutoSize = true, WrapContents = false };
        var cancel = new Button { Text = L.T("cancel"), AutoSize = true };
        var choose = new Button { Text = L.T("cal_google_choose_json"), AutoSize = true };
        row.Controls.Add(cancel); row.Controls.Add(choose);
        var f = Make(L.T("g_title"), L.T("g_intro"), GoogleSteps, row);
        f.AcceptButton = choose;
        cancel.Click += (_, _) => f.Close();
        choose.Click += (_, _) =>
        {
            using var d = new OpenFileDialog
            {
                Filter = "JSON|*.json",
                InitialDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads"),
            };
            if (d.ShowDialog(f) == DialogResult.OK) { save(d.FileName); f.Close(); }
        };
        if (show) f.Show(owner);
        return f;
    }
}
