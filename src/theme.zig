//! Dark mode.
//!
//! Windows documents two parts of this and no more: a registry value holding
//! which way the user set the switch, and a DWM attribute that darkens the
//! title bar. The rest -- a dark scrollbar down the side of the results, a dark
//! context menu -- lives behind uxtheme entry points that ship with no names,
//! only ordinals. Every application with a dark mode calls them, because there
//! is nothing else to call.
//!
//! So each one is looked up by ordinal, only on the builds that are known to
//! have it, and every result is allowed to be null. A future Windows that drops
//! them leaves the documented path intact: the title bar and the colours this
//! program picks itself still go dark, and the scrollbar stays light. That is
//! worse than it should look, but it is not a crash.

const std = @import("std");
const ui = @import("win32_ui.zig");

pub const Colors = struct {
    /// Behind the search box and the status line, which this program paints.
    window: ui.ColorRef,
    /// Behind the results, which the list view paints.
    list: ui.ColorRef,
    text: ui.ColorRef,
    /// Second-rank text: the status line and the timing.
    dim: ui.ColorRef,
    /// Inside the search box.
    field: ui.ColorRef,
    /// The rule above the status line and the border round the search box.
    line: ui.ColorRef,
    /// Behind the selected result. Painted here rather than left to the theme,
    /// which draws a barely-there grey while the search box holds the focus --
    /// and the search box holds the focus almost always, since that is where
    /// the typing goes. The selected row is what enter opens, so it has to be
    /// legible at a glance whatever has the caret.
    select: ui.ColorRef,
    select_text: ui.ColorRef,
    /// Text in the status line that does something when clicked.
    link: ui.ColorRef,
};

pub const light: Colors = .{
    .window = ui.rgb(243, 243, 243),
    .list = ui.rgb(255, 255, 255),
    .text = ui.rgb(0, 0, 0),
    .dim = ui.rgb(96, 96, 96),
    .field = ui.rgb(255, 255, 255),
    .line = ui.rgb(217, 217, 217),
    .select = ui.rgb(205, 232, 255),
    .select_text = ui.rgb(0, 0, 0),
    .link = ui.rgb(0, 95, 184),
};

pub const dark: Colors = .{
    .window = ui.rgb(32, 32, 32),
    .list = ui.rgb(32, 32, 32),
    .text = ui.rgb(240, 240, 240),
    .dim = ui.rgb(155, 155, 155),
    .field = ui.rgb(45, 45, 45),
    .line = ui.rgb(64, 64, 64),
    .select = ui.rgb(38, 79, 120),
    .select_text = ui.rgb(255, 255, 255),
    .link = ui.rgb(96, 205, 255),
};

/// Reads the switch in Settings. Not `ShouldAppsUseDarkMode`, which is another
/// nameless ordinal and answers the same question the registry does in writing.
pub fn prefersDark() bool {
    const key = std.unicode.utf8ToUtf16LeStringLiteral(
        "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
    );
    const name = std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme");

    var value: ui.DWORD = 1;
    var size: ui.DWORD = @sizeOf(ui.DWORD);
    const rc = ui.RegGetValueW(
        ui.HKEY_CURRENT_USER,
        key,
        name,
        ui.RRF_RT_REG_DWORD,
        null,
        &value,
        &size,
    );
    // Missing on a fresh profile, where light is the default.
    if (rc != ui.ERROR_SUCCESS) return false;
    return value == 0;
}

// ---- the undocumented half ----

/// What `SetPreferredAppMode` takes. This is process wide and decides the
/// parts no window owns: the title bar and the shell's own menus. Following
/// the system switch is `allow_dark`; the two forced modes are what an
/// explicit choice needs, since a window pinned to light on a dark machine
/// would otherwise keep a dark title bar around a light window.
pub const PreferredAppMode = enum(i32) {
    default = 0,
    allow_dark = 1,
    force_dark = 2,
    force_light = 3,
};

const SetPreferredAppModeFn = *const fn (PreferredAppMode) callconv(.winapi) PreferredAppMode;
const AllowDarkModeForWindowFn = *const fn (ui.HANDLE, ui.BOOL) callconv(.winapi) ui.BOOL;
const FlushMenuThemesFn = *const fn () callconv(.winapi) void;
const RefreshImmersiveColorPolicyStateFn = *const fn () callconv(.winapi) void;

var set_preferred_app_mode: ?SetPreferredAppModeFn = null;
var allow_dark_mode_for_window: ?AllowDarkModeForWindowFn = null;
var flush_menu_themes: ?FlushMenuThemesFn = null;
var refresh_color_policy: ?RefreshImmersiveColorPolicyStateFn = null;

/// The build that first shipped any of this. Below it the ordinals mean
/// something else entirely, so they are not asked for at all.
const first_dark_build: ui.DWORD = 17763;

fn ordinal(module: ui.HANDLE, n: u16) ?*anyopaque {
    return ui.GetProcAddress(module, @ptrFromInt(n));
}

