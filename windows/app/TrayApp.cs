// The tray icon and its menu: the Windows twin of the macOS menu bar app (menubar/main.swift).
// All the work is done by meet.py; this file only asks and shows.

using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using static MeetRec.L;

namespace MeetRec;

sealed class TrayApp : ApplicationContext
{
    public readonly NotifyIcon Tray = new();
    public readonly ContextMenuStrip Menu = new();
    readonly System.Windows.Forms.Timer timer = new();
    readonly HotKeyWindow hotkey;
    public bool Processing;
    public string ProcessingStep = "";
    public string? LastNote;
    public List<JsonObject> Recent = new(), Recover = new();
    string lastIconKey = "";
    Icon? currentIcon;
    /// set only by --render-docs: draw the menu of a recording without recording
    public DateTimeOffset? DocsRecording;
    public readonly LevelPanel Levels;
    readonly ToolStripControlHost levelHost;
    DateTime lastMuteTick = DateTime.MinValue;

    public TrayApp(bool show = true)
    {
        LastNote = AppState.Load()["lastNote"]?.GetValue<string>();
        Menu.Opening += (_, e) => { BuildMenu(); e.Cancel = false; };
        Menu.ShowImageMargin = false;
        Levels = new LevelPanel(this);
        levelHost = new ToolStripControlHost(Levels) { AutoSize = false, Size = Levels.Size, Margin = Padding.Empty, Padding = Padding.Empty };
        Levels.OnMuteToggled = ToggleMute;
        Menu.Opened += (_, _) => Levels.Open();
        Menu.Closed += (_, _) => Levels.Close();
        Tray.ContextMenuStrip = Menu;
        Tray.Text = "MeetRec";
        // left click opens the same menu (right click does it by itself)
        Tray.MouseUp += (_, e) =>
        {
            if (e.Button == MouseButtons.Left)
                typeof(NotifyIcon).GetMethod("ShowContextMenu", BindingFlags.Instance | BindingFlags.NonPublic)?.Invoke(Tray, null);
        };
        Tray.BalloonTipClicked += (_, _) => { if (balloonNote != null) Shell.OpenNote(balloonNote); };
        timer.Tick += (_, _) => Refresh();
        hotkey = new HotKeyWindow(HotKeyPressed);
        Refresh();
        Tray.Visible = show;
        if (show) LoadLists();
    }

    // ---------------------------------------------------------------- state

    public record Current(DateTimeOffset Start, string? Title, bool Alive, string Dir);

    public Current? Cur()
    {
        if (DocsRecording is DateTimeOffset d) return new(d, "Weekly product sync", true, "");
        try
        {
            var j = JsonNode.Parse(File.ReadAllText(Paths.StateFile))!.AsObject();
            var start = DateTimeOffset.Parse(j["started_at"]!.GetValue<string>());
            return new(start, j["title"]?.GetValue<string>(), Shell.PidAlive(j["pid"]!.GetValue<int>()), j["dir"]?.GetValue<string>() ?? "");
        }
        catch { return null; }
    }

    public static string Elapsed(DateTimeOffset since)
    {
        var s = (int)Math.Max(0, (DateTimeOffset.Now - since).TotalSeconds);
        return s >= 3600 ? $"{s / 3600}:{s % 3600 / 60:00}:{s % 60:00}" : $"{s / 60:00}:{s % 60:00}";
    }

    /// mic level from <dir>/levels, written by the recorder every 100 ms
    public static double MicDb(string dir)
    {
        try
        {
            foreach (var l in File.ReadAllLines(Path.Combine(dir, "levels")))
            {
                var p = l.Split(' ');
                if (p.Length >= 2 && p[0] == "mic") return double.Parse(p[1], System.Globalization.CultureInfo.InvariantCulture);
            }
        }
        catch { }
        return -120;
    }

