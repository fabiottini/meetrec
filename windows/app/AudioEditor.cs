// Audio editor: look at the whole recording, select parts by dragging, listen to them, cut them,
// then transcribe. The cuts are applied by `meet cut` to every track (verified durations).
// Same as menubar/AudioEditor.swift; playback with Media Foundation + WASAPI (ffmpeg to WAV as a fallback).

using System.Globalization;
using System.Text.Json.Nodes;
using NAudio.Wave;
using static MeetRec.L;

namespace MeetRec;

static class AudioEditor
{
    public static bool Available => true;

    /// modal; null = cancelled, otherwise the parts to cut, in seconds
    public static List<(double start, double end)>? Open(string dir)
    {
        using var f = new EditorForm(dir);
        f.ShowDialog();
        return f.Result;
    }

    public static string Ranges(List<(double start, double end)> cuts) =>
        string.Join(",", cuts.Select(c => string.Format(CultureInfo.InvariantCulture, "{0:F2}-{1:F2}", c.start, c.end)));

    public static string HmsShort(double t)
    {
        var s = (int)t;
        return s >= 3600 ? $"{s / 3600}:{s % 3600 / 60:00}:{s % 60:00}" : $"{s / 60}:{s % 60:00}";
    }

    public static string HmsTenths(double t)
    {
        var s = (int)t;
        return (s >= 3600 ? $"{s / 3600}:{s % 3600 / 60:00}:" : $"{s / 60}:") + (t % 60).ToString("00.0", CultureInfo.InvariantCulture);
    }
}

sealed class WaveView : Control
{
    public double[] Peaks = Array.Empty<double>();
    public double Duration = 1;
    public (double a, double b)? Selection;
    public readonly List<(double a, double b)> Cuts = new();
    public double? Playhead;
    public Action? OnSelection;
    double? dragStart;

    public WaveView() { DoubleBuffered = true; Cursor = Cursors.IBeam; }

    public double TimeAt(int x) => Math.Clamp(x / (double)Math.Max(1, Width) * Duration, 0, Duration);
    public float XAt(double t) => (float)(t / Math.Max(Duration, 0.001) * Width);

    protected override void OnMouseDown(MouseEventArgs e)
    {
        var t = TimeAt(e.X);
        dragStart = t;
        Selection = (t, t);
        Invalidate(); OnSelection?.Invoke();
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (dragStart is not double s || e.Button != MouseButtons.Left) return;
        var t = TimeAt(e.X);
        Selection = (Math.Min(s, t), Math.Max(s, t));
        Invalidate(); OnSelection?.Invoke();
        // keep the drag visible when it leaves the visible part (autoscroll)
        if (Parent is ScrollableControl p)
        {
            var vis = -p.AutoScrollPosition.X;
            if (e.X > vis + p.ClientSize.Width - 10) p.AutoScrollPosition = new Point(e.X - p.ClientSize.Width + 20, 0);
            else if (e.X < vis + 10) p.AutoScrollPosition = new Point(Math.Max(0, e.X - 20), 0);
        }
    }

