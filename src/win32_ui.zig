//! Win32 declarations for the desktop window: window classes, the common
//! controls, GDI drawing, and the theming calls dark mode goes through.
//!
//! Kept apart from `win32.zig` because only the window binary needs any of it,
//! and folding several hundred more declarations into the file the console tool
//! also reads would bury the volume and journal ones it is actually about.

const std = @import("std");
const w = @import("win32.zig");

pub const HANDLE = w.HANDLE;
pub const BOOL = w.BOOL;
pub const DWORD = w.DWORD;
pub const HRESULT = w.HRESULT;

pub const Wparam = usize;
pub const Lparam = isize;
pub const Lresult = isize;

/// 0x00BBGGRR, which is the reverse of how a colour is usually written down.
pub const ColorRef = u32;

pub fn rgb(r: u8, g: u8, b: u8) ColorRef {
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16);
}

pub const WndProc = *const fn (HANDLE, u32, Wparam, Lparam) callconv(.winapi) Lresult;

pub const SubclassProc = *const fn (
    HANDLE,
    u32,
    Wparam,
    Lparam,
    usize,
    usize,
) callconv(.winapi) Lresult;

// ---- shapes ----

pub const Point = extern struct { x: i32, y: i32 };

pub const Rect = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn width(self: Rect) i32 {
        return self.right - self.left;
    }

    pub fn height(self: Rect) i32 {
        return self.bottom - self.top;
    }
};

pub const WndClassEx = extern struct {
    size: u32 = @sizeOf(WndClassEx),
    style: u32 = 0,
    proc: ?WndProc = null,
    cls_extra: i32 = 0,
    wnd_extra: i32 = 0,
    instance: ?HANDLE = null,
    icon: ?HANDLE = null,
    cursor: ?HANDLE = null,
    background: ?HANDLE = null,
    menu_name: ?[*:0]const u16 = null,
    class_name: [*:0]const u16,
    small_icon: ?HANDLE = null,
};

pub const Msg = extern struct {
    hwnd: ?HANDLE,
    message: u32,
    wparam: Wparam,
    lparam: Lparam,
    time: DWORD,
    pt: Point,
};

pub const PaintStruct = extern struct {
    dc: HANDLE,
    erase: BOOL,
    paint: Rect,
    restore: BOOL,
    inc_update: BOOL,
    reserved: [32]u8,
};

/// Every WM_NOTIFY carries one of these, and `code` says what the rest is.
pub const NmHdr = extern struct {
    from: HANDLE,
    id: usize,
    code: u32,
};

pub const LvItem = extern struct {
    mask: u32 = 0,
    item: i32 = 0,
    sub_item: i32 = 0,
    state: u32 = 0,
    state_mask: u32 = 0,
    text: ?[*:0]u16 = null,
    text_max: i32 = 0,
    image: i32 = 0,
    param: Lparam = 0,
    indent: i32 = 0,
    group_id: i32 = 0,
    columns: u32 = 0,
    column_ids: ?*u32 = null,
    column_formats: ?*i32 = null,
    group: i32 = 0,
};

pub const NmLvDispInfo = extern struct {
    hdr: NmHdr,
    item: LvItem,
};

pub const LvColumn = extern struct {
    mask: u32 = 0,
    fmt: i32 = 0,
    cx: i32 = 0,
    text: ?[*:0]const u16 = null,
    text_max: i32 = 0,
    sub_item: i32 = 0,
    image: i32 = 0,
    order: i32 = 0,
    cx_min: i32 = 0,
    cx_default: i32 = 0,
    cx_ideal: i32 = 0,
};

/// The common part of every custom draw notification. `stage` says which of
/// the several passes over a control this one is.
pub const NmCustomDraw = extern struct {
    hdr: NmHdr,
    stage: DWORD,
    dc: HANDLE,
    rc: Rect,
    item: usize,
    item_state: u32,
    item_param: Lparam,
};

pub const NmLvCustomDraw = extern struct {
    nmcd: NmCustomDraw,
    text_color: ColorRef,
    text_bk_color: ColorRef,
    sub_item: i32,
    item_type: DWORD,
    face_color: ColorRef,
    icon_effect: i32,
    icon_phase: i32,
    part_id: i32,
    state_id: i32,
    text_rect: Rect,
    align_: u32,
};