    /// icon and tooltip; the timer runs every 2 s when idle and 4 times a second while recording
    public void Refresh()
    {
        if ((DateTime.Now - lastMuteTick).TotalSeconds >= 1 && DocsRecording == null)
        {
            lastMuteTick = DateTime.Now;
            MicMute.Tick();
        }
        bool muted = MicMute.Enabled;
        var c = Cur();
        string key, tip;
        Func<Bitmap> make;
        int size = SystemInformation.SmallIconSize.Width;
        if (c != null)
        {
            var db = MicDb(c.Dir);
            int bucket = (int)Math.Clamp((db + 60) / 6, 0, 8);
            key = c.Alive ? $"rec-{bucket}-{muted}" : "dead";
            make = () => c.Alive ? Icons.Glyph(size, Color.FromArgb(0xE5, 0x39, 0x35), db, muted) : Icons.Glyph(size, Color.FromArgb(0xF5, 0x8A, 0x00), null);
            tip = $"MeetRec – {T("recording")} {Elapsed(c.Start)}" + (c.Title != null ? " – " + c.Title : "");
        }
        else if (Processing)
        {
            key = "proc"; make = () => Icons.Glyph(size, null, null);
            tip = "MeetRec – " + T("processing") + ProcessingStep;
        }
        else
        {
            key = $"idle-{muted}"; make = () => Icons.Glyph(size, null, null, muted);
            tip = "MeetRec – " + T("ready");
        }
        key += Icons.DarkTaskbar() ? "-d" : "-l";
        if (key != lastIconKey)
        {
            using var b = make();
            var old = currentIcon;
            currentIcon = Icons.ToIcon(b);
            Tray.Icon = currentIcon;
            Icons.Release(old);
            lastIconKey = key;
        }
        Tray.Text = tip.Length > 127 ? tip[..124] + "…" : tip;
        int want = c?.Alive == true ? 250 : Processing || muted ? 1000 : 2000;
        if (timer.Interval != want || !timer.Enabled) { timer.Interval = want; timer.Start(); }
    }

    public void LoadLists()
    {
        Meet.Run(new[] { "recover", "--json" }, (_, out_) =>
        {
            if (Meet.LastJson(out_) is JsonArray a) Recover = a.OfType<JsonObject>().ToList();
        });
        Meet.Run(new[] { "list", "--json", "--n", "15" }, (_, out_) =>
        {
            if (Meet.LastJson(out_) is JsonArray a) Recent = a.OfType<JsonObject>().ToList();
        });
    }

    // ---------------------------------------------------------------- menu

    static string Short(string s, int max = 48) => s.Length <= max ? s : s[..(max - 1)] + "…";

    ToolStripMenuItem Item(ToolStripItemCollection to, string text, Action? onClick, string keys = "", int max = 48)
    {
        var i = new ToolStripMenuItem(Short(text, max)) { Enabled = onClick != null, ShortcutKeyDisplayString = keys };
        if (i.Text != text) i.ToolTipText = text;
        if (onClick != null) i.Click += (_, _) => onClick();
        to.Add(i);
        return i;
    }

