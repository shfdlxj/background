param(
    [Parameter(Position = 0)] [string]$Target,
    [Parameter(Position = 1)] [string]$Image,
    [ValidateSet('fill', 'fit', 'stretch', 'center')] [string]$Mode = 'fill',
    [switch]$Host_
)

# 임시 바탕화면: 실제 배경화면 설정은 건드리지 않고,
# 배경화면(WorkerW) 위 / 바탕화면 아이콘(SHELLDLL_DefView) 아래에 이미지를 띄운다.
#   background                   폴더 안 이미지를 이름 순서대로 데스크톱 1, 2, 3...에 배정 (한 장이면 전체)
#   background <이미지>          모든 가상 데스크톱에 표시
#   background <번호> <이미지>   해당 가상 데스크톱(Win+Tab 순서, 1부터)에만 표시
#   background <번호> off        해당 데스크톱 설정 지우기
#   background list              데스크톱별 설정 보기
#   background off               끄기 (실제 배경화면이 그대로 다시 보임)

$ErrorActionPreference = 'Stop'
$pidFile = Join-Path $env:TEMP 'temp-background.pid'
$configFile = Join-Path $PSScriptRoot 'desktops.txt'
$vdKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops'

function Test-Running {
    $old = Get-Content $pidFile -ErrorAction SilentlyContinue
    return [bool]($old -and (Get-Process -Id ([int]$old) -ErrorAction SilentlyContinue))
}

function Stop-Existing {
    if (Test-Path $pidFile) {
        $old = Get-Content $pidFile -ErrorAction SilentlyContinue
        if ($old) { Stop-Process -Id ([int]$old) -Force -ErrorAction SilentlyContinue }
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }
}

# Win+Tab에 보이는 순서대로 가상 데스크톱 ID 목록 (16바이트 GUID가 이어 붙어 있음)
function Get-DesktopIds {
    $bytes = (Get-ItemProperty $vdKey -ErrorAction SilentlyContinue).VirtualDesktopIDs
    if (-not $bytes) { return @() }
    for ($i = 0; $i -lt $bytes.Length; $i += 16) { [guid]::new([byte[]]$bytes[$i..($i + 15)]).ToString() }
}

function Get-CurrentDesktopId {
    $bytes = (Get-ItemProperty $vdKey -ErrorAction SilentlyContinue).CurrentVirtualDesktop
    if ($bytes) { [guid]::new([byte[]]$bytes).ToString() }
}

# 설정 파일 한 줄 = "키<TAB>표시방식<TAB>이미지경로", 키는 데스크톱 ID 또는 모든 데스크톱을 뜻하는 *
function Read-Config {
    $config = [ordered]@{}
    if (Test-Path $configFile) {
        foreach ($line in Get-Content $configFile -Encoding UTF8) {
            $key, $m, $path = $line -split "`t", 3
            if ($path) { $config[$key] = @($m, $path) }
        }
    }
    return $config
}

function Write-Config($config) {
    $lines = foreach ($k in $config.Keys) { "$k`t$($config[$k][0])`t$($config[$k][1])" }
    Set-Content -Path $configFile -Value $lines -Encoding UTF8
}

function Show-Config {
    $config = Read-Config
    $current = Get-CurrentDesktopId
    $ids = @(Get-DesktopIds)
    $all = if ($config.Contains('*')) { $config['*'][1] } else { '(없음)' }
    Write-Host "모든 데스크톱: $all"
    for ($i = 0; $i -lt $ids.Count; $i++) {
        $mark = if ($ids[$i] -eq $current) { '*' } else { ' ' }
        $img = if ($config.Contains($ids[$i])) { $config[$ids[$i]][1] } else { '-' }
        Write-Host ("{0} 데스크톱 {1}: {2}" -f $mark, ($i + 1), $img)
    }
}

function Resolve-Image($path) {
    if (-not $path) {
        $path = Get-ChildItem -LiteralPath $PSScriptRoot -File |
            Where-Object { $_.Extension -match '^\.(jpe?g|png|bmp|gif|tiff?)$' } |
            Select-Object -First 1 -ExpandProperty FullName
        if (-not $path) { Write-Host '이미지를 지정하거나 이 폴더에 이미지 파일(jpg/png/bmp/gif)을 넣어주세요.'; exit 1 }
    }
    return (Resolve-Path -LiteralPath $path).Path
}