/// What a list view says about a row it is reporting on. Only `sub_item`
/// matters here, and only for `LVN_COLUMNCLICK`, where it is the column.
pub const NmListView = extern struct {
    hdr: NmHdr,
    item: i32,
    sub_item: i32,
    new_state: u32,
    old_state: u32,
    changed: u32,
    action: Point,
    param: Lparam,
};

/// One column heading. The list view owns the header control, so its columns
/// are reachable both ways, and this is the way that carries the sort arrow.
pub const HdItem = extern struct {
    mask: u32 = 0,
    cxy: i32 = 0,
    text: ?[*:0]u16 = null,
    bitmap: ?HANDLE = null,
    text_max: i32 = 0,
    fmt: i32 = 0,
    param: Lparam = 0,
    image: i32 = 0,
    order: i32 = 0,
    kind: u32 = 0,
    filter: ?*anyopaque = null,
    state: u32 = 0,
};

/// Which row is under a point. `item` comes back as -1 when the answer is
/// none of them.
pub const LvHitTest = extern struct {
    pt: Point,
    flags: u32 = 0,
    item: i32 = 0,
    sub_item: i32 = 0,
    group: i32 = 0,
};

pub const CommonControlsInit = extern struct {
    size: u32 = @sizeOf(CommonControlsInit),
    icc: u32,
};

comptime {
    // The list view fills these in by pointer, so a wrong offset here is a
    // silent read of the wrong field rather than a compile error.
    std.debug.assert(@sizeOf(NmHdr) == 24);
    std.debug.assert(@offsetOf(NmLvDispInfo, "item") == 24);
    std.debug.assert(@offsetOf(LvItem, "text") == 24);
    std.debug.assert(@offsetOf(NmCustomDraw, "rc") == 40);
    std.debug.assert(@offsetOf(NmCustomDraw, "item_state") == 64);
    std.debug.assert(@sizeOf(NmCustomDraw) == 80);
    std.debug.assert(@offsetOf(NmLvCustomDraw, "text_color") == 80);
    std.debug.assert(@offsetOf(NmLvCustomDraw, "sub_item") == 88);
    std.debug.assert(@offsetOf(NmListView, "sub_item") == 28);
    std.debug.assert(@offsetOf(HdItem, "fmt") == 28);
    std.debug.assert(@sizeOf(HdItem) == 72);
}

// ---- window management ----

pub extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) callconv(.winapi) HANDLE;

pub extern "user32" fn RegisterClassExW(unnamedParam1: *const WndClassEx) callconv(.winapi) u16;

pub extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD,
    lpClassName: [*:0]const u16,
    lpWindowName: ?[*:0]const u16,
    dwStyle: DWORD,
    X: i32,
    Y: i32,
    nWidth: i32,
    nHeight: i32,
    hWndParent: ?HANDLE,
    hMenu: ?HANDLE,
    hInstance: ?HANDLE,
    lpParam: ?*anyopaque,
) callconv(.winapi) ?HANDLE;

pub extern "user32" fn DefWindowProcW(HANDLE, u32, Wparam, Lparam) callconv(.winapi) Lresult;
pub extern "user32" fn DestroyWindow(hWnd: HANDLE) callconv(.winapi) BOOL;
pub extern "user32" fn ShowWindow(hWnd: HANDLE, nCmdShow: i32) callconv(.winapi) BOOL;
pub extern "user32" fn UpdateWindow(hWnd: HANDLE) callconv(.winapi) BOOL;
pub extern "user32" fn PostQuitMessage(nExitCode: i32) callconv(.winapi) void;

pub extern "user32" fn GetMessageW(
    lpMsg: *Msg,
    hWnd: ?HANDLE,
    wMsgFilterMin: u32,
    wMsgFilterMax: u32,
) callconv(.winapi) BOOL;

pub extern "user32" fn TranslateMessage(lpMsg: *const Msg) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(lpMsg: *const Msg) callconv(.winapi) Lresult;
pub extern "user32" fn SendMessageW(HANDLE, u32, Wparam, Lparam) callconv(.winapi) Lresult;
pub extern "user32" fn PostMessageW(?HANDLE, u32, Wparam, Lparam) callconv(.winapi) BOOL;

pub extern "user32" fn SetWindowLongPtrW(hWnd: HANDLE, nIndex: i32, dwNewLong: isize) callconv(.winapi) isize;
pub extern "user32" fn GetWindowLongPtrW(hWnd: HANDLE, nIndex: i32) callconv(.winapi) isize;

