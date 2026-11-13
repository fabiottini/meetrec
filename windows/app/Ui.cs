// Small UI toolkit: an alert like NSAlert (title, text, optional controls, buttons), a labelled grid,
// and the tray icon drawing. Everything sizes itself (AutoSize), so DPI scaling and long translations fit.

using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace MeetRec;

static class L
{
    /// localized string: T("start_recording"), T("login_code_copied", ("code", code))
    public static string T(string key, params (string name, string value)[] args)
    {
        var s = I18n.Table(I18n.Lang).GetValueOrDefault(key) ?? I18n.Table("en").GetValueOrDefault(key) ?? key;
        foreach (var (n, v) in args) s = s.Replace("{" + n + "}", v);
        return s;
    }
}

sealed class Alert : Form
{
    public int Result = -1;
    readonly FlowLayoutPanel buttons;
    readonly TableLayoutPanel body;

    public Alert(string title, string info = "", Control? accessory = null, int width = 480)
    {
        Text = "MeetRec";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false; MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        AutoSize = true; AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Font = SystemFonts.MessageBoxFont;
        ShowInTaskbar = true;
        TopMost = true;
        Icon = Icons.App;
        body = new TableLayoutPanel { ColumnCount = 1, AutoSize = true, Padding = new Padding(16, 14, 16, 10), Dock = DockStyle.Fill };
        var head = new Label { Text = title, AutoSize = true, MaximumSize = new Size(width, 0), Font = new Font(Font.FontFamily, Font.Size + 2, FontStyle.Bold), Margin = new Padding(0, 0, 0, 6) };
        body.Controls.Add(head);
        if (info.Length > 0)
            body.Controls.Add(new Label { Text = info, AutoSize = true, MaximumSize = new Size(width, 0), Margin = new Padding(0, 0, 0, 10) });
        if (accessory != null) { accessory.Margin = new Padding(0, 0, 0, 8); body.Controls.Add(accessory); }
        buttons = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, AutoSize = true, Dock = DockStyle.Fill, Margin = new Padding(0, 6, 0, 0), MinimumSize = new Size(width, 0) };
        body.Controls.Add(buttons);
        Controls.Add(body);
    }

    /// buttons right to left: the first is the default (Enter), the last also answers Esc when cancel is true
    public Alert Buttons(bool lastIsCancel, params string[] labels)
    {
        for (int i = 0; i < labels.Length; i++)
        {
            int idx = i;
            var b = new Button { Text = labels[i], AutoSize = true, MinimumSize = new Size(88, 0), Padding = new Padding(6, 2, 6, 2) };
            b.Click += (_, _) => { if (Check(idx)) { Result = idx; Close(); } };
            buttons.Controls.Add(b);
            if (i == 0) AcceptButton = b;
            if (i == labels.Length - 1 && lastIsCancel) CancelButton = b;
        }
        return this;
    }

    public Func<int, bool> Check = _ => true;

    public int Run(Control? focus = null)
    {
        if (focus != null) Shown += (_, _) => focus.Focus();
        Shown += (_, _) => { Activate(); TopMost = false; TopMost = true; };
        ShowDialog();
        return Result;
    }

    public static void Info(string title, string info) => new Alert(title, info).Buttons(true, "OK").Run();
}

static class Grid
{
    /// two columns: label (right aligned) and control
    public static TableLayoutPanel Of(params (string label, Control control)[] rows)
    {
        var g = new TableLayoutPanel { ColumnCount = 2, AutoSize = true, Margin = Padding.Empty };
        g.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        g.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        foreach (var (label, c) in rows)
        {
            g.Controls.Add(new Label { Text = label, AutoSize = true, Anchor = AnchorStyles.Right, Margin = new Padding(0, 6, 8, 4) });
            c.Margin = new Padding(0, 3, 0, 3);
            g.Controls.Add(c);
        }
        return g;
    }

    public static TextBox Text(string value = "", string placeholder = "", int width = 330) =>
        new() { Text = value, PlaceholderText = placeholder, Width = width };