    public void BuildMenu()
    {
        Menu.Items.Clear();
        var m = Menu.Items;
        var c = Cur();
        var hk = hotkey.Display;
        Levels.Prepare(c?.Alive == true);
        levelHost.Size = Levels.Size;
        m.Add(levelHost);
        var mi = new ToolStripMenuItem(T("mute_mic_menu")) { Checked = MicMute.Enabled };
        mi.Click += (_, _) => ToggleMute();
        m.Add(mi);
        m.Add(new ToolStripSeparator());
        if (c != null)
        {
            var head = T("recording_for") + Elapsed(c.Start);
            Item(m, c.Alive ? head + (c.Title != null ? " – " + Short(c.Title, 30) : "") : T("the_recorder_stopped_stop_to_save"), null, max: 80);
            Item(m, T("stop_and_process"), StopAndProcess, hk);
            Item(m, T("stop_without_processing"), StopOnly);
            Item(m, T("stop_and_discard"), StopAndDiscard);
        }
        else
        {
            if (Processing) Item(m, T("processing") + ProcessingStep, null, max: 70);
            Item(m, T("start_recording"), () => StartRecording(null), hk);
            Item(m, T("start_with_title"), StartWithTitle);
        }
        m.Add(new ToolStripSeparator());
        if (LastNote != null)
        {
            var name = Path.GetFileNameWithoutExtension(LastNote);
            var it = Item(m, T("open_last_note") + Short(name, 40), () => Shell.OpenNote(LastNote), max: 80);
            it.ToolTipText = name;
        }
        Item(m, T("import_audio_file"), Processing ? null : ImportAudio);
        Item(m, T("open_recordings_folder"), OpenRecordings);
        if (Recent.Count > 0)
        {
            var sub = Item(m, T("recordings_menu"), null);
            sub.Enabled = true;
            foreach (var r in Recent)
            {
                var when = (r["started_at"]?.GetValue<string>() ?? "").Replace('T', ' ');
                if (when.Length > 16) when = when[..16];
                var it = Item(sub.DropDownItems, $"{when} · {r["title"]?.GetValue<string>() ?? ""}", null, max: 60);
                it.Enabled = true;
                var note = r["note"]?.GetValue<string>() ?? "";
                var dir = r["dir"]?.GetValue<string>() ?? "";
                bool hasAudio = r["has_audio"]?.GetValue<bool>() ?? false;
                Item(it.DropDownItems, T("open_note"), r["note_exists"]?.GetValue<bool>() == true ? () => Shell.OpenNote(note) : null);
                Item(it.DropDownItems, T("edit_audio"), hasAudio && !Processing ? () => Flows.EditAfter(this, dir) : null);
                Item(it.DropDownItems, T("reprocess_with_instructions"), Processing ? null : () => Flows.Reprocess(this, r));
                if (!hasAudio) Item(it.DropDownItems, T("audio_deleted_short"), null);
            }
        }
        if (Recover.Count > 0)
        {
            var sub = Item(m, T("to_process") + $" ({Recover.Count})", null);
            sub.Enabled = true;
            foreach (var r in Recover)
            {
                var dir = r["dir"]?.GetValue<string>() ?? "";
                var it = Item(sub.DropDownItems, $"{r["started_at"]?.GetValue<string>() ?? "?"} [{r["duration"]?.GetValue<string>() ?? ""}] {r["title"]?.GetValue<string>() ?? ""}", null, max: 70);
                it.Enabled = true;
                Item(it.DropDownItems, T("process_now"), Processing ? null : () => Flows.ChooseEventThenProcess(this, dir));
                Item(it.DropDownItems, T("edit_audio"), Processing ? null : () => Flows.EditBefore(this, dir));
                Item(it.DropDownItems, T("delete_recording"), () => Flows.DiscardDir(this, dir));
            }
        }
        m.Add(new ToolStripSeparator());
        Item(m, T("settings"), () => SettingsHook?.Invoke());
        Item(m, T("setup_menu"), () => SetupHook?.Invoke());
        Item(m, "Log", () => { Log.Append(""); Shell.Open(Paths.AppLog); });
        Item(m, "MeetRec " + Program.Version, null);
        Item(m, T("quit_meetrec"), Quit);
        LoadLists();
    }

    public Action? SettingsHook, SetupHook;

    public void ToggleMute()
    {
        MicMute.Enabled = !MicMute.Enabled;
        MicMute.Tick();
        lastIconKey = "";
        Refresh();
    }

    // ---------------------------------------------------------------- actions

    string? balloonNote;

    public void Notify(string title, string body, string? note = null)
    {
        balloonNote = note;
        Tray.ShowBalloonTip(5000, title, body.Length > 0 ? body : " ", ToolTipIcon.None);
    }

    bool ConsentAcknowledged()
    {
        if (AppState.Load()["consentAcknowledged"]?.GetValue<bool>() == true) return true;
        if (new Alert(T("consent_title"), T("consent_text_win")).Buttons(true, T("consent_ok"), T("cancel")).Run() != 0) return false;
        AppState.Set("consentAcknowledged", true);
        return true;
    }