pub extern "user32" fn MoveWindow(
    hWnd: HANDLE,
    X: i32,
    Y: i32,
    nWidth: i32,
    nHeight: i32,
    bRepaint: BOOL,
) callconv(.winapi) BOOL;

pub extern "user32" fn GetClientRect(hWnd: HANDLE, lpRect: *Rect) callconv(.winapi) BOOL;
pub extern "user32" fn InvalidateRect(hWnd: HANDLE, lpRect: ?*const Rect, bErase: BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn SetFocus(hWnd: ?HANDLE) callconv(.winapi) ?HANDLE;
pub extern "user32" fn LoadCursorW(hInstance: ?HANDLE, lpCursorName: [*:0]const u8) callconv(.winapi) ?HANDLE;
pub extern "user32" fn GetKeyState(nVirtKey: i32) callconv(.winapi) i16;
pub extern "user32" fn GetDpiForWindow(hwnd: HANDLE) callconv(.winapi) u32;
pub extern "user32" fn GetSystemMetrics(nIndex: i32) callconv(.winapi) i32;

pub extern "user32" fn LoadImageW(
    hInst: ?HANDLE,
    name: [*:0]align(1) const u16,
    image_type: u32,
    cx: i32,
    cy: i32,
    fuLoad: u32,
) callconv(.winapi) ?HANDLE;

pub extern "user32" fn SetTimer(
    hWnd: ?HANDLE,
    nIDEvent: usize,
    uElapse: u32,
    lpTimerFunc: ?*anyopaque,
) callconv(.winapi) usize;

pub extern "user32" fn KillTimer(hWnd: ?HANDLE, uIDEvent: usize) callconv(.winapi) BOOL;

pub extern "user32" fn CreatePopupMenu() callconv(.winapi) ?HANDLE;

pub extern "user32" fn InsertMenuW(
    hMenu: HANDLE,
    uPosition: u32,
    uFlags: u32,
    uIDNewItem: usize,
    lpNewItem: ?[*:0]const u16,
) callconv(.winapi) BOOL;

/// The bold entry, which is what a double click would have done.
pub extern "user32" fn SetMenuDefaultItem(
    hMenu: HANDLE,
    uItem: u32,
    fByPos: u32,
) callconv(.winapi) BOOL;

pub extern "user32" fn GetSystemMenu(hWnd: HANDLE, bRevert: BOOL) callconv(.winapi) ?HANDLE;
pub extern "user32" fn AppendMenuW(
    hMenu: HANDLE,
    uFlags: u32,
    uIDNewItem: usize,
    lpNewItem: ?[*:0]const u16,
) callconv(.winapi) BOOL;

pub const MF_STRING: u32 = 0x0000;
pub const MF_BYPOSITION: u32 = 0x0400;
pub const MF_SEPARATOR: u32 = 0x0800;

pub extern "user32" fn DestroyMenu(hMenu: HANDLE) callconv(.winapi) BOOL;
pub extern "user32" fn GetMenuItemCount(hMenu: ?HANDLE) callconv(.winapi) i32;

/// With TPM_RETURNCMD this returns the chosen command rather than a boolean,
/// and does not come back until the menu is gone.
pub extern "user32" fn TrackPopupMenuEx(
    hMenu: HANDLE,
    uFlags: u32,
    x: i32,
    y: i32,
    hwnd: HANDLE,
    lptpm: ?*anyopaque,
) callconv(.winapi) i32;

pub extern "user32" fn ScreenToClient(hWnd: HANDLE, lpPoint: *Point) callconv(.winapi) BOOL;
pub extern "user32" fn ClientToScreen(hWnd: HANDLE, lpPoint: *Point) callconv(.winapi) BOOL;

pub extern "user32" fn SetWindowPos(
    hWnd: HANDLE,
    hWndInsertAfter: ?HANDLE,
    X: i32,
    Y: i32,
    cx: i32,
    cy: i32,
    uFlags: u32,
) callconv(.winapi) BOOL;

pub const SWP_NOZORDER: u32 = 0x0004;
pub const SWP_NOACTIVATE: u32 = 0x0010;

pub extern "user32" fn GetWindowTextLengthW(hWnd: HANDLE) callconv(.winapi) i32;
pub extern "user32" fn GetWindowTextW(hWnd: HANDLE, lpString: [*]u16, nMaxCount: i32) callconv(.winapi) i32;
pub extern "user32" fn SetWindowTextW(hWnd: HANDLE, lpString: [*:0]const u16) callconv(.winapi) BOOL;

pub extern "user32" fn MessageBoxW(
    hWnd: ?HANDLE,
    lpText: [*:0]const u16,
    lpCaption: [*:0]const u16,
    uType: u32,
) callconv(.winapi) i32;

pub extern "user32" fn BeginPaint(hWnd: HANDLE, lpPaint: *PaintStruct) callconv(.winapi) ?HANDLE;
pub extern "user32" fn EndPaint(hWnd: HANDLE, lpPaint: *const PaintStruct) callconv(.winapi) BOOL;
pub extern "user32" fn FillRect(hDC: HANDLE, lprc: *const Rect, hbr: HANDLE) callconv(.winapi) i32;

pub extern "user32" fn DrawTextW(
    hdc: HANDLE,
    lpchText: [*]const u16,
    cchText: i32,
    lprc: *Rect,
    format: u32,
) callconv(.winapi) i32;

// ---- icons ----

/// What `SHGetFileInfoW` fills in. Only `icon_index` is read here, but the
/// whole thing has to be declared or the call writes past the end of it.
pub const ShFileInfo = extern struct {
    icon: ?HANDLE = null,
    icon_index: i32 = 0,
    attributes: u32 = 0,
    display_name: [260]u16 = undefined,
    type_name: [80]u16 = undefined,
};

comptime {
    std.debug.assert(@offsetOf(ShFileInfo, "icon_index") == 8);
    std.debug.assert(@sizeOf(ShFileInfo) == 696);
}

/// With `SHGFI_SYSICONINDEX` the return value is the shell's own image list,
/// which is shared across the process and must not be destroyed.
pub extern "shell32" fn SHGetFileInfoW(
    pszPath: [*:0]const u16,
    dwFileAttributes: DWORD,
    psfi: *ShFileInfo,
    cbFileInfo: u32,
    uFlags: u32,
) callconv(.winapi) usize;

pub const Guid = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

/// IID_IImageList. An `IImageList*` and an `HIMAGELIST` are documented as
/// interchangeable, so what comes back goes straight to the list view.
pub const IID_IImageList: Guid = .{
    .data1 = 0x46EB5926,
    .data2 = 0x582E,
    .data3 = 0x4017,
    .data4 = .{ 0x9F, 0xDF, 0xE8, 0x99, 0x8D, 0xAA, 0x09, 0x50 },
};

pub extern "shell32" fn SHGetImageList(
    iImageList: i32,
    riid: *const Guid,
    ppvObj: *?HANDLE,
) callconv(.winapi) HRESULT;

pub extern "comctl32" fn ImageList_Draw(
    himl: HANDLE,
    i: i32,
    hdcDst: HANDLE,
    x: i32,
    y: i32,
    fStyle: u32,
) callconv(.winapi) BOOL;

pub extern "comctl32" fn ImageList_GetIconSize(
    himl: HANDLE,
    cx: *i32,
    cy: *i32,
) callconv(.winapi) BOOL;

/// The icon index the shell holds for a file, rather than an icon handle of
/// our own to destroy afterwards.
pub const SHGFI_SYSICONINDEX: u32 = 0x0000_4000;
pub const SHGFI_SMALLICON: u32 = 0x0000_0001;
/// Answer from the name and the attributes alone. The file is never opened,
/// which is what makes the common case cheap enough to do while drawing.
pub const SHGFI_USEFILEATTRIBUTES: u32 = 0x0000_0010;

pub const FILE_ATTRIBUTE_DIRECTORY: DWORD = 0x0000_0010;
pub const FILE_ATTRIBUTE_NORMAL: DWORD = 0x0000_0080;

/// The shell small icon size, which follows SM_CXSMICON rather than being
/// fixed at 16 pixels, so it is already right on a scaled display.
pub const SHIL_SYSSMALL: i32 = 3;

pub const ILD_TRANSPARENT: u32 = 0x0000_0001;

pub const StockIconInfo = extern struct {
    size: DWORD = @sizeOf(StockIconInfo),
    icon: ?HANDLE = null,
    sys_image_index: i32 = 0,
    icon_index: i32 = 0,
    path: [260]u16 = undefined,
};

pub extern "shell32" fn SHGetStockIconInfo(
    siid: i32,
    uFlags: u32,
    psii: *StockIconInfo,
) callconv(.winapi) HRESULT;

/// The shield Windows puts on anything that asks for elevation.
pub const SIID_SHIELD: i32 = 77;
/// Answer with a place in the system image list rather than an icon to free.
pub const SHGSI_SYSICONINDEX: u32 = 0x0000_4000;
pub const SHGSI_SMALLICON: u32 = 0x0000_0001;

// ---- gdi ----

/// Only the first few fields matter here, but the rest have to be declared or
/// the call writes past the end of it.
pub const TextMetric = extern struct {
    height: i32,
    ascent: i32,
    descent: i32,
    internal_leading: i32,
    external_leading: i32,
    ave_char_width: i32,
    max_char_width: i32,
    weight: i32,
    overhang: i32,
    aspect_x: i32,
    aspect_y: i32,
    first_char: u16,
    last_char: u16,
    default_char: u16,
    break_char: u16,
    italic: u8,
    underlined: u8,
    struck_out: u8,
    pitch_and_family: u8,
    char_set: u8,
};

comptime {
    std.debug.assert(@sizeOf(TextMetric) == 60);
}

pub extern "user32" fn GetDC(hWnd: ?HANDLE) callconv(.winapi) ?HANDLE;
pub extern "user32" fn ReleaseDC(hWnd: ?HANDLE, hDC: HANDLE) callconv(.winapi) i32;
pub extern "gdi32" fn GetTextMetricsW(hdc: HANDLE, lptm: *TextMetric) callconv(.winapi) BOOL;

pub const Size = extern struct { cx: i32 = 0, cy: i32 = 0 };

/// How wide a run of text comes out in the font currently selected. What the
/// bolding needs, since it lays the runs of a cell out itself.
pub extern "gdi32" fn GetTextExtentPoint32W(
    hdc: HANDLE,
    lpString: [*]const u16,
    c: i32,
    psizl: *Size,
) callconv(.winapi) BOOL;

pub extern "gdi32" fn CreateSolidBrush(color: ColorRef) callconv(.winapi) ?HANDLE;
pub extern "gdi32" fn DeleteObject(ho: HANDLE) callconv(.winapi) BOOL;
pub extern "gdi32" fn SelectObject(hdc: HANDLE, h: HANDLE) callconv(.winapi) ?HANDLE;
pub extern "gdi32" fn SetTextColor(hdc: HANDLE, color: ColorRef) callconv(.winapi) ColorRef;
pub extern "gdi32" fn SetBkColor(hdc: HANDLE, color: ColorRef) callconv(.winapi) ColorRef;
pub extern "gdi32" fn SetBkMode(hdc: HANDLE, mode: i32) callconv(.winapi) i32;

pub extern "gdi32" fn CreateFontW(
    cHeight: i32,
    cWidth: i32,
    cEscapement: i32,
    cOrientation: i32,
    cWeight: i32,
    bItalic: DWORD,
    bUnderline: DWORD,
    bStrikeOut: DWORD,
    iCharSet: DWORD,
    iOutPrecision: DWORD,
    iClipPrecision: DWORD,
    iQuality: DWORD,
    iPitchAndFamily: DWORD,
    pszFaceName: [*:0]const u16,
) callconv(.winapi) ?HANDLE;

// ---- common controls ----

pub extern "comctl32" fn InitCommonControlsEx(picce: *const CommonControlsInit) callconv(.winapi) BOOL;

pub extern "comctl32" fn SetWindowSubclass(
    hWnd: HANDLE,
    pfnSubclass: SubclassProc,
    uIdSubclass: usize,
    dwRefData: usize,
) callconv(.winapi) BOOL;

pub extern "comctl32" fn DefSubclassProc(HANDLE, u32, Wparam, Lparam) callconv(.winapi) Lresult;

// ---- theming ----

pub extern "uxtheme" fn SetWindowTheme(
    hwnd: HANDLE,
    pszSubAppName: ?[*:0]const u16,
    pszSubIdList: ?[*:0]const u16,
) callconv(.winapi) HRESULT;

pub extern "dwmapi" fn DwmSetWindowAttribute(
    hwnd: HANDLE,
    dwAttribute: DWORD,
    pvAttribute: *const anyopaque,
    cbAttribute: DWORD,
) callconv(.winapi) HRESULT;

pub extern "advapi32" fn RegGetValueW(
    hkey: HANDLE,
    lpSubKey: ?[*:0]const u16,
    lpValue: ?[*:0]const u16,
    dwFlags: DWORD,
    pdwType: ?*DWORD,
    pvData: ?*anyopaque,
    pcbData: ?*DWORD,
) callconv(.winapi) i32;

pub extern "kernel32" fn LoadLibraryW(lpLibFileName: [*:0]const u16) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GetProcAddress(hModule: HANDLE, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;

pub const OsVersionInfo = extern struct {
    size: DWORD = @sizeOf(OsVersionInfo),
    major: DWORD = 0,
    minor: DWORD = 0,
    build: DWORD = 0,
    platform: DWORD = 0,
    csd: [128]u16 = @splat(0),
};

/// The only version call that still tells the truth. GetVersionExW reports
/// whatever the manifest claims support for, which is not what a check for a
/// particular build wants to know.
pub extern "ntdll" fn RtlGetVersion(lpVersionInformation: *OsVersionInfo) callconv(.winapi) i32;

// ---- constants ----

pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x8000_0000));
pub const IDC_ARROW: [*:0]const u8 = @ptrFromInt(32512);
pub const IDC_HAND: [*:0]const u8 = @ptrFromInt(32649);

