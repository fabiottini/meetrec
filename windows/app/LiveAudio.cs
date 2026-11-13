// Live audio pieces of the Windows app, like the macOS ones:
//  - LevelPanel: mic and system meters at the top of the menu, input volume, auto gain, mute, mic test
//  - MicMute: "Mute microphone" switch, forced every second, restored when switched off or on quit
//  - CallWatcher + CallPrompt: another app opens the mic -> "Record?"; it releases it -> "Stop?"

using System.Text.Json.Nodes;
using Microsoft.Win32;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using static MeetRec.L;

namespace MeetRec;

static class Mics
{
    /// the configured mic, or the default communications mic (the same one the recorder uses)
    public static MMDevice? Current()
    {
        try
        {
            var en = new MMDeviceEnumerator();
            var id = Config.Str("mic_id", "");
            if (id.Length > 0) { try { return en.GetDevice(id); } catch { } }
            return en.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications);
        }
        catch { return null; }
    }
}

// ---------------------------------------------------------------- mute

static class MicMute
{
    public static bool Enabled
    {
        get => AppState.Load()["micMuteEnabled"]?.GetValue<bool>() == true;
        set => AppState.Set("micMuteEnabled", value);
    }

    /// devices muted by us (saved, so a crash does not leave a mic muted: the next start restores it)
    static List<string> MutedByUs
    {
        get => (AppState.Load()["micMutedDevices"] as JsonArray)?.Select(n => n!.GetValue<string>()).ToList() ?? new();
        set => AppState.Set("micMutedDevices", new JsonArray(value.Select(v => (JsonNode)v!).ToArray()));
    }

    public static bool Unsupported;

    public static void Tick()
    {
        if (!Enabled) { RestoreAll(); return; }
        using var d = Mics.Current();
        if (d == null) return;
        try
        {
            if (!d.AudioEndpointVolume.Mute) d.AudioEndpointVolume.Mute = true;
            var l = MutedByUs;
            if (!l.Contains(d.ID)) { l.Add(d.ID); MutedByUs = l; }
            Unsupported = false;
        }
        catch { Unsupported = true; }
    }

    public static void RestoreAll()
    {
        var l = MutedByUs;
        if (l.Count == 0) return;
        var en = new MMDeviceEnumerator();
        foreach (var id in l)
        {
            try { using var d = en.GetDevice(id); d.AudioEndpointVolume.Mute = false; } catch { }
        }
        MutedByUs = new();
    }

    public static bool IsMuted()
    {
        using var d = Mics.Current();
        try { return d?.AudioEndpointVolume.Mute == true; } catch { return false; }
    }
}

// ---------------------------------------------------------------- levels in the menu

sealed class LevelPanel : UserControl
{
    readonly Label micName = new() { AutoSize = false, AutoEllipsis = true, Height = 20 };
    readonly Button mute = new() { AutoSize = true };
    readonly Meters meters = new() { Height = 44 };
    readonly Label status = new() { AutoSize = false, Height = 20 };
    readonly TrackBar volume = new() { Minimum = 0, Maximum = 100, TickStyle = TickStyle.None, AutoSize = false, Height = 26 };
    readonly Label volLabel = new() { AutoSize = false, Width = 90, Height = 20, TextAlign = ContentAlignment.MiddleRight };
    readonly CheckBox agc = new() { AutoSize = true };
    readonly Button test = new() { AutoSize = true };
    readonly Label note = new() { AutoSize = false, Height = 34, ForeColor = SystemColors.GrayText };
    readonly System.Windows.Forms.Timer timer = new() { Interval = 100 };
    readonly TrayApp app;
    WasapiCapture? preview;
    readonly object gate = new();
    float pPeak; double pSum; long pN; int pClip;
    DateTime lastClip = DateTime.MinValue;
    bool settingVolume;
    public Action? OnMuteToggled;

