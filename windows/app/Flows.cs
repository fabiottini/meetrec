// After a recording: which calendar event was it (or a manual one), optional instructions for Claude
// and audio review, processing, then "keep the audio?". Same steps as the macOS app.

using System.Globalization;
using System.Text.Json.Nodes;
using static MeetRec.L;

namespace MeetRec;

static class Flows
{
    public static bool ConfirmDiscard(string what) =>
        new Alert(T("discard_confirm_title"), T("discard_confirm_info", ("what", what)))
            .Buttons(true, T("delete_button"), T("cancel")).Run() == 0;

    public static void DiscardDir(TrayApp app, string dir)
    {
        if (!ConfirmDiscard(Path.GetFileName(dir))) return;
        Meet.Run(new[] { "discard", dir }, (status, out_) =>
        {
            app.LoadLists();
            app.Notify("MeetRec", status == 0 ? T("recording_discarded") : Meet.LastLine(out_));
        });
    }

    public static void ChooseEventThenProcess(TrayApp app, string dir)
    {
        app.Processing = true; app.ProcessingStep = T("cal_looking"); app.Refresh();
        Meet.Run(new[] { "candidates", dir, "--json" }, (_, out_) =>
        {
            app.Processing = false; app.Refresh();
            var cands = (Meet.LastJson(out_) as JsonArray)?.OfType<JsonObject>().ToList() ?? new();
            var r = AskEvent(cands);
            if (r == null)
            {
                app.Notify("MeetRec", T("cal_saved_for_later"));
                app.LoadLists();
                return;
            }
            var (choice, instructions, review) = r.Value;
            if (choice == -1) { AskManualEvent(app, dir, instructions, review); return; }
            Meet.Run(new[] { "choose", dir, choice == 0 ? "none" : choice.ToString() },
                     (_, _) => ContinueToTranscript(app, dir, instructions, review));
        });
    }

    /// the "which meeting?" dialog. null = decide later; choice: n = candidate n, 0 = none, -1 = write it myself
    public static (int choice, string instructions, bool review)? AskEvent(List<JsonObject> cands)
    {
        var a = EventForm(cands, out var collect);
        return a.Run() == 0 ? collect() : null;
    }

