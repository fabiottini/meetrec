// Wiring of the windows that live in their own files: settings, setup, guides.

namespace MeetRec;

static partial class Extras
{
    static SettingsForm? settings;
    static SetupForm? setup;

    public static void OpenSetup()
    {
        if (setup == null || setup.IsDisposed) { setup = new SetupForm(); setup.FormClosed += (_, _) => setup = null; setup.Show(); }
        else setup.Refresh_();
        setup.Activate();
    }

    public static void OpenSettings()
    {
        if (settings == null || settings.IsDisposed)
        {
            settings = new SettingsForm(OpenSetup);
            settings.FormClosed += (_, _) => settings = null;
            settings.Show();
        }
        settings.Activate();
    }

    static readonly CallWatcher calls = new();

    static partial void AttachMore(TrayApp app)
    {
        app.SettingsHook = OpenSettings;
        app.SetupHook = OpenSetup;
        StartCallWatcher(app);
        // first run, or something required went missing: open the setup by itself
        using var probe = new SetupForm(load: false);
        if (probe.RequiredMissing) OpenSetup();
    }

    static void StartCallWatcher(TrayApp app)
    {
        bool Enabled() => Config.Bool("call_prompt", true);
        calls.OnCallStart = appName =>
        {
            var why = !Enabled() ? "prompt off in Settings" : app.Cur()?.Alive == true ? "already recording"
                    : app.Processing ? "processing a recording" : "";
            Log.Append($"[app] call detected: microphone used by {appName}" + (why.Length == 0 ? ", prompt shown" : $", no prompt: {why}") + "\n");
            if (why.Length > 0) return;
            void Show(string ev) => CallPrompt.Show(L.T("call_detected", ("app", appName)), ev.Length == 0 ? L.T("call_detected_sub") : ev,
                                                    L.T("record"), L.T("ignore"), () => app.StartRecording(null));
            Show("");
            Meet.Run(new[] { "now", "--json" }, (_, out_) =>   // add the meeting title when a calendar has it
            {
                if (Meet.LastJson(out_) is System.Text.Json.Nodes.JsonArray a && a.FirstOrDefault()?["subject"]?.GetValue<string>() is string subj
                    && app.Cur()?.Alive != true && calls.InCall)
                    Show(subj);
            });
        };
        calls.OnCallEnd = appName =>
        {
            Log.Append($"[app] call ended: {appName} released the microphone\n");
            if (!Enabled() || app.Cur()?.Alive != true) return;
            CallPrompt.Show(L.T("call_ended", ("app", appName)), L.T("call_ended_sub"), L.T("stop_and_process"), L.T("keep_recording"), app.StopAndProcess);
        };
        calls.Start();
    }

    static partial void SelfTestParts(Action<string, bool, string> check)
    {
        using (var s = new SettingsForm(load: false)) { s.CreateControl(); check("settings window", true, ""); }
        using var setupForm = new SetupForm(load: false);
        setupForm.CreateControl();
        var c = setupForm.ComputeChecks();
        check("setup checks", c.Count >= 8 && c.First(x => x.Id == "python").Ok,
              string.Join(", ", c.Select(x => $"{x.Id}={(x.Ok ? "ok" : "missing")}")));
        using (var g = Guides.Google(null, _ => { }, show: false)) check("google guide", true, "");
        using (var m = Guides.Microsoft(null, _ => { }, show: false)) check("microsoft guide", true, "");
        using (var p = CallPrompt.Demo()) { p.CreateControl(); check("call prompt", true, ""); }
        using (var ed = EditorForm.Demo()) { ed.CreateControl(); check("audio editor", true, ""); }
        var users = CallWatcher.MicUsers();
        check("mic users (privacy records)", true, users.Count == 0 ? "nobody" : string.Join(", ", users));
    }

    static partial void MoreDocs(List<(string, Func<Form>)> list)
    {
        list.Add(("settings", () => new SettingsForm(load: false)));
        list.Add(("settings-ai", () =>
        {
            var f = new SettingsForm(load: false);
            f.Shown += (_, _) => f.AutoScrollPosition = new Point(0, 100000);    // the AI section, at the bottom
            return f;
        }));
        list.Add(("setup", () => new SetupForm(load: false)));
        list.Add(("guide-microsoft", () => Guides.Microsoft(null, _ => { }, show: false)));
        list.Add(("call-prompt", CallPrompt.Demo));
        list.Add(("editor", EditorForm.Demo));
    }
}
