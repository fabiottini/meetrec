// meetrec-capture for Windows: records the microphone and the system audio (WASAPI loopback) on two
// tracks, with the same contract as the macOS recorder, so meet.py does not see any difference:
//
//   meetrec-capture <out_dir> [--no-mic] [--no-system] [--mic-id ID] [--auto-gain]
//   meetrec-capture --list-mics                 "* name<TAB>id" lines, * = default
//   meetrec-capture <out_dir> --test-tone SEC   synthetic audio through the same writer (CI, no devices)
//
// Files: <track>.s16 (s16le mono, appended as it arrives: crash safe) + <track>.json, "levels" every
// 100 ms, capture.done at the end, capture.error on failure. Stop: <out_dir>/stop.request or Ctrl+C.
// WASAPI loopback sends nothing while nothing plays: the gaps are filled with silence by the clock,
// so the two tracks stay aligned.

using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace MeetRec.Capture;

sealed class Track
{
    public readonly string Name;
    readonly string dir;
    FileStream? fs;
    public int Rate;
    public long Frames;
    public double StartSec;
    readonly object gate = new();
    int winPeak; double winSumSq; long winN; int winClipped;

    public Track(string name, string dir) { Name = name; this.dir = dir; }

    public void Open(int rate, double startSec)
    {
        Rate = rate; StartSec = startSec; Frames = 0;
        fs = new FileStream(Path.Combine(dir, Name + ".s16"), FileMode.Create, FileAccess.Write, FileShare.Read);
        var meta = new Dictionary<string, object> { ["format"] = "s16le", ["channels"] = 1, ["sample_rate"] = rate, ["offset_seconds"] = startSec };
        File.WriteAllText(Path.Combine(dir, Name + ".json"), JsonSerializer.Serialize(meta, new JsonSerializerOptions { WriteIndented = true }));
        Program.Log($"track {Name}: {rate} Hz, offset {startSec:F3} s");
    }

    public void Write(short[] s, int count)
    {
        lock (gate)
        {
            if (fs == null || count <= 0) return;
            var bytes = new byte[count * 2];
            Buffer.BlockCopy(s, 0, bytes, 0, count * 2);
            fs.Write(bytes, 0, bytes.Length);
            Frames += count;
            for (int i = 0; i < count; i++)
            {
                int a = Math.Abs((int)s[i]);
                if (a > winPeak) winPeak = a;
                if (a >= 32000) winClipped++;
                winSumSq += (double)s[i] * s[i];
            }
            winN += count;
        }
    }

    public double LastData = double.NegativeInfinity;

    /// fill with silence up to the given clock time (loopback is silent when nothing plays)
    public void PadTo(double nowSec)
    {
        lock (gate)
        {
            if (fs == null) return;
            long missing = (long)((nowSec - StartSec) * Rate) - Frames;
            if (missing < Rate / 20) return;                 // < 50 ms: normal jitter
            var zeros = new short[Math.Min(missing, Rate)];
            while (missing > 0)
            {
                int n = (int)Math.Min(missing, zeros.Length);
                Write(zeros, n);
                missing -= n;
            }
        }
    }

    /// a packet from the device. The gap is filled only after a real pause in the packets, never
    /// while the stream flows: the device clock and the system clock drift a little, and padding
    /// against the drift would put small holes in the voice.
    public void Feed(short[] s, int n, double now)
    {
        lock (gate)
        {
            if (now - LastData > 0.2) PadTo(now - (double)n / Rate);
            LastData = now;
            Write(s, n);
        }
    }

    /// called every 100 ms: silence while no packets arrive
    public void Idle(double now)
    {
        lock (gate) { if (now - LastData > 0.3) PadTo(now - 0.15); }
    }

    public (double rms, double peak, int clipped) TakeWindow()
    {
        lock (gate)
        {
            if (winN == 0) return (-120, -120, 0);
            double rms = Math.Sqrt(winSumSq / winN) / 32768, peak = winPeak / 32768.0;
            var r = (rms > 0 ? 20 * Math.Log10(rms) : -120, peak > 0 ? 20 * Math.Log10(peak) : -120, winClipped);
            winPeak = 0; winSumSq = 0; winN = 0; winClipped = 0;
            return r;
        }
    }

    public void Close()
    {
        lock (gate) { fs?.Flush(true); fs?.Dispose(); fs = null; }
    }
}

static class Program
{
    static readonly Stopwatch clock = Stopwatch.StartNew();
    static readonly Guid IeeeFloat = new("00000003-0000-0010-8000-00aa00389b71");
    static volatile bool stopRequested;
    static double Now => clock.Elapsed.TotalSeconds;

    [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint flags);

    public static void Log(string s) =>
        Console.Error.WriteLine($"[{DateTime.UtcNow:yyyy-MM-ddTHH:mm:ssZ}] {s}");

