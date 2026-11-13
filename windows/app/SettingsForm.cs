// Settings window: the same options as the macOS app, saved in %APPDATA%\MeetRec\config.json.

using System.Text.Json.Nodes;
using Microsoft.Win32;
using static MeetRec.L;

namespace MeetRec;

sealed class SettingsForm : Form
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    readonly JsonObject raw = Config.Load();
    readonly TableLayoutPanel grid = new() { ColumnCount = 2, AutoSize = true, Padding = new Padding(16, 10, 16, 10) };
    readonly Label saved = new() { AutoSize = true, ForeColor = SystemColors.GrayText, Margin = new Padding(0, 8, 10, 0) };
    readonly Action? openSetup;

    TextBox recordingsDir = null!, vault = null!, meetingsDir = null!, peopleDir = null!, context = null!;
    ComboBox ui = null!, mic = null!, lang = null!, record = null!, transcript = null!, voice = null!, scope = null!, after = null!;
    CheckBox keepRaw = null!, keepTracks = null!, callPrompt = null!, summary = null!, atLogin = null!;
    Label account = null!;

    static string S(JsonObject o, string k, string d) { try { return o[k]?.GetValue<string>() ?? d; } catch { return d; } }
    static bool B(JsonObject o, string k, bool d) { try { return o[k]?.GetValue<bool>() ?? d; } catch { return d; } }

    public SettingsForm(Action? openSetup = null, bool load = true)
    {
        this.openSetup = openSetup;
        Text = "MeetRec – " + T("settings_2");
        Icon = Icons.App;
        Font = SystemFonts.MessageBoxFont;
        StartPosition = FormStartPosition.CenterScreen;
        AutoScroll = true;
        FormBorderStyle = FormBorderStyle.Sizable;
        MaximizeBox = false;
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        Build();
        Controls.Add(grid);
        Shown += (_, _) => FitToScreen();
        if (load) { LoadMics(); LoadAccount(); }
    }

    void FitToScreen()
    {
        var pref = grid.GetPreferredSize(Size.Empty);
        var area = Screen.FromControl(this).WorkingArea;
        ClientSize = new Size(pref.Width + SystemInformation.VerticalScrollBarWidth + 4, Math.Min(pref.Height, area.Height - 80));
        CenterToScreen();
    }

    void Section(string title)
    {
        var l = new Label { Text = title, AutoSize = true, Font = new Font(Font, FontStyle.Bold), Margin = new Padding(0, 14, 0, 4) };
        grid.Controls.Add(l);
        grid.SetColumnSpan(l, 2);
    }

    C Row<C>(string label, C c) where C : Control
    {
        grid.Controls.Add(new Label { Text = label, AutoSize = true, Anchor = AnchorStyles.Right, Margin = new Padding(0, 6, 8, 4) });
        c.Margin = new Padding(0, 3, 0, 3);
        grid.Controls.Add(c);
        return c;
    }

    CheckBox Check(string label, bool value)
    {
        var c = new CheckBox { Text = label, Checked = value, AutoSize = true, MaximumSize = new Size(520, 0) };
        grid.Controls.Add(new Label());
        grid.Controls.Add(c);
        return c;
    }

    Control PathRow(string label, string value, out TextBox box)
    {
        var p = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = Padding.Empty };
        var t = new TextBox { Text = value, Width = 300 };
        var b = new Button { Text = T("choose"), AutoSize = true };
        b.Click += (_, _) =>
        {
            using var d = new FolderBrowserDialog { SelectedPath = t.Text, ShowNewFolderButton = true };
            if (d.ShowDialog(this) == DialogResult.OK) t.Text = d.SelectedPath;
        };
        p.Controls.Add(t); p.Controls.Add(b);
        box = t;
        return Row(label, p);
    }

    void Build()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        Section(T("interface"));
        ui = Row(T("menu_and_messages_language"), Grid.Combo(I18n.Available().Select(a => (a.code, a.name)), I18n.Lang, 220));
        var tr = Row("", new Button { Text = T("open_translations_folder"), AutoSize = true });
        tr.Click += (_, _) =>
        {
            var d = Path.Combine(Paths.ConfDir, "locales");
            Directory.CreateDirectory(d);
            Shell.Open(d);
        };

        Section(T("recordings"));
        PathRow(T("audio_folder"), S(raw, "recordings_dir", Path.Combine(home, "Recordings", "meetings")), out recordingsDir);
        mic = Row(T("microphone"), Grid.Combo(new[] { ("", T("system_default")) }, "", 330));
        lang = Row(T("meeting_language_transcription"), Grid.Combo(new[] { ("it", "Italiano"), ("en", "English") }, S(raw, "language", "it"), 220));
        keepRaw = Check(T("also_keep_raw_audio_much_more_space"), B(raw, "keep_raw", false));
        keepTracks = Check(T("keep_separate_tracks"), B(raw, "keep_tracks", false));
        callPrompt = Check(T("call_prompt_setting"), B(raw, "call_prompt", true));

        Section(T("audio_section"));
        record = Row(T("what_to_record"), Grid.Combo(new[] { ("both", T("record_both")), ("mine", T("record_mine")) },
                                                     B(raw, "record_system", true) ? "both" : "mine"));
        transcript = Row(T("transcript_kind"), Grid.Combo(new[] { ("separate", T("transcript_separate")), ("mixed", T("transcript_mixed")) },
                                                          S(raw, "transcript_mode", "separate")));
        voice = Row(T("voice_profile"), Grid.Combo(Program.VoiceProfiles.Select(v => (v.tag, T(v.key))), S(raw, "voice_profile", "none")));
        scope = Row(T("voice_scope"), Grid.Combo(new[] { ("mine", T("voice_scope_mine")), ("all", T("voice_scope_all")) },
                                                 S(raw, "voice_profile_scope", "mine")));
        var vt = Row("", new Button { Text = T("voice_test"), AutoSize = true });
        vt.Click += (_, _) =>
        {
            var p = Grid.Selected(voice);
            if (p == "none") return;
            Meet.Run(new[] { "voice-test", p }, (_, _) => { });
        };
        void VoiceVisible() { scope.Enabled = vt.Enabled = Grid.Selected(voice) != "none"; }
        voice.SelectedIndexChanged += (_, _) => VoiceVisible();
        VoiceVisible();
        after = Row(T("after_audio"), Grid.Combo(new[] { ("ask", T("after_audio_ask")), ("keep", T("after_audio_keep")), ("delete", T("after_audio_delete")) },
                                                 S(raw, "after_process_audio", "ask")));

        Section("Obsidian");
        PathRow(T("setup_vault"), S(raw, "vault", ""), out vault);
        meetingsDir = Row(T("meetings_folder_relative_to_vault"), new TextBox { Text = S(raw, "meetings_dir", ""), Width = 300 });
        peopleDir = Row(T("people_folder_relative_to_vault"), new TextBox { Text = S(raw, "people_dir", ""), Width = 300 });
        context = Row(T("frontmatter_context"), new TextBox { Text = S(raw, "context", "work"), Width = 160 });
        summary = Check(T("automatic_summary_with_claude_text_only"), B(raw, "summary", true));

        Section(T("cal_title"));
        account = Row("", new Label { Text = "…", AutoSize = true, MaximumSize = new Size(420, 0) });
        var manage = Row("", new Button { Text = T("cal_manage"), AutoSize = true });
        manage.Click += (_, _) => openSetup?.Invoke();

        Section(T("system"));
        atLogin = Check(T("open_meetrec_at_login"), LaunchAtLogin());
        atLogin.CheckedChanged += (_, _) => SetLaunchAtLogin(atLogin.Checked);
        var priv = Row("", new Button { Text = T("microphone_permission"), AutoSize = true });
        priv.Click += (_, _) => Shell.Open("ms-settings:privacy-microphone");

        var bottom = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, AutoSize = true, Dock = DockStyle.Fill, Margin = new Padding(0, 14, 0, 0) };
        var save = new Button { Text = T("save"), AutoSize = true, MinimumSize = new Size(90, 0) };
        save.Click += (_, _) => Save();
        AcceptButton = save;
        bottom.Controls.Add(save);
        bottom.Controls.Add(saved);
        grid.Controls.Add(bottom);
        grid.SetColumnSpan(bottom, 2);
    }

    void LoadMics()
    {
        var current = S(raw, "mic_id", "");
        Meet.Run(new[] { "mics" }, (_, out_) =>
        {
            if (IsDisposed) return;
            var items = new List<(string, string)> { ("", T("system_default")) };
            foreach (var line in out_.Split('\n'))
            {
                if (line.Length < 3) continue;
                var parts = line[2..].Split('\t');
                if (parts.Length == 2) items.Add((parts[1].Trim(), parts[0].Trim()));
            }
            var fresh = Grid.Combo(items, current, 330);
            mic.Items.Clear();
            foreach (var o in fresh.Items) mic.Items.Add(o);
            mic.Tag = fresh.Tag;
            mic.SelectedIndex = fresh.SelectedIndex;
        });
    }

    void LoadAccount()
    {
        Meet.Run(new[] { "whoami" }, (_, out_) => { if (!IsDisposed) account.Text = out_.Trim().Length > 0 ? out_.Trim() : T("cal_none"); });
    }

    void Save()
    {
        raw["recordings_dir"] = recordingsDir.Text.Trim();
        raw["vault"] = vault.Text.Trim();
        raw["meetings_dir"] = meetingsDir.Text.Trim();
        raw["people_dir"] = peopleDir.Text.Trim();
        raw["context"] = context.Text.Trim();
        raw["language"] = Grid.Selected(lang);
        raw["ui_language"] = Grid.Selected(ui);
        var m = Grid.Selected(mic);
        raw["mic_id"] = m.Length == 0 ? null : m;
        raw["summary"] = summary.Checked;
        raw["keep_raw"] = keepRaw.Checked;
        raw["keep_tracks"] = keepTracks.Checked;
        raw["call_prompt"] = callPrompt.Checked;
        raw["record_system"] = Grid.Selected(record) == "both";
        raw["transcript_mode"] = Grid.Selected(transcript);
        raw["voice_profile"] = Grid.Selected(voice);
        raw["voice_profile_scope"] = Grid.Selected(scope);
        raw["after_process_audio"] = Grid.Selected(after);
        Config.Save(raw);
        if (I18n.Lang != Grid.Selected(ui)) { I18n.Lang = Grid.Selected(ui); I18n.Reload(); }
        saved.Text = T("saved");
    }

    public static bool LaunchAtLogin()
    {
        using var k = Registry.CurrentUser.OpenSubKey(RunKey);
        return k?.GetValue("MeetRec") is string;
    }

    public static void SetLaunchAtLogin(bool on)
    {
        using var k = Registry.CurrentUser.CreateSubKey(RunKey);
        if (on) k.SetValue("MeetRec", $"\"{Environment.ProcessPath}\"");
        else k.DeleteValue("MeetRec", false);
    }
}