pub extern "user32" fn SetCursor(hCursor: ?HANDLE) callconv(.winapi) ?HANDLE;
pub extern "user32" fn GetCursorPos(lpPoint: *Point) callconv(.winapi) BOOL;

/// The icon compiled in from elephant.rc. A resource named by number is passed
/// where a string pointer goes, which is what MAKEINTRESOURCE does in C.
/// Not aligned, because it is not really a pointer: an integer this small is
/// a resource number, and the loader checks the value before dereferencing.
pub const app_icon: [*:0]align(1) const u16 = @ptrFromInt(1);
pub const IMAGE_ICON: u32 = 1;

pub const SM_CXICON: i32 = 11;
pub const SM_CYICON: i32 = 12;
pub const SM_CXSMICON: i32 = 49;
pub const SM_CYSMICON: i32 = 50;

pub const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF_0000;
pub const WS_CHILD: DWORD = 0x4000_0000;
pub const WS_VISIBLE: DWORD = 0x1000_0000;
pub const WS_TABSTOP: DWORD = 0x0001_0000;
pub const WS_CLIPCHILDREN: DWORD = 0x0200_0000;

pub const ES_AUTOHSCROLL: DWORD = 0x0080;

pub const SW_SHOW: i32 = 5;

pub const MB_OK: u32 = 0x0000;
pub const MB_ICONERROR: u32 = 0x0010;
pub const MB_ICONINFORMATION: u32 = 0x0040;