    /// combo of (tag, localized label)
    public static ComboBox Combo(IEnumerable<(string tag, string label)> items, string current, int width = 330)
    {
        var c = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = width };
        var list = items.ToList();
        foreach (var (_, label) in list) c.Items.Add(label);
        c.Tag = list.Select(i => i.tag).ToList();
        c.SelectedIndex = Math.Max(0, list.FindIndex(i => i.tag == current));
        return c;
    }

    public static string Selected(ComboBox c) => ((List<string>)c.Tag!)[Math.Max(0, c.SelectedIndex)];
}

static class Icons
{
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr h);

    /// Windows taskbar in dark mode (default on Windows 11)?
    public static bool DarkTaskbar()
    {
        try
        {
            using var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return (k?.GetValue("SystemUsesLightTheme") as int? ?? 0) == 0;
        }
        catch { return true; }
    }

    /// rounded tile with a waveform, like the macOS menu bar glyph.
    /// idle: white (dark taskbar) or black tile with the waveform cut out; recording: red tile, white bars
    /// that follow the mic level; recorder dead: orange; muted: a diagonal slash.
    public static Bitmap Glyph(int size, Color? fill, double? levelDb, bool muted = false, bool? dark = null)
    {
        var bmp = new Bitmap(size, size);
        float s = size / 18f;
        bool isDark = dark ?? DarkTaskbar();
        var tileColor = fill ?? (isDark ? Color.White : Color.Black);
        using var g = Graphics.FromImage(bmp);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(Color.Transparent);
        using (var tile = Rounded(new RectangleF(1 * s, 1 * s, 16 * s, 16 * s), 4.5f * s))
        using (var b = new SolidBrush(tileColor)) g.FillPath(b, tile);
        float[] heights = { 3.5f, 7.5f, 11f, 6.5f, 3.5f };
        if (levelDb is double db)
        {
            float f = (float)Math.Clamp((db + 55) / 40, 0.2, 1);
            heights = heights.Select(h => Math.Max(1.6f, h * f)).ToArray();
        }
        float w = 1.6f * s, gap = 1.3f * s;
        float x = 9 * s - (heights.Length * w + (heights.Length - 1) * gap) / 2;
        // cut-out bars: paint them in "transparent" with SourceCopy
        g.CompositingMode = fill == null ? CompositingMode.SourceCopy : CompositingMode.SourceOver;
        using var barBrush = new SolidBrush(fill == null ? Color.Transparent : Color.White);
        foreach (var h in heights)
        {
            using var r = Rounded(new RectangleF(x, 9 * s - h * s / 2, w, h * s), w / 2);
            g.FillPath(barBrush, r);
            x += w + gap;
        }
        g.CompositingMode = CompositingMode.SourceOver;
        if (muted)
        {
            using var cut = new Pen(Color.Transparent, 4.2f * s) { StartCap = LineCap.Round, EndCap = LineCap.Round };
            g.CompositingMode = CompositingMode.SourceCopy;
            g.DrawLine(cut, 2.5f * s, 1.5f * s, 16.5f * s, 16.5f * s);
            g.CompositingMode = CompositingMode.SourceOver;
            using var pen = new Pen(fill == null ? tileColor : Color.White, 1.7f * s) { StartCap = LineCap.Round, EndCap = LineCap.Round };
            g.DrawLine(pen, 2.5f * s, 1.5f * s, 16.5f * s, 16.5f * s);
        }
        return bmp;
    }

    static GraphicsPath Rounded(RectangleF r, float rad)
    {
        var p = new GraphicsPath();
        float d = rad * 2;
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    /// icon from a bitmap; the previous one must be released with Release
    public static Icon ToIcon(Bitmap b) => Icon.FromHandle(b.GetHicon());
    public static void Release(Icon? i) { if (i != null) { DestroyIcon(i.Handle); i.Dispose(); } }

    static Icon? app;
    /// window icon: the red tile
    public static Icon App => app ??= ToIcon(Glyph(32, Color.FromArgb(0xE5, 0x39, 0x35), null));
}