    public LevelPanel(TrayApp app)
    {
        this.app = app;
        Font = SystemFonts.MenuFont;
        Width = 330;
        Height = 200;
        BackColor = Color.Transparent;
        int x = 12, w = Width - 24;
        micName.SetBounds(x, 6, w - 90, 20);
        mute.Location = new Point(Width - 12 - 80, 2);
        mute.Click += (_, _) => OnMuteToggled?.Invoke();
        meters.SetBounds(x, 30, w, 44);
        status.SetBounds(x, 76, w, 20);
        volume.SetBounds(x - 4, 98, w - 90, 26);
        volLabel.Location = new Point(Width - 12 - 90, 100);
        volume.ValueChanged += (_, _) =>
        {
            if (settingVolume) return;
            using var d = Mics.Current();
            try { if (d != null) d.AudioEndpointVolume.MasterVolumeLevelScalar = volume.Value / 100f; } catch { }
            volLabel.Text = $"{volume.Value}%";
        };
        agc.Location = new Point(x, 128);
        agc.CheckedChanged += (_, _) =>
        {
            var c = Config.Load();
            if ((c["auto_gain"]?.GetValue<bool>() ?? true) == agc.Checked) return;
            c["auto_gain"] = agc.Checked;
            Config.Save(c);
        };
        test.Location = new Point(x, 154);
        test.Click += (_, _) => StartPreview();
        note.SetBounds(x + 110, 152, w - 110, 34);
        Controls.AddRange(new Control[] { micName, mute, meters, status, volume, volLabel, agc, test, note });
        timer.Tick += (_, _) => Tick();
    }

    /// height for the menu: without the mic test row while recording
    public void Prepare(bool recording)
    {
        Height = recording ? 152 : 192;
        test.Visible = note.Visible = !recording;
    }

    public void Open()
    {
        using var d = Mics.Current();
        micName.Text = T("microphone_2") + (d?.FriendlyName ?? "—");
        agc.Text = T("lower_automatically_when_clipping");
        agc.Checked = Config.Bool("auto_gain", true);
        test.Text = T("test_mic");
        bool recording = app.Cur()?.Alive == true;
        test.Visible = !recording;
        note.Text = recording ? "" : T("preview_hint");
        meters.Clear();
        ReadVolume(d);
        UpdateMute();
        Tick();
        timer.Start();
    }

    public void Close()
    {
        timer.Stop();
        StopPreview();
    }

    void UpdateMute()
    {
        var m = MicMute.Enabled;
        mute.Text = m ? T("unmute") : T("mute");
        mute.Location = new Point(Width - 12 - mute.Width, 2);
    }

    void ReadVolume(MMDevice? d)
    {
        settingVolume = true;
        try
        {
            if (d == null) throw new InvalidOperationException();
            var v = (int)Math.Round(d.AudioEndpointVolume.MasterVolumeLevelScalar * 100);
            volume.Value = Math.Clamp(v, 0, 100);
            volume.Enabled = true;
            volLabel.Text = $"{volume.Value}%";
        }
        catch { volume.Enabled = false; volLabel.Text = T("not_adjustable"); }
        settingVolume = false;
    }

    void StartPreview()
    {
        StopPreview();
        note.Text = T("preview_starting");
        try
        {
            var d = Mics.Current() ?? throw new InvalidOperationException();
            var cap = new WasapiCapture(d);
            var fmt = cap.WaveFormat;
            cap.DataAvailable += (_, e) =>
            {
                int ch = fmt.Channels, bps = fmt.BitsPerSample / 8;
                bool isFloat = fmt.Encoding == WaveFormatEncoding.IeeeFloat || (fmt is WaveFormatExtensible && bps == 4);
                float p = 0; double s = 0; int c = 0, n = 0;
                for (int o = 0; o + bps <= e.BytesRecorded; o += bps * ch)
                {
                    float v = isFloat ? Math.Abs(BitConverter.ToSingle(e.Buffer, o)) : bps == 2 ? Math.Abs(BitConverter.ToInt16(e.Buffer, o) / 32768f) : 0;
                    if (v > p) p = v;
                    if (v >= 0.98f) c++;
                    s += v * v; n++;
                }
                lock (gate) { pPeak = Math.Max(pPeak, p); pSum += s; pN += n; pClip += c; }
            };
            cap.StartRecording();
            preview = cap;
            note.Text = T("preview_the_mic_is_listening_while_the");
        }
        catch { note.Text = T("mic_preview_not_available_permission"); }
    }