pub const GWLP_USERDATA: i32 = -21;

pub const WM_DESTROY: u32 = 0x0002;
pub const WM_SIZE: u32 = 0x0005;
pub const WM_SETFOCUS: u32 = 0x0007;
pub const WM_PAINT: u32 = 0x000F;
pub const WM_ERASEBKGND: u32 = 0x0014;
pub const WM_SETTINGCHANGE: u32 = 0x001A;
pub const WM_SETFONT: u32 = 0x0030;
pub const WM_NOTIFY: u32 = 0x004E;
pub const WM_LBUTTONDOWN: u32 = 0x0201;
pub const WM_SETCURSOR: u32 = 0x0020;
pub const WM_SYSCOMMAND: u32 = 0x0112;
/// What WM_SETCURSOR carries in its low word when the pointer is over the
/// client area rather than a border or the title bar.
pub const HTCLIENT: u16 = 1;
pub const WM_KEYDOWN: u32 = 0x0100;
pub const WM_CHAR: u32 = 0x0102;
pub const WM_COMMAND: u32 = 0x0111;
pub const WM_TIMER: u32 = 0x0113;
pub const WM_CTLCOLOREDIT: u32 = 0x0133;
pub const WM_CTLCOLORSTATIC: u32 = 0x0138;
pub const WM_DPICHANGED: u32 = 0x02E0;
pub const WM_APP: u32 = 0x8000;