    protected override void OnMouseUp(MouseEventArgs e) => dragStart = null;

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(Color.FromArgb(31, 31, 31));
        // time grid: a line every minute (every 10 s when zoomed in enough)
        double step = Width / Math.Max(Duration, 1) > 6 ? 10 : 60;
        using var grid = new SolidBrush(Color.FromArgb(20, 255, 255, 255));
        using var small = new Font(FontFamily.GenericMonospace, 7.5f);
        for (double t = 0; t <= Duration; t += step)
        {
            var gx = XAt(t);
            if (gx < e.ClipRectangle.Left - 60 || gx > e.ClipRectangle.Right) continue;
            g.FillRectangle(grid, gx, 0, 1, Height);
            if ((int)t % (int)(step * (step == 10 ? 3 : 5)) == 0)
                g.DrawString(AudioEditor.HmsShort(t), small, Brushes.Gray, gx + 3, 2);
        }
        using (var cut = new SolidBrush(Color.FromArgb(90, 229, 57, 53)))
            foreach (var (a, b) in Cuts) g.FillRectangle(cut, XAt(a), 0, Math.Max(1, XAt(b) - XAt(a)), Height);
        float mid = Height / 2f + 6, n = Math.Max(Peaks.Length, 1), bw = Width / n;
        using (var wave = new SolidBrush(Color.FromArgb(0x3D, 0x8B, 0xFD)))
            for (int i = 0; i < Peaks.Length; i++)
            {
                var x = i * bw;
                if (x < e.ClipRectangle.Left - bw || x > e.ClipRectangle.Right) continue;
                var h = Math.Max(1, (float)Peaks[i] * (Height - 24));
                g.FillRectangle(wave, x, mid - h / 2, Math.Max(1, bw - 0.3f), h);
            }
        if (Selection is { } range && range.b - range.a > 0.05)
        {
            var (sa, sb) = range;
            using var sel = new SolidBrush(Color.FromArgb(46, 255, 255, 255));
            using var edge = new SolidBrush(Color.FromArgb(180, 255, 255, 255));
            g.FillRectangle(sel, XAt(sa), 0, XAt(sb) - XAt(sa), Height);
            g.FillRectangle(edge, XAt(sa), 0, 1, Height);
            g.FillRectangle(edge, XAt(sb), 0, 1, Height);
        }
        else if (Selection is { } pt)
            g.FillRectangle(Brushes.White, XAt(pt.a), 0, 1, Height);
        if (Playhead is double ph) g.FillRectangle(Brushes.Gold, XAt(ph) - 1, 0, 2, Height);
    }
}

sealed class EditorForm : Form
{
    public List<(double start, double end)>? Result;
    readonly string dir;
    readonly WaveView wave = new();
    readonly Panel scroll = new() { AutoScroll = true, Dock = DockStyle.Fill };
    readonly TrackBar zoom = new() { Minimum = 1, Maximum = 40, Value = 1, TickStyle = TickStyle.None, Width = 200, AutoSize = false, Height = 26 };
    readonly Label info = new() { AutoSize = true, Margin = new Padding(12, 6, 0, 0) };
    readonly Label cutsLabel = new() { AutoSize = true, MaximumSize = new Size(560, 0), Margin = new Padding(0, 8, 0, 0) };
    readonly System.Windows.Forms.Timer timer = new() { Interval = 50 };
    WasapiOut? output;
    WaveStream? reader;
    double? stopAt;
    string? tempWav;

