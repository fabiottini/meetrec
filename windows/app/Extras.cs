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

    static partial void AttachMore(TrayApp app)
    {
        app.SettingsHook = OpenSettings;
        app.SetupHook = OpenSetup;
        // first run, or something required went missing: open the setup by itself
        using var probe = new SetupForm(load: false);
        if (probe.RequiredMissing) OpenSetup();
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
    }

    static partial void MoreDocs(List<(string, Func<Form>)> list)
    {
        list.Add(("settings", () => new SettingsForm(load: false)));
        list.Add(("setup", () => new SetupForm(load: false)));
        list.Add(("guide-microsoft", () => Guides.Microsoft(null, _ => { }, show: false)));
    }
}