// The four the shell's own menu draws itself with, which have to reach it
// while its menu is on screen or the submenus come up empty.
pub const WM_DRAWITEM: u32 = 0x002B;
pub const WM_MEASUREITEM: u32 = 0x002C;
pub const WM_INITMENUPOPUP: u32 = 0x0117;
pub const WM_MENUCHAR: u32 = 0x0120;
pub const WM_CONTEXTMENU: u32 = 0x007B;

pub const TPM_LEFTALIGN: u32 = 0x0000;
pub const TPM_RIGHTBUTTON: u32 = 0x0002;
pub const TPM_RETURNCMD: u32 = 0x0100;

pub const EN_CHANGE: u16 = 0x0300;
pub const EM_GETSEL: u32 = 0x00B0;
pub const EM_SETSEL: u32 = 0x00B1;
pub const EM_REPLACESEL: u32 = 0x00C2;
/// ECM_FIRST + 1. The grey placeholder an empty search box shows.
pub const EM_SETCUEBANNER: u32 = 0x1501;

pub const VK_SHIFT: i32 = 0x10;
/// The menu key, and the F10 that shift turns into one.
pub const VK_APPS: u16 = 0x5D;
pub const VK_F10: u16 = 0x79;
pub const VK_CONTROL: i32 = 0x11;