    public EditorForm(string dir, bool load = true)
    {
        this.dir = dir;
        Text = "MeetRec – " + T("editor_title");
        Icon = Icons.App;
        Font = SystemFonts.MessageBoxFont;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(980, 460);
        MinimumSize = new Size(700, 380);
        KeyPreview = true;
        var root = new TableLayoutPanel { ColumnCount = 1, Dock = DockStyle.Fill, Padding = new Padding(14) };
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.Controls.Add(new Label { Text = T("editor_help"), AutoSize = true, MaximumSize = new Size(940, 0), Margin = new Padding(0, 0, 0, 8) });
        var zoomRow = new FlowLayoutPanel { AutoSize = true, WrapContents = false };
        zoomRow.Controls.Add(new Label { Text = T("editor_zoom"), AutoSize = true, Margin = new Padding(0, 6, 4, 0) });
        zoomRow.Controls.Add(zoom);
        zoomRow.Controls.Add(info);
        root.Controls.Add(zoomRow);
        scroll.Controls.Add(wave);
        scroll.Resize += (_, _) => LayoutWave();
        root.Controls.Add(scroll);
        var buttons = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(0, 8, 0, 0) };
        Button B(string text, Action a) { var b = new Button { Text = text, AutoSize = true }; b.Click += (_, _) => a(); buttons.Controls.Add(b); return b; }
        B("▶ " + T("editor_play_selection"), PlaySelection);
        B(T("editor_play_from_here"), () => Play(wave.Selection?.a ?? 0, null));
        B("■ " + T("editor_stop"), StopPlayback);
        buttons.Controls.Add(new Label { Width = 20 });
        B("✂ " + T("editor_cut"), CutSelection);
        B(T("editor_undo"), UndoCut);
        root.Controls.Add(buttons);
        var bottom = new TableLayoutPanel { ColumnCount = 3, AutoSize = true, Dock = DockStyle.Fill };
        bottom.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        bottom.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        bottom.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        bottom.Controls.Add(cutsLabel);
        var cancel = new Button { Text = T("cancel"), AutoSize = true };
        var apply = new Button { Text = T("editor_apply"), AutoSize = true };
        cancel.Click += (_, _) => { Result = null; Close(); };
        apply.Click += (_, _) => { Result = wave.Cuts.ToList(); Close(); };
        bottom.Controls.Add(cancel); bottom.Controls.Add(apply);
        AcceptButton = apply;
        root.Controls.Add(bottom);
        Controls.Add(root);
        zoom.ValueChanged += (_, _) =>
        {
            double center = (-scroll.AutoScrollPosition.X + scroll.ClientSize.Width / 2.0) / Math.Max(1, wave.Width);
            LayoutWave();
            scroll.AutoScrollPosition = new Point((int)Math.Max(0, center * wave.Width - scroll.ClientSize.Width / 2.0), 0);
        };
        wave.OnSelection = UpdateInfo;
        timer.Tick += (_, _) => TickPlayback();
        KeyDown += (_, e) =>
        {
            if (e.KeyCode == Keys.Space) { if (output?.PlaybackState == PlaybackState.Playing) StopPlayback(); else PlaySelection(); e.Handled = e.SuppressKeyPress = true; }
            if (e.KeyCode == Keys.Delete || e.KeyCode == Keys.Back) { CutSelection(); e.Handled = e.SuppressKeyPress = true; }
            if (e.Control && e.KeyCode == Keys.Z) { UndoCut(); e.Handled = true; }
        };
        FormClosed += (_, _) => Cleanup();
        UpdateCuts();
        info.Text = T("editor_loading");
        if (load) Shown += (_, _) => Load_();
    }

    /// demo data for --render-docs
    public static EditorForm Demo()
    {
        var f = new EditorForm("", load: false);
        var rnd = new Random(7);
        f.wave.Duration = 1840;
        f.wave.Peaks = Enumerable.Range(0, 1500).Select(i => Math.Abs(Math.Sin(i / 9.0)) * 0.5 * rnd.NextDouble() + (i % 300 < 20 ? 0 : 0.15)).ToArray();
        f.wave.Cuts.Add((95, 160));
        f.wave.Selection = (612, 655);
        f.UpdateCuts(); f.UpdateInfo();
        return f;
    }

    void LayoutWave()
    {
        var h = scroll.ClientSize.Height - (zoom.Value > 1 ? 0 : 0);
        wave.SetBounds(scroll.AutoScrollPosition.X, 0, Math.Max(scroll.ClientSize.Width, scroll.ClientSize.Width * zoom.Value), h);
        wave.Invalidate();
    }

    void Load_()
    {
        LayoutWave();
        Meet.Run(new[] { "peaks", dir, "--n", "6000" }, (_, out_) =>
        {
            if (IsDisposed) return;
            if (Meet.LastJson(out_) is not JsonObject j || j["peaks"] is not JsonArray arr || arr.Count == 0)
            {
                info.Text = T("editor_no_audio");
                return;
            }
            wave.Duration = j["duration"]?.GetValue<double>() ?? 1;
            wave.Peaks = arr.Select(p => p?.GetValue<double>() ?? 0).ToArray();
            UpdateInfo();
            LayoutWave();
            OpenAudio();
        });
    }

    void OpenAudio()
    {
        var m4a = Path.Combine(dir, "mix.m4a");
        try { reader = new MediaFoundationReader(m4a); }
        catch
        {
            // no Media Foundation AAC decoder (Windows N): ffmpeg to a temporary WAV
            try
            {
                tempWav = Path.Combine(Path.GetTempPath(), $"meetrec-edit-{Environment.ProcessId}.wav");
                var ff = File.Exists(Path.Combine(Paths.DataDir, "bin", "ffmpeg.exe")) ? Path.Combine(Paths.DataDir, "bin", "ffmpeg.exe") : "ffmpeg.exe";
                var p = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(ff) { CreateNoWindow = true, UseShellExecute = false,
                    ArgumentList = { "-hide_banner", "-loglevel", "error", "-y", "-i", m4a, tempWav } })!;
                p.WaitForExit();
                reader = new WaveFileReader(tempWav);
            }
            catch (Exception e) { Log.Append($"[app] editor: cannot play the audio: {e.Message}\n"); }
        }
        if (reader != null)
        {
            output = new WasapiOut();
            output.Init(reader);
        }
    }

    void UpdateInfo()
    {
        var total = AudioEditor.HmsShort(wave.Duration);
        if (wave.Selection is { } s && s.b - s.a > 0.05)
            info.Text = $"{AudioEditor.HmsTenths(s.a)} – {AudioEditor.HmsTenths(s.b)}  ({AudioEditor.HmsTenths(s.b - s.a)})  / {total}";
        else if (wave.Selection is { } p)
            info.Text = $"{AudioEditor.HmsTenths(p.a)}  / {total}";
        else info.Text = T("editor_total", ("t", total));
    }

    void UpdateCuts()
    {
        var removed = wave.Cuts.Sum(c => c.b - c.a);
        cutsLabel.Text = wave.Cuts.Count == 0 ? T("editor_no_cuts")
            : T("editor_cuts", ("n", wave.Cuts.Count.ToString()), ("t", AudioEditor.HmsTenths(removed))) + ": "
              + string.Join(", ", wave.Cuts.Select(c => $"{AudioEditor.HmsShort(c.a)}–{AudioEditor.HmsShort(c.b)}"));
    }

    void Play(double from, double? until)
    {
        if (output == null || reader == null) { System.Media.SystemSounds.Beep.Play(); return; }
        output.Stop();
        reader.CurrentTime = TimeSpan.FromSeconds(Math.Min(from, reader.TotalTime.TotalSeconds));
        stopAt = until;
        output.Play();
        timer.Start();
    }

    void PlaySelection()
    {
        if (wave.Selection is not { } s) { Play(0, null); return; }
        Play(s.a, s.b - s.a > 0.05 ? s.b : null);
    }

    void TickPlayback()
    {
        if (reader == null || output == null) return;
        var t = reader.CurrentTime.TotalSeconds;
        wave.Playhead = t;
        wave.Invalidate();
        if (stopAt is double s && t >= s) StopPlayback();
        if (output.PlaybackState != PlaybackState.Playing) timer.Stop();
    }

    void StopPlayback()
    {
        output?.Pause();
        timer.Stop();
    }

    void CutSelection()
    {
        if (wave.Selection is not { } s || s.b - s.a <= 0.2) { System.Media.SystemSounds.Beep.Play(); return; }
        wave.Cuts.Add(s);
        wave.Selection = null;
        wave.Invalidate();
        UpdateCuts(); UpdateInfo();
    }

    void UndoCut()
    {
        if (wave.Cuts.Count == 0) return;
        wave.Cuts.RemoveAt(wave.Cuts.Count - 1);
        wave.Invalidate();
        UpdateCuts();
    }

    void Cleanup()
    {
        timer.Stop();
        output?.Stop(); output?.Dispose(); output = null;
        reader?.Dispose(); reader = null;
        if (tempWav != null) try { File.Delete(tempWav); } catch { }
    }
}