/// Looks the entry points up and puts the process into the mode asked for.
/// Call once, before any window exists.
pub fn init(mode: PreferredAppMode) void {
    var version: ui.OsVersionInfo = .{};
    if (ui.RtlGetVersion(&version) != 0) return;
    if (version.build < first_dark_build) return;

    const name = std.unicode.utf8ToUtf16LeStringLiteral("uxtheme.dll");
    const module = ui.LoadLibraryW(name) orelse return;

    // 135 was AllowDarkModeForApp(BOOL) in 1809 and became
    // SetPreferredAppMode(enum) in 1903. `allow_dark` is 1, which reads as
    // `true` to the older one, so the common case works on both. The forced
    // modes are 2 and 3, which that older call reads as true as well, so a
    // 1809 machine follows its own switch rather than an override.
    set_preferred_app_mode = @ptrCast(ordinal(module, 135));
    allow_dark_mode_for_window = @ptrCast(ordinal(module, 133));
    refresh_color_policy = @ptrCast(ordinal(module, 104));
    flush_menu_themes = @ptrCast(ordinal(module, 136));

    if (set_preferred_app_mode) |f| _ = f(mode);
    if (refresh_color_policy) |f| f();
}

/// Marks one window as allowed to draw itself dark, which the themed scrollbars
/// and the title bar both check before they do.
pub fn allowDark(hwnd: ui.HANDLE, on: bool) void {
    if (allow_dark_mode_for_window) |f| _ = f(hwnd, @intFromBool(on));
}

/// Colours the title bar and the frame. Attribute 20 is the documented one;
/// 19 is what the same setting was called before Windows 10 2004, and asking
/// for the wrong one fails instead of doing something else.
pub fn titleBar(hwnd: ui.HANDLE, on: bool) void {
    const want: ui.BOOL = @intFromBool(on);
    if (ui.DwmSetWindowAttribute(
        hwnd,
        ui.DWMWA_USE_IMMERSIVE_DARK_MODE,
        &want,
        @sizeOf(ui.BOOL),
    ) >= 0) return;
    _ = ui.DwmSetWindowAttribute(
        hwnd,
        ui.DWMWA_USE_IMMERSIVE_DARK_MODE_OLD,
        &want,
        @sizeOf(ui.BOOL),
    );
}

/// Which of the shell's own themes a control should draw with. The dark ones
/// are only present once `init` has run, and asking for a theme that is not
/// there leaves the control unthemed rather than failing.
pub const Style = enum {
    /// Rows and the scrollbar beside them.
    explorer,
    /// A list view's column headers.
    items_view,
    /// The border around a text field.
    field,
};

/// The theme name is the same either way. `allowDark` is what decides which
/// one a control actually gets: uxtheme keeps a dark twin of each of these
/// classes and hands it to any window that has been marked. Asking for
/// "DarkMode_Explorer" by name looks like it should do the same thing and does
/// not -- it darkens the scrollbar and leaves the rows in the light theme,
/// because there is no dark LISTVIEW part under that class to find.
pub fn style(hwnd: ui.HANDLE, which: Style, want_dark: bool) void {
    allowDark(hwnd, want_dark);
    const name = switch (which) {
        .explorer => std.unicode.utf8ToUtf16LeStringLiteral("Explorer"),
        .items_view => std.unicode.utf8ToUtf16LeStringLiteral("ItemsView"),
        // What the combo box and the edit field share.
        .field => std.unicode.utf8ToUtf16LeStringLiteral("CFD"),
    };
    _ = ui.SetWindowTheme(hwnd, name, null);
}

/// Re-reads the system switch after it changes. Menus cache their colours, so
/// they have to be told separately.
pub fn refresh() void {
    if (refresh_color_policy) |f| f();
    if (flush_menu_themes) |f| f();
}

// ---- brushes ----

/// The colours in use plus the GDI brushes that go with them, so a repaint does
/// not create and destroy a brush per frame.
pub const Palette = struct {
    dark: bool = false,
    c: Colors = light,
    window_brush: ?ui.HANDLE = null,
    field_brush: ?ui.HANDLE = null,
    line_brush: ?ui.HANDLE = null,
    select_brush: ?ui.HANDLE = null,

    /// Returns true when the theme actually changed, which is the caller's cue
    /// to re-theme its controls and repaint.
    pub fn set(self: *Palette, want_dark: bool) bool {
        if (self.window_brush != null and self.dark == want_dark) return false;
        self.free();
        self.dark = want_dark;
        self.c = if (want_dark) dark else light;
        self.window_brush = ui.CreateSolidBrush(self.c.window);
        self.field_brush = ui.CreateSolidBrush(self.c.field);
        self.line_brush = ui.CreateSolidBrush(self.c.line);
        self.select_brush = ui.CreateSolidBrush(self.c.select);
        return true;
    }

    pub fn free(self: *Palette) void {
        for ([_]*?ui.HANDLE{
            &self.window_brush,
            &self.field_brush,
            &self.line_brush,
            &self.select_brush,
        }) |slot| {
            if (slot.*) |h| _ = ui.DeleteObject(h);
            slot.* = null;
        }
    }
};