pub const TRANSPARENT: i32 = 1;

pub const DT_LEFT: u32 = 0x0000;
pub const DT_RIGHT: u32 = 0x0002;
pub const DT_VCENTER: u32 = 0x0004;
pub const DT_SINGLELINE: u32 = 0x0020;
pub const DT_NOPREFIX: u32 = 0x0800;
pub const DT_END_ELLIPSIS: u32 = 0x8000;
/// Skips the clip against the rectangle, for text already measured to fit.
pub const DT_NOCLIP: u32 = 0x0100;

pub const FW_NORMAL: i32 = 400;
pub const FW_BOLD: i32 = 700;
pub const DEFAULT_CHARSET: DWORD = 1;
pub const OUT_DEFAULT_PRECIS: DWORD = 0;
pub const CLIP_DEFAULT_PRECIS: DWORD = 0;
pub const CLEARTYPE_QUALITY: DWORD = 5;
pub const DEFAULT_PITCH: DWORD = 0;

pub const ICC_LISTVIEW_CLASSES: u32 = 0x0000_0001;

pub const WC_LISTVIEW = std.unicode.utf8ToUtf16LeStringLiteral("SysListView32");
pub const WC_EDIT = std.unicode.utf8ToUtf16LeStringLiteral("EDIT");

pub const LVS_REPORT: DWORD = 0x0001;
pub const LVS_SINGLESEL: DWORD = 0x0004;
pub const LVS_SHOWSELALWAYS: DWORD = 0x0008;
pub const LVS_OWNERDATA: DWORD = 0x1000;
pub const LVS_NOSORTHEADER: DWORD = 0x8000;
pub const LVS_EDITLABELS: DWORD = 0x0200;

pub const LVS_EX_FULLROWSELECT: u32 = 0x0000_0020;
pub const LVS_EX_LABELTIP: u32 = 0x0000_4000;
pub const LVS_EX_DOUBLEBUFFER: u32 = 0x0001_0000;

const LVM_FIRST: u32 = 0x1000;
pub const LVM_SETBKCOLOR = LVM_FIRST + 1;
pub const LVM_SETIMAGELIST = LVM_FIRST + 3;
pub const LVM_GETSUBITEMRECT = LVM_FIRST + 56;
pub const LVM_GETNEXTITEM = LVM_FIRST + 12;
pub const LVM_GETITEMRECT = LVM_FIRST + 14;
pub const LVM_HITTEST = LVM_FIRST + 18;
pub const LVM_ENSUREVISIBLE = LVM_FIRST + 19;
pub const LVM_GETCOLUMNWIDTH = LVM_FIRST + 29;
pub const LVM_SETCOLUMNWIDTH = LVM_FIRST + 30;
pub const LVM_SETTEXTCOLOR = LVM_FIRST + 36;
pub const LVM_SETTEXTBKCOLOR = LVM_FIRST + 38;
pub const LVM_GETCOUNTPERPAGE = LVM_FIRST + 40;
pub const LVM_SETITEMSTATE = LVM_FIRST + 43;
pub const LVM_GETITEMSTATE = LVM_FIRST + 44;
pub const LVM_SETITEMCOUNT = LVM_FIRST + 47;
pub const LVM_SETEXTENDEDLISTVIEWSTYLE = LVM_FIRST + 54;
pub const LVM_GETHEADER = LVM_FIRST + 31;
pub const LVM_INSERTCOLUMNW = LVM_FIRST + 97;
pub const LVM_EDITLABELW = LVM_FIRST + 118;