    public void StartRecording(string? title, IEnumerable<string>? extra = null)
    {
        CallPrompt.Hide_();
        if (!ConsentAcknowledged()) return;
        var args = new List<string> { "start" };
        if (title != null) args.AddRange(new[] { "-t", title });
        if (extra != null) args.AddRange(extra);
        Meet.Run(args, (status, out_) =>
        {
            Refresh();
            if (status != 0)
            {
                var tail = out_.Length > 800 ? out_[^800..] : out_;
                if (new Alert(T("recording_did_not_start"), tail + "\n\n" + T("win_start_failed_hint"))
                        .Buttons(true, "OK", T("open_privacy")).Run() == 1)
                    Shell.Open("ms-settings:privacy-microphone");
            }
        });
    }

    void StartWithTitle()
    {
        var cfg = Config.Load();
        var f = Grid.Text(placeholder: T("leave_empty_to_use_the_calendar_event"));
        var rec = Grid.Combo(new[] { ("both", T("record_both")), ("mine", T("record_mine")) },
                             (cfg["record_system"]?.GetValue<bool>() ?? true) ? "both" : "mine");
        var tr = Grid.Combo(new[] { ("separate", T("transcript_separate")), ("mixed", T("transcript_mixed")) },
                            cfg["transcript_mode"]?.GetValue<string>() ?? "separate");
        var vp = Grid.Combo(Program.VoiceProfiles.Select(v => (v.tag, T(v.key))), cfg["voice_profile"]?.GetValue<string>() ?? "none");
        var grid = Grid.Of((T("manual_title"), f), (T("what_to_record"), rec), (T("transcript_kind"), tr), (T("voice_profile"), vp));
        if (new Alert(T("start_options_title"), "", grid).Buttons(true, T("record"), T("cancel")).Run(f) != 0) return;
        var t = f.Text.Trim();
        var extra = new List<string> { Grid.Selected(rec) == "mine" ? "--mic-only" : "--with-system",
                                       "--transcript", Grid.Selected(tr), "--voice-profile", Grid.Selected(vp) };
        StartRecording(t.Length == 0 ? null : t, extra);
    }

    void ImportAudio()
    {
        using var d = new OpenFileDialog
        {
            Title = T("import_panel_message"),
            Filter = "Audio|*.mp3;*.wav;*.m4a;*.aac;*.ogg;*.opus;*.flac;*.wma;*.mp4;*.webm|*.*|*.*",
        };
        if (d.ShowDialog() == DialogResult.OK) ImportFile(d.FileName);
    }

    public void ImportFile(string path)
    {
        if (Processing) { Notify("MeetRec", T("import_busy")); return; }
        var f = Grid.Text(width: 360);
        if (new Alert(T("import_title", ("file", Path.GetFileName(path))), T("import_title_info"), f)
                .Buttons(true, T("import_button"), T("cancel")).Run(f) != 0) return;
        var t = f.Text.Trim();
        Processing = true; ProcessingStep = T("import_copying"); Refresh();
        var args = new List<string> { "import", path, "--no-process" };
        if (t.Length > 0) args.AddRange(new[] { "-t", t });
        Meet.Run(args, (status, out_) =>
        {
            Processing = false;
            var d = Meet.DirFrom(out_, "recording folder -> ");
            if (status == 0 && d != null) Flows.ChooseEventThenProcess(this, d);
            else Notify(T("processing_failed"), Meet.LastLine(out_));
            Refresh();
        });
    }

    public void StopAndProcess()
    {
        Meet.Run(new[] { "stop", "--no-process" }, (_, out_) =>
        {
            Refresh();
            var d = Meet.DirFrom(out_, "-> ");
            if (d != null) Flows.ChooseEventThenProcess(this, d);
        });
    }

    void StopOnly() => Meet.Run(new[] { "stop", "--no-process" }, (_, _) => { Refresh(); LoadLists(); });

