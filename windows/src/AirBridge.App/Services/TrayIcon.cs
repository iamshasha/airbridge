using System.Runtime.InteropServices;

namespace AirBridge.App;

/// <summary>
/// Notification-area (system tray) icon so AirBridge keeps receiving after its window is closed.
/// WinUI 3 has no tray API, so this uses Shell_NotifyIcon and subclasses the main window for its callbacks.
/// </summary>
internal sealed partial class TrayIcon : IDisposable
{
    const uint WmTray = 0x8001; // WM_APP + 1
    const uint NimAdd = 0, NimDelete = 2, NimSetVersion = 4;
    const uint NifMessage = 1, NifIcon = 2, NifTip = 4;
    const uint WmLButtonUp = 0x202, WmRButtonUp = 0x205, WmContextMenu = 0x7B;
    const uint CmdOpen = 1, CmdQuit = 2;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct NotifyIconData
    {
        public int cbSize;
        public nint hWnd;
        public uint uID;
        public uint uFlags;
        public uint uCallbackMessage;
        public nint hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
        public uint dwState, dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
        public uint uVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
        public uint dwInfoFlags;
        public Guid guidItem;
        public nint hBalloonIcon;
    }

    [StructLayout(LayoutKind.Sequential)] struct Point { public int X, Y; }

    delegate nint SubclassProc(nint hWnd, uint msg, nint wParam, nint lParam, nuint id, nuint data);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern bool Shell_NotifyIcon(uint message, ref NotifyIconData data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern nint LoadImage(nint instance, string name, uint type, int cx, int cy, uint load);
    [DllImport("user32.dll")] static extern bool DestroyIcon(nint icon);
    [DllImport("user32.dll")] static extern nint CreatePopupMenu();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool AppendMenu(nint menu, uint flags, nuint id, string? text);
    [DllImport("user32.dll")] static extern uint TrackPopupMenu(nint menu, uint flags, int x, int y, int reserved, nint hWnd, nint rect);
    [DllImport("user32.dll")] static extern bool DestroyMenu(nint menu);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(nint hWnd);
    [DllImport("comctl32.dll")] static extern bool SetWindowSubclass(nint hWnd, SubclassProc proc, nuint id, nuint data);
    [DllImport("comctl32.dll")] static extern bool RemoveWindowSubclass(nint hWnd, SubclassProc proc, nuint id);
    [DllImport("comctl32.dll")] static extern nint DefSubclassProc(nint hWnd, uint msg, nint wParam, nint lParam);

    readonly nint _hwnd;
    readonly nint _icon;
    readonly SubclassProc _proc; // keep the delegate alive while Windows holds a pointer to it
    readonly Action _open;
    readonly Action _quit;

    public TrayIcon(nint hwnd, string iconPath, Action open, Action quit)
    {
        _hwnd = hwnd;
        _open = open;
        _quit = quit;
        _icon = LoadImage(0, iconPath, 1 /* IMAGE_ICON */, 16, 16, 0x10 /* LR_LOADFROMFILE */);
        _proc = WndProc;
        SetWindowSubclass(hwnd, _proc, 1, 0);
        var data = Data();
        Shell_NotifyIcon(NimAdd, ref data);
        data.uVersion = 4;
        Shell_NotifyIcon(NimSetVersion, ref data);
    }

    NotifyIconData Data() => new()
    {
        cbSize = Marshal.SizeOf<NotifyIconData>(),
        hWnd = _hwnd,
        uID = 1,
        uFlags = NifMessage | NifIcon | NifTip,
        uCallbackMessage = WmTray,
        hIcon = _icon,
        szTip = "AirBridge — ready to receive",
        szInfo = "",
        szInfoTitle = "",
    };

    nint WndProc(nint hWnd, uint msg, nint wParam, nint lParam, nuint id, nuint data)
    {
        if (msg == WmTray)
        {
            // NOTIFYICON_VERSION_4: the mouse message is in the low word of lParam.
            switch ((uint)(lParam & 0xFFFF))
            {
                case WmLButtonUp: _open(); break;
                case WmRButtonUp or WmContextMenu: ShowMenu(); break;
            }
            return 0;
        }
        return DefSubclassProc(hWnd, msg, wParam, lParam);
    }

    void ShowMenu()
    {
        var menu = CreatePopupMenu();
        AppendMenu(menu, 0, CmdOpen, "Open AirBridge");
        AppendMenu(menu, 0x800 /* MF_SEPARATOR */, 0, null);
        AppendMenu(menu, 0, CmdQuit, "Quit");
        GetCursorPos(out var p);
        SetForegroundWindow(_hwnd); // so the menu closes when clicking elsewhere
        var command = TrackPopupMenu(menu, 0x100 /* TPM_RETURNCMD */ | 0x2 /* TPM_RIGHTBUTTON */, p.X, p.Y, 0, _hwnd, 0);
        DestroyMenu(menu);
        if (command == CmdOpen) _open();
        else if (command == CmdQuit) _quit();
    }

    public void Dispose()
    {
        var data = Data();
        Shell_NotifyIcon(NimDelete, ref data);
        RemoveWindowSubclass(_hwnd, _proc, 1);
        if (_icon != 0) DestroyIcon(_icon);
    }
}