    void StopPreview()
    {
        try { preview?.StopRecording(); preview?.Dispose(); } catch { }
        preview = null;
    }

    (double rms, double peak, int clip) TakePreview()
    {
        lock (gate)
        {
            if (pN == 0) return (-120, -120, 0);
            double rms = Math.Sqrt(pSum / pN), pk = pPeak;
            var r = (rms > 0 ? 20 * Math.Log10(rms) : -120, pk > 0 ? 20 * Math.Log10(pk) : -120, pClip);
            pPeak = 0; pSum = 0; pN = 0; pClip = 0;
            return r;
        }
    }

    /// <dir>/levels: "mic rms peak", "system rms peak", "volume v"
    public static Dictionary<string, double[]> ReadLevels(string dir)
    {
        var d = new Dictionary<string, double[]>();
        try
        {
            foreach (var l in File.ReadAllLines(Path.Combine(dir, "levels")))
            {
                var p = l.Split(' ');
                if (p.Length >= 2)
                    d[p[0]] = p.Skip(1).Select(x => double.Parse(x, System.Globalization.CultureInfo.InvariantCulture)).ToArray();
            }
        }
        catch { }
        return d;
    }

    void Tick()
    {
        var c = app.Cur();
        bool recording = c?.Alive == true;
        (double, double)? sys = null;
        (double rms, double peak) mic;
        if (recording)
        {
            var lv = ReadLevels(c!.Dir);
            mic = lv.TryGetValue("mic", out var m) && m.Length >= 2 ? (m[0], m[1]) : (-120, -120);
            if (lv.TryGetValue("system", out var s) && s.Length >= 2) sys = (s[0], s[1]);
            if (lv.TryGetValue("volume", out var v) && v.Length >= 1 && !volume.Capture)
            {
                settingVolume = true; volume.Value = Math.Clamp((int)Math.Round(v[0] * 100), 0, 100); volLabel.Text = $"{volume.Value}%"; settingVolume = false;
            }
            if (mic.peak >= -0.2) lastClip = DateTime.Now;
            StopPreview();
        }
        else if (preview != null)
        {
            var p = TakePreview();
            mic = (p.rms, p.peak);
            if (p.clip > 0) lastClip = DateTime.Now;
        }
        else mic = (-120, -120);
        meters.Push(mic, sys, recording);
        var (text, color) = Status(recording, mic);
        status.Text = text; status.ForeColor = color;
        UpdateMute();
    }

    (string, Color) Status(bool recording, (double rms, double peak) mic)
    {
        if (MicMute.Enabled)
        {
            if (MicMute.Unsupported) return (T("mute_unsupported"), Color.DarkOrange);
            return (recording ? T("recording_while_muted") : T("mic_muted_status"), Color.Firebrick);
        }
        if (!recording && preview == null) return ("", SystemColors.GrayText);
        if ((DateTime.Now - lastClip).TotalSeconds < 2) return (T("clipping_lower_the_volume"), Color.Firebrick);
        var loud = meters.Loud();
        if (loud < -50) return (T("silence_speak_to_test_the_level"), SystemColors.GrayText);
        if (loud < -32) return (T("low_raise_the_mic_volume"), Color.DarkOrange);
        if (loud > -8) return (T("high_close_to_clipping"), Color.DarkOrange);
        return (T("level_ok"), Color.ForestGreen);
    }

    /// the two meters ("You", "Others"), drawn
    sealed class Meters : Control
    {
        (double rms, double peak) mic = (-120, -120);
        (double rms, double peak)? sys;
        bool recording;
        readonly Queue<double> history = new();

        public Meters() { DoubleBuffered = true; }

        public void Clear() { history.Clear(); mic = (-120, -120); sys = null; Invalidate(); }

        public void Push((double, double) m, (double, double)? s, bool rec)
        {
            mic = m; sys = s; recording = rec;
            history.Enqueue(m.Item2);
            while (history.Count > 20) history.Dequeue();
            Invalidate();
        }