    void StopAndDiscard()
    {
        var c = Cur();
        if (c == null || !Flows.ConfirmDiscard(T("discard_current", ("time", Elapsed(c.Start))))) return;
        Meet.Run(new[] { "stop", "--discard" }, (status, out_) =>
        {
            Refresh(); LoadLists();
            Notify("MeetRec", status == 0 ? T("recording_discarded") : Meet.LastLine(out_));
        });
    }

    void OpenRecordings()
    {
        var dir = Config.Str("recordings_dir", Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Recordings", "meetings"));
        Directory.CreateDirectory(dir);
        Shell.Open(dir);
    }

    void HotKeyPressed()
    {
        if (Cur()?.Alive == true) { Notify("MeetRec", T("hotkey_stopping")); StopAndProcess(); }
        else if (Processing) Notify("MeetRec", T("hotkey_busy"));
        else
        {
            bool known = AppState.Load()["consentAcknowledged"]?.GetValue<bool>() == true;
            StartRecording(null);
            if (known) Notify("MeetRec", T("hotkey_started_win", ("keys", hotkey.Display)));
        }
    }

    /// processing with progress in the tooltip and the menu; the note is announced when done
    public void RunPipeline(List<string> args)
    {
        Processing = true; ProcessingStep = T("starting"); Refresh();
        string? note = null;
        Meet.Run(args, (status, out_) =>
        {
            Processing = false;
            Refresh(); LoadLists();
            if (status == 0 && note != null)
            {
                LastNote = note;
                AppState.Set("lastNote", note);
                Notify(T("meeting_saved"), Path.GetFileName(note), note);
                if (args[0] == "process" && args.Count > 1) Flows.AfterProcess(this, args[1]);
            }
            else Notify(T("processing_failed"), T("the_audio_is_safe_details_in_log"));
        }, line =>
        {
            var l = line.Replace("[meet] ", "");
            if (l.StartsWith("note: ")) note = l[6..].Trim();
            if (!l.StartsWith(" ")) { ProcessingStep = l; Refresh(); }
        });
    }

    void Quit()
    {
        if (Cur()?.Alive == true &&
            new Alert(T("a_recording_is_in_progress"), T("if_you_quit_the_recording_keeps_going")).Buttons(true, T("quit"), T("cancel")).Run() != 0)
            return;
        ExitThread();
    }

    protected override void ExitThreadCore()
    {
        BeforeExit?.Invoke();
        MicMute.RestoreAll();                 // never leave the mic muted without the app
        hotkey.Dispose();
        Tray.Visible = false;
        Tray.Dispose();
        base.ExitThreadCore();
    }

    public Action? BeforeExit;
}

/// global shortcut Ctrl+Alt+Win+R (Ctrl+Alt+Shift+R if taken): start, or stop and process, from any app
sealed class HotKeyWindow : NativeWindow, IDisposable
{
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    const uint MOD_ALT = 1, MOD_CONTROL = 2, MOD_SHIFT = 4, MOD_WIN = 8, MOD_NOREPEAT = 0x4000;
    readonly Action onPress;
    public string Display = "";

    public HotKeyWindow(Action onPress)
    {
        this.onPress = onPress;
        CreateHandle(new CreateParams());
        if (RegisterHotKey(Handle, 1, MOD_CONTROL | MOD_ALT | MOD_WIN | MOD_NOREPEAT, (uint)Keys.R)) Display = "Ctrl+Alt+Win+R";
        else if (RegisterHotKey(Handle, 1, MOD_CONTROL | MOD_ALT | MOD_SHIFT | MOD_NOREPEAT, (uint)Keys.R)) Display = "Ctrl+Alt+Shift+R";
        Log.Append($"[app] global shortcut: {(Display.Length > 0 ? Display : "none (taken by another app)")}\n");
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == 0x0312) onPress();               // WM_HOTKEY
        base.WndProc(ref m);
    }

    public void Dispose()
    {
        UnregisterHotKey(Handle, 1);
        DestroyHandle();
    }
}