if (-not $Host_) {
    if ($Target -in 'off', 'stop') {
        Stop-Existing
        Remove-Item $configFile -Force -ErrorAction SilentlyContinue
        Write-Host '임시 바탕화면을 껐습니다.'
        return
    }
    if ($Target -eq 'list') { Show-Config; return }

    $isRunning = Test-Running
    # 새로 켤 때는 지난번(재부팅 전 등)에 남은 설정을 이어받지 않는다
    $config = if ($isRunning) { Read-Config } else { [ordered]@{} }

    if ($Target -match '^\d+$') {
        $ids = @(Get-DesktopIds)
        $n = [int]$Target
        if ($n -lt 1 -or $n -gt $ids.Count) {
            Write-Host "데스크톱 $n 이(가) 없습니다. 지금 가상 데스크톱은 $($ids.Count)개예요. (Win+Tab으로 확인)"
            exit 1
        }
        $id = $ids[$n - 1]
        if ($Image -in 'off', 'stop') {
            $config.Remove($id)
            Write-Host "데스크톱 $n 설정을 지웠습니다."
        } else {
            $path = Resolve-Image $Image
            $config[$id] = @($Mode, $path)
            Write-Host "데스크톱 $n : $path"
        }
    } elseif (-not $Target) {
        # 원터치(인자 없음): 폴더 안 이미지를 파일 이름 순서대로 데스크톱 1, 2, 3...에 배정
        $files = @(Get-ChildItem -LiteralPath $PSScriptRoot -File |
            Where-Object { $_.Extension -match '^\.(jpe?g|png|bmp|gif|tiff?)$' } |
            Sort-Object Name | Select-Object -ExpandProperty FullName)
        if ($files.Count -eq 0) { Write-Host '이 폴더에 이미지 파일(jpg/png/bmp/gif)을 넣어주세요.'; exit 1 }
        $ids = @(Get-DesktopIds)
        $config = [ordered]@{}
        if ($files.Count -eq 1 -or $ids.Count -le 1) {
            $config['*'] = @($Mode, $files[0])
            Write-Host "모든 데스크톱: $($files[0])"
        } else {
            for ($i = 0; $i -lt [Math]::Min($files.Count, $ids.Count); $i++) {
                $config[$ids[$i]] = @($Mode, $files[$i])
                Write-Host "데스크톱 $($i + 1) : $($files[$i])"
            }
            # 이미지가 데스크톱보다 적으면(나중에 새로 만든 데스크톱 포함) 1번 이미지를 쓴다
            $config['*'] = @($Mode, $files[0])
            if ($files.Count -lt $ids.Count) { Write-Host "나머지 데스크톱: $($files[0])" }
        }
    } else {
        $path = Resolve-Image $Target
        $config['*'] = @($Mode, $path)
        Write-Host "모든 데스크톱: $path"
    }

    if ($config.Count -eq 0) {
        Stop-Existing
        Remove-Item $configFile -Force -ErrorAction SilentlyContinue
        Write-Host '남은 설정이 없어서 임시 바탕화면을 껐습니다.'
        return
    }
    Write-Config $config
    # 이미 떠 있으면 설정 파일 변경을 스스로 감지하므로 다시 띄울 필요가 없다
    if (-not $isRunning) {
        $p = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @(
            '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', "`"$PSCommandPath`"", '-Host_')
        Set-Content -Path $pidFile -Value $p.Id
    }
    Write-Host '(설정 보기: background list / 끄기: background off)'
    return
}

Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.Win32;

public class DesktopLayer : Form
{
    [DllImport("user32.dll")] static extern IntPtr FindWindow(string cls, string name);
    [DllImport("user32.dll")] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string name);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr SetParent(IntPtr child, IntPtr parent);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool ScreenToClient(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr h);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int idx);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int idx, int v);
    [DllImport("user32.dll")] static extern bool SetLayeredWindowAttributes(IntPtr h, uint key, byte alpha, uint flags);
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr v);

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }

    const int GWL_STYLE = -16, GWL_EXSTYLE = -20;
    const int WS_CHILD = 0x40000000, WS_POPUP = unchecked((int)0x80000000), WS_VISIBLE = 0x10000000;
    const int WS_EX_LAYERED = 0x80000, WS_EX_TOOLWINDOW = 0x80, WS_EX_NOACTIVATE = 0x8000000;
    const uint SWP_NOACTIVATE = 0x10, SWP_SHOWWINDOW = 0x40, SWP_HIDEWINDOW = 0x80;
    const string VirtualDesktopsKey = @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops";

    IntPtr parent, insertAfter;
    Size hostSize;
    Rectangle[] screens;     // 부모 창 좌표 기준의 모니터 영역
    string configPath;
    DateTime configStamp;
    Dictionary<string, string[]> entries = new Dictionary<string, string[]>();   // 키 → [표시방식, 경로]
    Dictionary<string, Bitmap> cache = new Dictionary<string, Bitmap>();          // 데스크톱 전환을 즉시 하려고 미리 그린 것을 보관
    string shownEntry;       // 지금 보이는 "표시방식|경로" (안 보이면 null)
    Bitmap canvas;
    bool isShown;
    Timer poll;

    public static void Run(string configPath)
    {
        try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch { }
        Application.EnableVisualStyles();
        Application.Run(new DesktopLayer(configPath));
    }

    DesktopLayer(string configPath)
    {
        this.configPath = configPath;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        BackColor = Color.Black;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint, true);

        FindHost();

        RECT rc; GetClientRect(parent, out rc);
        hostSize = new Size(rc.R - rc.L, rc.B - rc.T);
        screens = Screen.AllScreens.Select(s =>
        {
            var p = new POINT { X = s.Bounds.X, Y = s.Bounds.Y };
            ScreenToClient(parent, ref p);
            return new Rectangle(p.X, p.Y, s.Bounds.Width, s.Bounds.Height);
        }).ToArray();
        Bounds = new Rectangle(Point.Empty, hostSize);
    }

    void FindHost()
    {
        IntPtr progman = FindWindow("Progman", null), r;
        if (progman == IntPtr.Zero) throw new InvalidOperationException("바탕화면(Progman) 창을 찾을 수 없습니다.");
        // Progman에게 배경화면 뒤에 WorkerW를 만들라고 요청 (실제 배경화면 설정은 바뀌지 않음)
        SendMessageTimeout(progman, 0x052C, new IntPtr(0xD), new IntPtr(1), 0, 1000, out r);
        SendMessageTimeout(progman, 0x052C, IntPtr.Zero, IntPtr.Zero, 0, 1000, out r);

        IntPtr defView = FindWindowEx(progman, IntPtr.Zero, "SHELLDLL_DefView", null);
        IntPtr innerWorker = FindWindowEx(progman, IntPtr.Zero, "WorkerW", null);
        if (defView != IntPtr.Zero && innerWorker != IntPtr.Zero)
        {
            // Windows 11 24H2+: Progman 안에 [DefView(아이콘) > WorkerW(배경)] 구조
            parent = progman;
            insertAfter = defView;   // 아이콘 바로 아래, 배경 위
            return;
        }

        // 이전 Windows: 아이콘을 가진 WorkerW 다음(뒤)의 WorkerW가 배경 레이어
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) =>
        {
            if (FindWindowEx(h, IntPtr.Zero, "SHELLDLL_DefView", null) != IntPtr.Zero)
                found = FindWindowEx(IntPtr.Zero, h, "WorkerW", null);
            return true;
        }, IntPtr.Zero);
        parent = found != IntPtr.Zero ? found : progman;
        insertAfter = IntPtr.Zero;   // HWND_TOP
    }

    // ---- 가상 데스크톱 ----

    // 공식 API가 없어서 탐색기가 레지스트리에 적어 두는 현재 데스크톱 ID를 읽는다
    static string CurrentDesktopId()
    {
        var bytes = Registry.GetValue(VirtualDesktopsKey, "CurrentVirtualDesktop", null) as byte[];
        if (bytes == null)
        {
            // Windows 10은 세션별 위치에 저장한다
            string sessionKey = @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\SessionInfo\"
                + Process.GetCurrentProcess().SessionId + @"\VirtualDesktops";
            bytes = Registry.GetValue(sessionKey, "CurrentVirtualDesktop", null) as byte[];
        }
        return bytes != null && bytes.Length == 16 ? new Guid(bytes).ToString() : "";
    }

    void LoadConfig()
    {
        entries.Clear();
        foreach (var line in File.ReadAllLines(configPath))
        {
            var parts = line.Split(new[] { '\t' }, 3);
            if (parts.Length == 3) entries[parts[0]] = new[] { parts[1], parts[2] };
        }
        // 같은 경로라도 파일 내용이 바뀌었을 수 있으니 설정이 바뀌면 새로 그린다
        // (지금 화면에 있는 것은 교체될 때 Poll에서 정리)
        foreach (var bmp in cache.Values) if (bmp != canvas) bmp.Dispose();
        cache.Clear();
    }

    void Poll()
    {
        if (!IsWindow(parent) || !File.Exists(configPath)) { Application.Exit(); return; }
        if (GetParent(Handle) != parent) Attach();

        bool isConfigChanged = false;
        var stamp = File.GetLastWriteTimeUtc(configPath);
        if (stamp != configStamp)
        {
            try { LoadConfig(); configStamp = stamp; isConfigChanged = true; }
            catch (IOException) { return; }   // 저장 중이면 다음 차례에 다시 읽는다
        }

        string[] entry;
        if (!entries.TryGetValue(CurrentDesktopId(), out entry)) entries.TryGetValue("*", out entry);
        string wanted = entry == null ? null : entry[0] + "|" + entry[1];
        if (!isConfigChanged && wanted == shownEntry) return;

        var old = canvas;
        shownEntry = wanted;
        canvas = wanted == null ? null : GetCanvas(wanted, entry[0], entry[1]);
        if (old != null && old != canvas && !cache.ContainsValue(old)) old.Dispose();
        SetShown(canvas != null);
        Invalidate();
    }

    Bitmap GetCanvas(string key, string mode, string path)
    {
        Bitmap bmp;
        if (cache.TryGetValue(key, out bmp)) return bmp;
        try { bmp = BuildCanvas(path, mode); }
        catch (Exception) { return null; }   // 이미지가 지워졌거나 깨졌으면 그 데스크톱은 원래 배경을 보여준다
        cache[key] = bmp;
        return bmp;
    }

    Bitmap BuildCanvas(string path, string mode)
    {
        var bmp = new Bitmap(hostSize.Width, hostSize.Height);
        using (var img = Image.FromFile(path))
        using (var g = Graphics.FromImage(bmp))
        {
            ApplyExifOrientation(img);
            g.Clear(Color.Black);
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            foreach (var s in screens) DrawInto(g, img, s, mode);
        }
        return bmp;
    }

    // 휴대폰 사진은 세로로 저장하고 EXIF 회전값만 붙이는 경우가 많아서, 그 값대로 돌려준다
    static void ApplyExifOrientation(Image img)
    {
        if (Array.IndexOf(img.PropertyIdList, 0x112) < 0) return;
        RotateFlipType t;
        switch (img.GetPropertyItem(0x112).Value[0])
        {
            case 2: t = RotateFlipType.RotateNoneFlipX; break;
            case 3: t = RotateFlipType.Rotate180FlipNone; break;
            case 4: t = RotateFlipType.Rotate180FlipX; break;
            case 5: t = RotateFlipType.Rotate90FlipX; break;
            case 6: t = RotateFlipType.Rotate90FlipNone; break;
            case 7: t = RotateFlipType.Rotate270FlipX; break;
            case 8: t = RotateFlipType.Rotate270FlipNone; break;
            default: return;
        }
        img.RotateFlip(t);
    }

    static void DrawInto(Graphics g, Image img, Rectangle dst, string mode)
    {
        if (mode == "stretch") { g.DrawImage(img, dst); return; }
        if (mode == "center")
        {
            g.DrawImage(img, dst.X + (dst.Width - img.Width) / 2, dst.Y + (dst.Height - img.Height) / 2, img.Width, img.Height);
            return;
        }
        double sx = (double)dst.Width / img.Width, sy = (double)dst.Height / img.Height;
        double k = mode == "fit" ? Math.Min(sx, sy) : Math.Max(sx, sy);
        int iw = (int)Math.Round(img.Width * k), ih = (int)Math.Round(img.Height * k);
        var state = g.Save();
        g.SetClip(dst);
        g.DrawImage(img, dst.X + (dst.Width - iw) / 2, dst.Y + (dst.Height - ih) / 2, iw, ih);
        g.Restore(state);
    }

    // ---- 바탕화면에 붙이기 ----

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
            return cp;
        }
    }

    protected override bool ShowWithoutActivation { get { return true; } }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        // WinForms가 창을 다 만든 뒤에 붙여야 한다 (OnHandleCreated에서 붙이면 WinForms가 다시 떼어 숨겨버림)
        Attach();
        Poll();

        // 데스크톱 전환과 설정 변경을 감지하고, 떨어지면 다시 붙이고, 탐색기가 재시작되면 같이 종료
        poll = new Timer { Interval = 300 };
        poll.Tick += (s, a) => Poll();
        poll.Start();
    }

    void Attach()
    {
        int style = GetWindowLong(Handle, GWL_STYLE);
        SetWindowLong(Handle, GWL_STYLE, (style & ~WS_POPUP) | WS_CHILD);
        SetParent(Handle, parent);
        if (parent != IntPtr.Zero && insertAfter != IntPtr.Zero)
        {
            // 24H2의 Progman 자식은 레이어드 창이어야 합성(DirectComposition)에 그려진다
            SetWindowLong(Handle, GWL_EXSTYLE, GetWindowLong(Handle, GWL_EXSTYLE) | WS_EX_LAYERED);
            SetLayeredWindowAttributes(Handle, 0, 255, 2);
        }
        SetShown(isShown);
    }

    // 이미지가 없는 데스크톱에서는 창을 숨겨서 원래 배경화면이 보이게 한다
    void SetShown(bool show)
    {
        isShown = show;
        SetWindowPos(Handle, insertAfter, 0, 0, hostSize.Width, hostSize.Height,
            SWP_NOACTIVATE | (show ? SWP_SHOWWINDOW : SWP_HIDEWINDOW));
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        if (canvas != null) e.Graphics.DrawImageUnscaled(canvas, 0, 0);
    }
}
'@

[DesktopLayer]::Run($configFile)