        /// loudest peak of the last 2 s
        public double Loud() => history.Count == 0 ? -120 : history.Max();

        static float Frac(double db) => (float)Math.Clamp((db + 60) / 60, 0, 1);

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            int labelW = 64;
            void Meter(string label, (double rms, double peak)? v, int y)
            {
                TextRenderer.DrawText(g, label, Font, new Point(0, y - 2), ForeColor);
                var r = new Rectangle(labelW, y, Width - labelW - 2, 12);
                using (var bg = new SolidBrush(Color.FromArgb(40, 128, 128, 128))) g.FillRectangle(bg, r);
                if (v == null)
                {
                    TextRenderer.DrawText(g, T("only_while_recording"), Font, new Point(labelW + 4, y - 2), SystemColors.GrayText);
                    return;
                }
                var f = Frac(v.Value.rms);
                var col = v.Value.peak >= -1 ? Color.Firebrick : v.Value.peak > -8 ? Color.DarkOrange : Color.ForestGreen;
                using (var b = new SolidBrush(col)) g.FillRectangle(b, r.X, r.Y, r.Width * f, r.Height);
                var px = r.X + r.Width * Frac(v.Value.peak);
                using (var p = new Pen(ForeColor, 2)) g.DrawLine(p, px, r.Y, px, r.Bottom);
            }
            Meter(T("you"), mic, 6);
            Meter(T("others"), recording ? sys ?? (-120, -120) : null, 26);
        }
    }
}

// ---------------------------------------------------------------- call detection

sealed class CallWatcher
{
    public Action<string>? OnCallStart, OnCallEnd;
    public bool InCall { get; private set; }
    string callApp = "";
    DateTime? activeSince, inactiveSince;
    readonly System.Windows.Forms.Timer timer = new() { Interval = 3000 };
    string lastUsers = "";

    const string Store = @"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";

    public void Start()
    {
        timer.Tick += (_, _) => Tick();
        timer.Start();
    }

    static readonly Dictionary<string, string> Names = new(StringComparer.OrdinalIgnoreCase)
    {
        ["ms-teams.exe"] = "Microsoft Teams", ["teams.exe"] = "Microsoft Teams", ["MSTeams"] = "Microsoft Teams",
        ["zoom.exe"] = "Zoom", ["slack.exe"] = "Slack", ["chrome.exe"] = "Google Chrome", ["msedge.exe"] = "Microsoft Edge",
        ["firefox.exe"] = "Firefox", ["brave.exe"] = "Brave", ["opera.exe"] = "Opera", ["webex.exe"] = "Webex",
        ["CiscoCollabHost.exe"] = "Webex", ["Discord.exe"] = "Discord", ["WhatsApp"] = "WhatsApp", ["Skype"] = "Skype",
        ["Telegram.exe"] = "Telegram", ["GoTo.exe"] = "GoTo Meeting",
    };

    // voice typing, Cortana and speech services open the mic too: not calls
    static readonly string[] Ignored = { "MeetRec.exe", "meetrec-capture.exe", "Microsoft.Windows.Cortana", "MicrosoftWindows.Client", "SpeechRuntime", "VoiceAccess", "TextInputHost" };

    /// apps using a microphone right now, from the privacy usage records (no permission needed)
    public static List<string> MicUsers()
    {
        var users = new List<string>();
        void Scan(RegistryKey? root, bool nonPackaged)
        {
            if (root == null) return;
            foreach (var name in root.GetSubKeyNames())
            {
                if (name == "NonPackaged") continue;
                using var k = root.OpenSubKey(name);
                if (k == null) continue;
                var start = k.GetValue("LastUsedTimeStart") as long? ?? 0;
                var stop = k.GetValue("LastUsedTimeStop") as long? ?? -1;
                if (start == 0 || stop != 0) continue;            // in use: started and not stopped
                var id = nonPackaged ? name.Split('#').Last() : name.Split('_')[0];
                if (Ignored.Any(i => id.Contains(i, StringComparison.OrdinalIgnoreCase))) continue;
                var key = Names.Keys.FirstOrDefault(n => id.Contains(n, StringComparison.OrdinalIgnoreCase));
                users.Add(key != null ? Names[key] : Path.GetFileNameWithoutExtension(id));
            }
        }
        try
        {
            using var store = Registry.CurrentUser.OpenSubKey(Store);
            Scan(store, false);
            using var np = Registry.CurrentUser.OpenSubKey(Store + @"\NonPackaged");
            Scan(np, true);
        }
        catch { }
        return users.Distinct().ToList();
    }