/// Sent with `LVM_SETITEMCOUNT`. Without it the control takes a new count as
/// reason to go back to the top, which throws away wherever the list had been
/// scrolled to.
pub const LVSICF_NOSCROLL: Lparam = 0x0000_0002;

pub const LVIF_TEXT: u32 = 0x0001;
pub const LVIF_IMAGE: u32 = 0x0002;
/// The 16 pixel icons a report view draws beside the first column.
pub const LVSIL_SMALL: Wparam = 1;
pub const LVIS_FOCUSED: u32 = 0x0001;
pub const LVIS_SELECTED: u32 = 0x0002;
pub const LVNI_SELECTED: u32 = 0x0002;

pub const LVCF_FMT: u32 = 0x0001;
pub const LVCF_WIDTH: u32 = 0x0002;
pub const LVCF_TEXT: u32 = 0x0004;
pub const LVCF_SUBITEM: u32 = 0x0008;
pub const LVCFMT_LEFT: i32 = 0;
pub const LVCFMT_RIGHT: i32 = 1;

const HDM_FIRST: u32 = 0x1200;
pub const HDM_GETITEMW = HDM_FIRST + 11;
pub const HDM_SETITEMW = HDM_FIRST + 12;

pub const HDI_FORMAT: u32 = 0x0004;
/// The triangle a heading shows to say the list is sorted on it. Which way up
/// it points is the whole of the difference.
pub const HDF_SORTDOWN: i32 = 0x0200;
pub const HDF_SORTUP: i32 = 0x0400;

/// Notification codes are unsigned but counted downwards from zero, so they
/// only read as small negatives.
fn code(n: i32) u32 {
    return @bitCast(n);
}

pub const LVN_ITEMCHANGED = code(-100 - 1);
pub const LVN_COLUMNCLICK = code(-100 - 8);
pub const LVN_GETDISPINFOW = code(-100 - 77);
pub const LVN_BEGINLABELEDITW = code(-100 - 75);
pub const LVN_ENDLABELEDITW = code(-100 - 76);
pub const NM_DBLCLK = code(-3);
pub const NM_RETURN = code(-4);
pub const NM_CUSTOMDRAW = code(-12);

pub const CDDS_PREPAINT: DWORD = 0x0000_0001;
pub const CDDS_ITEM: DWORD = 0x0001_0000;
pub const CDDS_ITEMPREPAINT: DWORD = CDDS_ITEM | CDDS_PREPAINT;
pub const CDDS_SUBITEM: DWORD = 0x0002_0000;
pub const CDDS_SUBITEMPREPAINT: DWORD = CDDS_SUBITEM | CDDS_ITEMPREPAINT;

pub const CDRF_DODEFAULT: Lresult = 0x0000_0000;
pub const CDRF_NEWFONT: Lresult = 0x0000_0002;
pub const CDRF_SKIPDEFAULT: Lresult = 0x0000_0004;
pub const CDRF_NOTIFYITEMDRAW: Lresult = 0x0000_0020;
/// The same value as `CDRF_NOTIFYITEMDRAW`, which is not a mistake: which of
/// the two it means is decided by the stage it is returned from.
pub const CDRF_NOTIFYSUBITEMDRAW: Lresult = 0x0000_0020;

pub const CDIS_SELECTED: u32 = 0x0001;
pub const CDIS_FOCUS: u32 = 0x0010;

/// "no colour", which for a text background means let what is behind show
/// through instead of filling it.
pub const CLR_NONE: ColorRef = 0xFFFF_FFFF;

pub const LVIR_BOUNDS: i32 = 0;
pub const LVIR_ICON: i32 = 1;
pub const LVIR_LABEL: i32 = 2;

/// Dark title bar. The attribute was 19 while it was still undocumented and
/// became 20 in Windows 10 2004, and setting the wrong one is a failed call
/// rather than a wrong window, so both get a try.
pub const DWMWA_USE_IMMERSIVE_DARK_MODE: DWORD = 20;
pub const DWMWA_USE_IMMERSIVE_DARK_MODE_OLD: DWORD = 19;

pub const HKEY_CURRENT_USER = w.HKEY_CURRENT_USER;
pub const RRF_RT_REG_DWORD: DWORD = 0x0000_0018;
pub const ERROR_SUCCESS = w.ERROR_SUCCESS;