    /// any WASAPI buffer -> mono s16 (first channel average of all channels)
    static short[] ToMonoS16(WaveFormat f, byte[] buf, int bytes, out int frames)
    {
        int ch = Math.Max(1, f.Channels);
        bool isFloat = f.Encoding == WaveFormatEncoding.IeeeFloat ||
                       (f is WaveFormatExtensible x && x.SubFormat == IeeeFloat);
        int bps = f.BitsPerSample / 8;
        frames = bytes / (bps * ch);
        var out16 = new short[frames];
        for (int i = 0; i < frames; i++)
        {
            double sum = 0;
            for (int c = 0; c < ch; c++)
            {
                int o = (i * ch + c) * bps;
                double v = isFloat && bps == 4 ? BitConverter.ToSingle(buf, o)
                         : bps == 2 ? BitConverter.ToInt16(buf, o) / 32768.0
                         : bps == 3 ? ((buf[o] | buf[o + 1] << 8 | (sbyte)buf[o + 2] << 16) / 8388608.0)
                         : bps == 4 ? BitConverter.ToInt32(buf, o) / 2147483648.0 : 0;
                sum += v;
            }
            double m = Math.Clamp(sum / ch, -1.0, 1.0);
            out16[i] = (short)(m * 32767);
        }
        return out16;
    }