    void Tick()
    {
        var users = MicUsers();
        var joined = string.Join(", ", users);
        if (joined != lastUsers)
        {
            Log.Append("[app] microphone in use by: " + (users.Count == 0 ? "nobody" : joined) + "\n");
            lastUsers = joined;
        }
        var now = DateTime.Now;
        if (users.Count > 0)
        {
            inactiveSince = null;
            activeSince ??= now;
            if (!InCall && (now - activeSince.Value).TotalSeconds >= 3)
            {
                InCall = true; callApp = users[0];
                OnCallStart?.Invoke(callApp);
            }
        }
        else
        {
            activeSince = null;
            if (InCall)
            {
                inactiveSince ??= now;
                if ((now - inactiveSince.Value).TotalSeconds >= 8) { InCall = false; OnCallEnd?.Invoke(callApp); }
            }
        }
    }
}

/// the small prompt in the bottom right corner, above the clock; it does not take the focus
sealed class CallPrompt : Form
{
    static CallPrompt? current;
    protected override bool ShowWithoutActivation => true;
    protected override CreateParams CreateParams
    {
        get { var p = base.CreateParams; p.ExStyle |= 0x08000000 | 0x00000080; return p; }   // NOACTIVATE | TOOLWINDOW
    }

    CallPrompt(string title, string subtitle, string primary, string secondary, Action onPrimary, Action? onSecondary)
    {
        FormBorderStyle = FormBorderStyle.FixedSingle;
        ControlBox = false;
        Text = "";
        TopMost = true;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        Font = SystemFonts.MessageBoxFont;
        AutoSize = true; AutoSizeMode = AutoSizeMode.GrowAndShrink;
        var row = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Padding = new Padding(12) };
        row.Controls.Add(new PictureBox { Image = Icons.Glyph(40, Color.FromArgb(0xE5, 0x39, 0x35), null), Size = new Size(44, 44) });
        var col = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false };
        col.Controls.Add(new Label { Text = title, AutoSize = true, MaximumSize = new Size(280, 0), Font = new Font(Font, FontStyle.Bold) });
        if (subtitle.Length > 0) col.Controls.Add(new Label { Text = subtitle, AutoSize = true, MaximumSize = new Size(280, 0), ForeColor = SystemColors.GrayText });
        var buttons = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(0, 6, 0, 0) };
        var a = new Button { Text = primary, AutoSize = true };
        var b = new Button { Text = secondary, AutoSize = true };
        a.Click += (_, _) => { Close(); onPrimary(); };
        b.Click += (_, _) => { Close(); onSecondary?.Invoke(); };
        buttons.Controls.Add(a); buttons.Controls.Add(b);
        col.Controls.Add(buttons);
        row.Controls.Add(col);
        Controls.Add(row);
        var t = new System.Windows.Forms.Timer { Interval = 60000 };
        t.Tick += (_, _) => { t.Stop(); Close(); };
        t.Start();
        Load += (_, _) =>
        {
            var area = Screen.PrimaryScreen!.WorkingArea;
            Location = new Point(area.Right - Width - 16, area.Bottom - Height - 12);
        };
    }

    public static void Show(string title, string subtitle, string primary, string secondary, Action onPrimary, Action? onSecondary = null)
    {
        Hide_();
        current = new CallPrompt(title, subtitle, primary, secondary, onPrimary, onSecondary);
        current.FormClosed += (s, _) => { if (current == s) current = null; };
        current.Show();
    }

    public static void Hide_() { current?.Close(); current = null; }

    public static Form Demo() => new CallPrompt(T("call_detected", ("app", "Microsoft Teams")), "Weekly product sync",
                                                T("record"), T("ignore"), () => { }, null);
}