    public static Alert EventForm(List<JsonObject> cands, out Func<(int, string, bool)> collect)
    {
        var panel = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false, Margin = Padding.Empty };
        var radios = new List<(RadioButton rb, int tag)>();
        for (int i = 0; i < cands.Count; i++)
            radios.Add((new RadioButton { Text = cands[i]["label"]?.GetValue<string>() ?? "?", AutoSize = true, MaximumSize = new Size(500, 0) }, i + 1));
        radios.Add((new RadioButton { Text = T("cal_write_myself"), AutoSize = true }, -1));
        radios.Add((new RadioButton { Text = cands.Count == 0 ? T("cal_no_event") : T("cal_none_of_these"), AutoSize = true }, 0));
        foreach (var (rb, _) in radios) panel.Controls.Add(rb);
        radios[0].rb.Checked = true;
        var instrLabel = new Label { Text = T("instructions_label"), AutoSize = true, MaximumSize = new Size(500, 0), Margin = new Padding(3, 14, 3, 3) };
        var instr = Grid.Text(placeholder: T("instructions_placeholder"), width: 500);
        var review = new CheckBox { Text = T("review_audio_first"), AutoSize = true, Enabled = AudioEditor.Available };
        panel.Controls.Add(instrLabel); panel.Controls.Add(instr); panel.Controls.Add(review);
        var a = new Alert(cands.Count == 0 ? T("cal_no_event_found") : T("cal_which_meeting"),
                          cands.Count == 0 ? T("cal_no_event_info") : T("cal_which_meeting_info"), panel, 500)
            .Buttons(true, T("cal_use_this"), T("cal_decide_later"));
        collect = () => (radios.First(r => r.rb.Checked).tag, instr.Text.Trim(), review.Checked);
        return a;
    }

    public static Alert ManualEventForm(JsonObject meta, out Func<List<string>?> collect)
    {
        var start = TryDate(meta["started_at"]) ?? DateTime.Now;
        var end = TryDate(meta["stopped_at"]) ?? start.AddMinutes(30);
        var title = Grid.Text(meta["title"]?.GetValue<string>() ?? "", T("manual_title_placeholder"));
        var day = new DateTimePicker { Format = DateTimePickerFormat.Short, Value = start.Date, Width = 130 };
        DateTimePicker Time(DateTime v) => new() { Format = DateTimePickerFormat.Custom, CustomFormat = "HH:mm", ShowUpDown = true, Value = v, Width = 80 };
        var t1 = Time(start); var t2 = Time(end);
        var times = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = Padding.Empty };
        times.Controls.Add(t1); times.Controls.Add(new Label { Text = "–", AutoSize = true, Margin = new Padding(4, 6, 4, 0) }); times.Controls.Add(t2);
        var people = Grid.Text(placeholder: T("manual_people_placeholder"));
        var agenda = Grid.Text(placeholder: T("manual_agenda_placeholder"));
        var grid = Grid.Of((T("manual_title"), title), (T("manual_day"), day), (T("manual_time"), times),
                           (T("manual_people"), people), (T("manual_agenda"), agenda));
        var a = new Alert(T("manual_header"), T("manual_info"), grid).Buttons(true, T("manual_save"), T("cal_decide_later"));
        a.Check = i => i != 0 || title.Text.Trim().Length > 0 || Beep();          // the title is required
        collect = () =>
        {
            var s1 = day.Value.Date + t1.Value.TimeOfDay;
            var s2 = day.Value.Date + t2.Value.TimeOfDay;
            if (s2 <= s1) s2 = s1.AddMinutes(30);
            var args = new List<string> { "manual", "--title", title.Text.Trim(), "--start", Iso(s1), "--end", Iso(s2) };
            if (people.Text.Trim().Length > 0) args.AddRange(new[] { "--people", people.Text.Trim() });
            if (agenda.Text.Trim().Length > 0) args.AddRange(new[] { "--agenda", agenda.Text.Trim() });
            return args;
        };
        a.Shown += (_, _) => title.Focus();
        return a;
    }

    static bool Beep() { System.Media.SystemSounds.Beep.Play(); return false; }

    static DateTime? TryDate(JsonNode? n)
    {
        try { return n == null ? null : DateTimeOffset.Parse(n.GetValue<string>(), CultureInfo.InvariantCulture).LocalDateTime; }
        catch { return null; }
    }

    static string Iso(DateTime local) => new DateTimeOffset(local).ToString("yyyy-MM-dd'T'HH:mm:sszzz", CultureInfo.InvariantCulture);

    static JsonObject Meta(string dir)
    {
        try { return JsonNode.Parse(File.ReadAllText(Path.Combine(dir, "meta.json")))!.AsObject(); } catch { return new(); }
    }

    public static void AskManualEvent(TrayApp app, string dir, string instructions, bool review)
    {
        var a = ManualEventForm(Meta(dir), out var collect);
        if (a.Run() != 0)
        {
            app.Notify("MeetRec", T("cal_saved_for_later"));
            app.LoadLists();
            return;
        }
        var args = new List<string> { "choose", dir };
        args.AddRange(collect()!);
        Meet.Run(args, (_, _) => ContinueToTranscript(app, dir, instructions, review));
    }

    static List<string> ProcessArgs(string dir, string instructions)
    {
        var l = new List<string> { "process", dir };
        if (instructions.Length > 0) l.AddRange(new[] { "--instructions", instructions });
        return l;
    }

    public static void ContinueToTranscript(TrayApp app, string dir, string instructions, bool review)
    {
        if (!review) { app.RunPipeline(ProcessArgs(dir, instructions)); return; }
        OpenEditor(app, dir, applied =>
        {
            if (applied) app.RunPipeline(ProcessArgs(dir, instructions));
            else { app.Notify("MeetRec", T("cal_saved_for_later")); app.LoadLists(); }
        });
    }

    /// encode the raw audio, open the editor, apply the cuts; done(true) when there is something to transcribe
    public static void OpenEditor(TrayApp app, string dir, Action<bool> done)
    {
        app.Processing = true; app.ProcessingStep = T("editor_preparing"); app.Refresh();
        Meet.Run(new[] { "prepare", dir }, (status, out_) =>
        {
            app.Processing = false; app.Refresh();
            if (status != 0) { app.Notify(T("processing_failed"), Meet.LastLine(out_)); done(false); return; }
            var cuts = AudioEditor.Open(dir);
            if (cuts == null) { done(false); return; }
            if (cuts.Count == 0) { done(true); return; }
            Meet.Run(new[] { "cut", dir, AudioEditor.Ranges(cuts) }, (st, o) =>
            {
                if (st != 0) app.Notify(T("processing_failed"), Meet.LastLine(o));
                done(st == 0);
            });
        });
    }

    /// a recording still to process: cut first, then choose the event and process
    public static void EditBefore(TrayApp app, string dir) =>
        OpenEditor(app, dir, applied => { if (applied) ChooseEventThenProcess(app, dir); else app.LoadLists(); });

    /// a processed recording: cut parts; transcript and note follow (no new transcription)
    public static void EditAfter(TrayApp app, string dir)
    {
        var cuts = AudioEditor.Open(dir);
        if (cuts == null || cuts.Count == 0) return;
        app.RunPipeline(new List<string> { "edit", dir, AudioEditor.Ranges(cuts) });
    }

    public static void Reprocess(TrayApp app, JsonObject r)
    {
        var dir = r["dir"]?.GetValue<string>() ?? "";
        var f = Grid.Text(r["instructions"]?.GetValue<string>() ?? "", T("instructions_placeholder"), 440);
        if (new Alert(T("reprocess_title"), T("reprocess_info"), f).Buttons(true, T("reprocess_button"), T("cancel")).Run(f) != 0) return;
        app.RunPipeline(ProcessArgs(dir, f.Text.Trim()));
    }

    /// "keep the audio?" after a transcript: asked only when meet verify confirms note + transcript
    public static void AfterProcess(TrayApp app, string dir)
    {
        if (Meta(dir)["audio_deleted_at"] != null) return;
        if (Config.Str("after_process_audio", "ask") != "ask") return;
        Meet.Run(new[] { "verify", dir }, (status, out_) =>
        {
            var why = Meet.LastLine(out_);
            if (status != 0) { app.Notify(T("audio_kept_title"), why.Replace("NOT OK: ", "")); return; }
            if (new Alert(T("keep_audio_title"), T("keep_audio_info", ("check", why.Replace("OK: ", ""))))
                    .Buttons(false, T("keep_audio"), T("delete_audio")).Run() == 1)
                Meet.Run(new[] { "drop-audio", dir }, (st, o) =>
                    app.Notify("MeetRec", st == 0 ? T("audio_deleted_done") : Meet.LastLine(o)));
        });
    }
}