    static int Main(string[] args)
    {
        Console.OutputEncoding = Encoding.UTF8;
        if (args.Length > 0 && args[0] == "--list-mics") return ListMics();
        if (args.Length == 0 || args[0].StartsWith("-"))
        {
            Console.Error.WriteLine("usage: meetrec-capture <out_dir> [--no-mic] [--no-system] [--mic-id ID] [--auto-gain] | --list-mics");
            return 64;
        }
        string dir = Path.GetFullPath(args[0]);
        bool wantMic = true, wantSystem = true, autoGain = false;
        string? micId = null;
        double testTone = 0;
        for (int i = 1; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--no-mic": wantMic = false; break;
                case "--no-system": wantSystem = false; break;
                case "--auto-gain": autoGain = true; break;
                case "--mic-id": micId = i + 1 < args.Length ? args[++i] : null; break;
                case "--test-tone": testTone = double.Parse(args[++i], System.Globalization.CultureInfo.InvariantCulture); break;
                default: Log($"unknown option {args[i]}"); return 64;
            }
        }
        Directory.CreateDirectory(dir);
        try { return testTone > 0 ? RunTestTone(dir, testTone, wantMic, wantSystem) : Run(dir, wantMic, wantSystem, micId, autoGain); }
        catch (Exception e)
        {
            Log($"cannot record: {e.Message}");
            File.WriteAllText(Path.Combine(dir, "capture.error"), e.Message);
            return 1;
        }
    }

    static int ListMics()
    {
        using var en = new MMDeviceEnumerator();
        string def = "";
        try { def = en.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications).ID; } catch { }
        foreach (var d in en.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
            Console.WriteLine($"{(d.ID == def ? "*" : " ")} {d.FriendlyName}\t{d.ID}");
        return 0;
    }

    static int Run(string dir, bool wantMic, bool wantSystem, string? micId, bool autoGain)
    {
        SetThreadExecutionState(0x80000000 | 0x00000001);    // ES_CONTINUOUS | ES_SYSTEM_REQUIRED: stay awake
        using var en = new MMDeviceEnumerator();
        MMDevice? micDev = null;
        if (wantMic)
        {
            micDev = micId != null ? en.GetDevice(micId) : en.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications);
            if (micDev.AudioEndpointVolume.Mute)
                Log($"warning: mic '{micDev.FriendlyName}' is muted, your voice will not be recorded until you unmute it");
        }
        var system = new Track("system", dir);
        var mic = new Track("mic", dir);
        WasapiLoopbackCapture? loop = wantSystem ? new WasapiLoopbackCapture() : null;
        WasapiCapture? micCap = micDev != null ? new WasapiCapture(micDev) : null;
        string? failure = null;

        if (loop != null)
        {
            system.Open(loop.WaveFormat.SampleRate, 0);
            loop.DataAvailable += (_, e) =>
            {
                var s = ToMonoS16(loop.WaveFormat, e.Buffer, e.BytesRecorded, out int n);
                system.Feed(s, n, Now);
            };
            loop.RecordingStopped += (_, e) => { if (e.Exception != null) failure = "system audio: " + e.Exception.Message; };
        }
        if (micCap != null)
        {
            mic.Open(micCap.WaveFormat.SampleRate, 0);
            micCap.DataAvailable += (_, e) =>
            {
                var s = ToMonoS16(micCap.WaveFormat, e.Buffer, e.BytesRecorded, out int n);
                mic.Feed(s, n, Now);
            };
            micCap.RecordingStopped += (_, e) => { if (e.Exception != null) failure = "microphone: " + e.Exception.Message; };
        }
        clock.Restart();
        loop?.StartRecording();
        micCap?.StartRecording();
        Log($"recording started in {dir} (system={wantSystem}, mic={wantMic})");
        if (autoGain && micDev != null)
            Log($"auto gain on, mic '{micDev.FriendlyName}' volume {(int)(micDev.AudioEndpointVolume.MasterVolumeLevelScalar * 100)}%");

        Loop(dir, system, mic, wantSystem, micCap != null, () => failure,
             autoGain && micDev != null ? micDev.AudioEndpointVolume : null);

        loop?.StopRecording();
        micCap?.StopRecording();
        Thread.Sleep(200);
        Finish(dir, system, mic, wantSystem, micCap != null);
        loop?.Dispose();
        micCap?.Dispose();
        if (failure != null)
        {
            File.WriteAllText(Path.Combine(dir, "capture.error"), failure);
            Log($"stream stopped with error: {failure}");
            return 2;
        }
        return 0;
    }

    /// every 100 ms: stop request?, silence padding of the loopback, levels file, auto gain
    static void Loop(string dir, Track system, Track mic, bool hasSystem, bool hasMic, Func<string?> failure,
                     AudioEndpointVolume? vol)
    {
        Console.CancelKeyPress += (_, e) => { e.Cancel = true; stopRequested = true; };
        var lastGain = DateTime.MinValue;
        string levels = Path.Combine(dir, "levels");
        while (!stopRequested && failure() == null && !File.Exists(Path.Combine(dir, "stop.request")))
        {
            Thread.Sleep(100);
            if (hasSystem) system.Idle(Now);
            if (hasMic) mic.Idle(Now);
            var m = mic.TakeWindow();
            var s = system.TakeWindow();
            if (vol != null && m.clipped >= 3 && (DateTime.Now - lastGain).TotalSeconds > 2 && vol.MasterVolumeLevelScalar > 0.1f)
            {
                vol.MasterVolumeLevelScalar = Math.Max(0.1f, vol.MasterVolumeLevelScalar * 0.85f);
                lastGain = DateTime.Now;
                Log($"auto gain: mic clipping, volume lowered to {(int)(vol.MasterVolumeLevelScalar * 100)}%");
            }
            var txt = FormattableString.Invariant($"mic {m.rms:F1} {m.peak:F1}\nsystem {s.rms:F1} {s.peak:F1}\n");
            if (vol != null) txt += FormattableString.Invariant($"volume {vol.MasterVolumeLevelScalar:F2}\n");
            try { File.WriteAllText(levels + ".tmp", txt); File.Move(levels + ".tmp", levels, true); } catch { }
        }
    }

    static void Finish(string dir, Track system, Track mic, bool hasSystem, bool hasMic)
    {
        double end = Now;
        if (hasSystem) { system.PadTo(end); system.Close(); }
        if (hasMic) { mic.PadTo(end); mic.Close(); }
        try { File.Delete(Path.Combine(dir, "levels")); } catch { }
        File.WriteAllText(Path.Combine(dir, "capture.done"), "");
        Log("recording stopped");
    }

    /// CI without audio devices: a 440 Hz tone on "system" that is silent (no packets) every other
    /// second, like loopback, and a quieter tone on "mic", through the same writer and stop protocol
    static int RunTestTone(string dir, double seconds, bool wantMic, bool wantSystem)
    {
        var system = new Track("system", dir);
        var mic = new Track("mic", dir);
        if (wantSystem) system.Open(48000, 0);
        if (wantMic) mic.Open(16000, 0);
        clock.Restart();
        Log($"recording started in {dir} (system={wantSystem}, mic={wantMic}, test tone)");
        double stopAt = seconds;
        long sentSys = 0, sentMic = 0;
        var worker = new Thread(() =>
        {
            while (Now < stopAt && !File.Exists(Path.Combine(dir, "stop.request")))
            {
                Thread.Sleep(10);
                double now = Now;
                if (wantSystem && ((int)now) % 2 == 0)              // loopback: packets only while "playing"
                {
                    long target = (long)(now * 48000);
                    if (sentSys < target - 48000) sentSys = target - 480;
                    var buf = new short[target - sentSys];
                    for (int i = 0; i < buf.Length; i++) buf[i] = (short)(Math.Sin(2 * Math.PI * 440 * (sentSys + i) / 48000.0) * 12000);
                    system.Feed(buf, buf.Length, now);
                    sentSys = target;
                }
                if (wantMic)
                {
                    long target = (long)(now * 16000);
                    var buf = new short[Math.Max(0, target - sentMic)];
                    for (int i = 0; i < buf.Length; i++) buf[i] = (short)(Math.Sin(2 * Math.PI * 220 * (sentMic + i) / 16000.0) * 4000);
                    mic.Feed(buf, buf.Length, now);
                    sentMic = target;
                }
            }
        });
        worker.Start();
        Loop(dir, system, mic, wantSystem, wantMic, () => null, null);
        stopAt = 0;
        worker.Join();
        Finish(dir, system, mic, wantSystem, wantMic);
        return 0;
    }
}
