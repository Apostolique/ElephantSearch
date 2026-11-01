//! Desktop window front end.
//!
//! A search box above a virtual list view. Virtual because a broad query
//! matches over a million files and handing the control a row each would cost
//! more than the search did; instead it asks for the handful it is about to
//! draw and `LVN_GETDISPINFOW` builds those on the spot.
//!
//! Reading the drives happens on its own thread, so the window is up and
//! honest about what it is doing within a frame of being asked for. Nothing
//! else here is threaded: a cold search costs about 20 ms and narrowing costs
//! single-digit milliseconds, which is under a frame either way.

const std = @import("std");
const w = @import("win32.zig");
const ui = @import("win32_ui.zig");
const highlight = @import("highlight.zig");
const icons_mod = @import("icons.zig");
const idx = @import("index.zig");
const mft = @import("mft.zig");
const search = @import("search.zig");
const shell = @import("shell.zig");
const shellmenu = @import("shellmenu.zig");
const sizer_mod = @import("sizer.zig");
const startup = @import("startup.zig");
const theme = @import("theme.zig");
const usn = @import("usn.zig");
const explorer = @import("explorer.zig");
const install = @import("install.zig");
const pipe = @import("pipe.zig");
const placement = @import("placement.zig");

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ElephantSearchWindow");
const app_name = std.unicode.utf8ToUtf16LeStringLiteral("ElephantSearch");
const cue_banner = std.unicode.utf8ToUtf16LeStringLiteral("Search every drive");

/// Results ranked before scrolling has to ask for more.
const pool: usize = 500;

/// How often the change journal and the size pass get a look in.
const tick_ms: u32 = 250;
const tick_id: usize = 1;

/// Least time between two searches caused by the journal rather than by a
/// keystroke. A busy machine writes files continuously, and re-running a query
/// over three million entries for each one would burn a core to show nothing.
const change_settle_ms: u64 = 1000;

/// Posted by the loader thread once the index is up.
const wm_indexed: u32 = ui.WM_APP + 1;
/// Posted by the icon worker once a file's own icon has been read off the
/// disk. Coalesced at the other end, so a screenful arriving together costs
/// one of these rather than thirty.
const wm_icon: u32 = ui.WM_APP + 2;
/// Posted by the installer thread once the elevated install has finished,
/// with its outcome in `wparam`.
const wm_installed: u32 = ui.WM_APP + 3;

const id_edit: usize = 100;
const id_list: usize = 101;
/// The window menu entry that starts this program over with administrator
/// rights. The system keeps the low four bits of a window menu command for
/// itself, and everything from 0xF000 up.
const id_elevate: usize = 0x0010;
/// The same for installing the service.
const id_install: usize = 0x0020;

const elevate_label = "Run as administrator";
const install_label = "Install the service";

/// Runs of matched and unmatched characters a cell is drawn in. A query that
/// alternates more often than this is not one anyone is reading letter by
/// letter, and the tail joins the last run rather than going missing.
const max_runs: usize = 48;

/// How a cell's text is laid out: one line, centred down the row, and no
/// ampersand quietly turning into an underline.
const text_flags: u32 = ui.DT_SINGLELINE | ui.DT_VCENTER | ui.DT_NOPREFIX;

/// Which way round to draw. `system` follows the switch in Settings and keeps
/// following it, so changing it while the window is open changes the window.
pub const Appearance = enum { system, light, dark };

pub const Options = struct {
    startup: startup.Options = .{},
    kind: search.Kind = .fuzzy,
    under: ?[]const u8 = null,
    appearance: Appearance = .system,
    /// A service pipe to read through instead of the installed one's.
    service_pipe: ?[:0]const u16 = null,
};

/// Which characters of a row the query matched, worked out once for the row
/// rather than once for each of its columns. The list view asks for a row's
/// columns one after another, so the path only gets built once however many
/// of them end up reading it.
const RowMarks = struct {
    /// Which search this was worked out against. The same row can hold the
    /// same file after a keystroke and still have matched somewhere else.
    stamp: u32 = 0,
    row: usize = std.math.maxInt(usize),
    entry: u32 = 0,
    /// Where the name starts inside what was marked, which is the whole path
    /// in path mode and the name itself in name mode.
    name_at: usize = 0,
    /// Whether the directory column has any of this to draw. A name-mode
    /// search matched names and nothing else, and bolding letters in a
    /// directory it never compared against would point at a coincidence.
    covers_path: bool = false,
    marks: highlight.Marks = .{},
};

const Column = struct {
    title: []const u8,
    /// Share of the list's width, out of the total across all columns.
    weight: u32,
    /// What clicking the heading sorts the list by.
    sort: search.SortBy,
    right: bool = false,
    /// Which way the first click on it goes. Names read A to Z, but nobody
    /// clicking Size wants the empty files first, or the oldest file on the
    /// drive from Modified.
    descending_first: bool = false,
};

const columns = [_]Column{
    .{ .title = "Name", .weight = 26, .sort = .name },
    .{ .title = "Path", .weight = 48, .sort = .path },
    .{ .title = "Size", .weight = 11, .sort = .size, .right = true, .descending_first = true },
    .{ .title = "Modified", .weight = 15, .sort = .modified, .descending_first = true },
};

/// Runs the window until it is closed. Owns the index for its whole life,
/// because the loader thread writes into it and the message loop reads it.
pub fn run(gpa: std.mem.Allocator, opts: Options) !void {
    // Before any window exists, so the first one is already the right way
    // round rather than flipping once it is on screen.
    theme.init(switch (opts.appearance) {
        .system => .allow_dark,
        .light => .force_light,
        .dark => .force_dark,
    });
    var icc: ui.CommonControlsInit = .{ .icc = ui.ICC_LISTVIEW_CLASSES };
    _ = ui.InitCommonControlsEx(&icc);

    // The shell's context menu runs on the thread that shows it, and wants COM
    // up for as long as the window is there to show one. S_FALSE means it
    // already was, and both of those still owe an uninitialise.
    const com = w.CoInitializeEx(null, w.COINIT_APARTMENTTHREADED);
    defer if (com >= 0) w.CoUninitialize();

    var index = idx.Index.init(gpa);
    defer index.deinit();

    var searcher = search.Searcher.init(gpa, &index);
    defer searcher.deinit();
    searcher.default_kind = opts.kind;

    // A few milliseconds at most, since all it does is knock on the pipe.
    const choice: pipe.Choice = if (opts.startup.synthetic > 0)
        .{ .source = .direct, .service = .elevated }
    else
        pipe.choose(gpa, shell.isElevated(), if (opts.service_pipe) |name| .{ .name = name, .verify = false } else null);
    var chosen = opts;
    chosen.startup.source = choice.source;
    chosen.startup.use_cache = opts.service_pipe == null;

    var monitor = usn.Monitor.init(gpa, &index, choice.source);
    defer monitor.deinit();

    var sizer = sizer_mod.Sizer.init(gpa, &index, choice.source);
    defer sizer.stop();

    var iconry = icons_mod.Icons.init(gpa);
    defer iconry.deinit();

    var win: Window = .{
        .gpa = gpa,
        .opts = chosen,
        .service = choice.service,
        .index = &index,
        .searcher = &searcher,
        .monitor = &monitor,
        .sizer = &sizer,
        .icons = &iconry,
        .since_change = w.Timer.start(),
    };
    defer win.deinit();

    try win.create();
    try win.startLoading();

    var msg: ui.Msg = undefined;
    while (ui.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = ui.TranslateMessage(&msg);
        _ = ui.DispatchMessageW(&msg);
    }

    // Closing the window does not stop a scan already under way, and the index
    // it is writing into is about to be freed, so this waits it out.
    win.joinLoader();
    win.joinInstaller();

    monitor.stop();
    sizer.stop();
    _ = monitor.drain() catch 0;
    if (win.loaded) startup.saveCache(&index, win.ready, gpa);
}

const Window = struct {
    gpa: std.mem.Allocator,
    opts: Options,
    index: *idx.Index,
    searcher: *search.Searcher,
    monitor: *usn.Monitor,
    sizer: *sizer_mod.Sizer,
    icons: *icons_mod.Icons,

    hwnd: ui.HANDLE = undefined,
    edit: ui.HANDLE = undefined,
    list: ui.HANDLE = undefined,
    /// The list view's own column headings, which are a control in their own
    /// right and need theming and drawing separately from it.
    header: ?ui.HANDLE = null,
    font: ?ui.HANDLE = null,
    /// The same face and size as `font`, for the characters a query matched.
    bold: ?ui.HANDLE = null,
    palette: theme.Palette = .{},
    menu: shellmenu.Menu = .{},
    /// The entry whose name the list view has open for editing, if any. A
    /// search underneath would throw the editor away, so this also says when
    /// one has to wait.
    ///
    /// The entry rather than the row it sits on: the rename is carried out
    /// when the editor closes, and by then the results can have been rebuilt
    /// under it, which would leave the same row standing for another file.
    renaming: ?u32 = null,
    dpi: u32 = 96,
    /// Set while the window is being put back where it last closed. The
    /// saved rect is already the right size for the screen it is on, so a
    /// scaling change on the way there must not resize it again.
    placing: bool = false,
    /// The window's rect the last time it was neither maximized nor
    /// minimized, in screen coordinates. Kept because a window snapped to an
    /// edge still reports its rect from before the snap as its normal one.
    shown_at: ?ui.Rect = null,
    /// One line of the interface font, in pixels. What the search box is
    /// sized from.
    line_height: i32 = 16,

    /// Set once the index is up and searching is allowed to touch it.
    ready_to_search: bool = false,
    /// Whether this process could gain administrator rights by asking, which
    /// is all of them except one already running with them.
    can_elevate: bool = false,
    /// Set by the loader once a drive has refused for want of administrator
    /// rights, which is what puts the offer to restart with them on screen.
    wants_admin: std.atomic.Value(bool) = .init(false),
    /// Where the offer was last drawn, so a click and the pointer can find it.
    /// Empty while it is not on screen.
    elevate_rect: ui.Rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    /// Whether the service answered, and so whether installing it is worth
    /// offering next to the restart.
    service: pipe.Choice.State = .missing,
    /// Set when installing the service would get this window reading the
    /// drives without being restarted elevated.
    can_install: bool = false,
    install_rect: ui.Rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    installer: ?std.Thread = null,
    /// Set from the start of the size pass until the tick after it ends, so
    /// the rows on screen get drawn once more with whatever landed last.
    sizes_unseen: bool = false,
    /// The shield's place in the shell's small image list.
    shield: ?i32 = null,
    /// Set when the index was built without a drive failing, which is the only
    /// state worth saving.
    loaded: bool = false,
    ready: startup.Ready = .{},

    loader: ?std.Thread = null,
    /// Guards `progress`, which the loader thread writes and the message loop
    /// reads on its next tick.
    progress_lock: w.Lock = .{},
    progress: [192]u8 = undefined,
    progress_len: usize = 0,

    results: []const search.Match = &.{},
    since_change: w.Timer,
    /// One-off message shown in place of the status until the next keystroke.
    note: [192]u8 = undefined,
    note_len: usize = 0,

    /// Where a row's text is built. The list view copies it out before the next
    /// `LVN_GETDISPINFOW`, so one buffer serves every row.
    cell: [2048]u16 = undefined,
    /// The same for drawing, which happens between one `LVN_GETDISPINFOW` and
    /// the next and so cannot share the buffer above.
    drawn: [2048]u16 = undefined,
    query: std.ArrayList(u8) = .empty,

    /// The query as the matcher sees it, kept so the bolding does not have to
    /// parse it again inside every paint. Null when there is nothing to bold.
    parsed: ?search.Query = null,
    /// Bumped whenever what the rows mean changes, which is what tells the
    /// marks below that they are stale even though the row is the same one.
    stamp: u32 = 0,
    marks: RowMarks = .{},
    /// Whether the row being drawn is the selected one, taken once at the top
    /// of the row and read by each of its columns.
    row_selected: bool = false,

    // ---- setting up ----

    fn create(self: *Window) !void {
        const instance = ui.GetModuleHandleW(null);
        // Two sizes rather than one scaled: the title bar and the alt+tab
        // switcher ask for different ones, and the icon has a drawing of each.
        const class: ui.WndClassEx = .{
            .proc = wndProc,
            .instance = instance,
            .cursor = ui.LoadCursorW(null, ui.IDC_ARROW),
            .icon = loadIcon(instance, ui.SM_CXICON, ui.SM_CYICON),
            .small_icon = loadIcon(instance, ui.SM_CXSMICON, ui.SM_CYSMICON),
            .class_name = class_name,
        };
        if (ui.RegisterClassExW(&class) == 0) return error.NoWindowClass;

        // Not visible yet: the children, the fonts and the theme all have to be
        // in place first, or the window flashes light before it turns dark.
        const hwnd = ui.CreateWindowExW(
            0,
            class_name,
            app_name,
            ui.WS_OVERLAPPEDWINDOW | ui.WS_CLIPCHILDREN,
            ui.CW_USEDEFAULT,
            ui.CW_USEDEFAULT,
            980,
            620,
            null,
            null,
            instance,
            null,
        ) orelse return error.NoWindow;
        self.hwnd = hwnd;
        _ = ui.SetWindowLongPtrW(hwnd, ui.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

        self.can_elevate = !shell.isElevated();
        self.can_install = self.can_elevate and self.opts.service_pipe == null and
            (self.service == .missing or self.service == .outdated);
        if (self.can_elevate) {
            // In the window menu as well as in the status line, so it can be
            // reached from the keyboard with alt+space.
            if (ui.GetSystemMenu(hwnd, 0)) |sys| {
                _ = ui.AppendMenuW(sys, ui.MF_SEPARATOR, 0, null);
                if (self.can_install) {
                    const install_text = std.unicode.utf8ToUtf16LeStringLiteral(install_label);
                    _ = ui.AppendMenuW(sys, ui.MF_STRING, id_install, install_text);
                }
                const label = std.unicode.utf8ToUtf16LeStringLiteral(elevate_label);
                _ = ui.AppendMenuW(sys, ui.MF_STRING, id_elevate, label);
            }
            var info: ui.StockIconInfo = .{};
            if (ui.SHGetStockIconInfo(ui.SIID_SHIELD, ui.SHGSI_SYSICONINDEX | ui.SHGSI_SMALLICON, &info) >= 0) {
                self.shield = info.sys_image_index;
            }
        }

        self.dpi = blk: {
            const got = ui.GetDpiForWindow(hwnd);
            break :blk if (got == 0) 96 else got;
        };

        // No WS_EX_CLIENTEDGE: the sunken 3D edge is non-client and stays the
        // system's light grey whatever the theme is. A flat rule painted with
        // the rest of the chrome follows the palette instead.
        self.edit = ui.CreateWindowExW(
            0,
            ui.WC_EDIT,
            null,
            ui.WS_CHILD | ui.WS_VISIBLE | ui.WS_TABSTOP | ui.ES_AUTOHSCROLL,
            0,
            0,
            0,
            0,
            hwnd,
            @ptrFromInt(id_edit),
            instance,
            null,
        ) orelse return error.NoWindow;

        self.list = ui.CreateWindowExW(
            0,
            ui.WC_LISTVIEW,
            null,
            ui.WS_CHILD | ui.WS_VISIBLE | ui.WS_TABSTOP | ui.LVS_REPORT |
                ui.LVS_OWNERDATA | ui.LVS_SINGLESEL | ui.LVS_SHOWSELALWAYS |
                ui.LVS_EDITLABELS,
            0,
            0,
            0,
            0,
            hwnd,
            @ptrFromInt(id_list),
            instance,
            null,
        ) orelse return error.NoWindow;

        _ = ui.SendMessageW(
            self.list,
            ui.LVM_SETEXTENDEDLISTVIEWSTYLE,
            0,
            ui.LVS_EX_FULLROWSELECT | ui.LVS_EX_DOUBLEBUFFER | ui.LVS_EX_LABELTIP,
        );

        // The shell's own image list, borrowed rather than built: every icon
        // Explorer would draw is already in it, at the index the shell hands
        // back for a file. Handing it to the list view is also what makes the
        // rows tall enough for one, so it goes in before anything is measured.
        self.icons.start(hwnd, wm_icon);
        if (self.icons.list) |list| {
            _ = ui.SendMessageW(
                self.list,
                ui.LVM_SETIMAGELIST,
                ui.LVSIL_SMALL,
                @bitCast(@intFromPtr(list)),
            );
        }

        self.setFont();
        _ = ui.SendMessageW(self.edit, ui.EM_SETCUEBANNER, 1, @bitCast(@intFromPtr(cue_banner)));

        // Keys have to be read before the controls handle them: arrows belong
        // to the results even while the caret is in the search box.
        _ = ui.SetWindowSubclass(self.edit, editProc, id_edit, @intFromPtr(self));
        _ = ui.SetWindowSubclass(self.list, listProc, id_list, @intFromPtr(self));

        const header = ui.SendMessageW(self.list, ui.LVM_GETHEADER, 0, 0);
        if (header != 0) self.header = @ptrFromInt(@as(usize, @bitCast(header)));

        try self.addColumns();
        self.applyTheme();
        self.layout();

        const maximized = self.restorePlacement();
        _ = ui.ShowWindow(hwnd, if (maximized) ui.SW_SHOWMAXIMIZED else ui.SW_SHOW);
        _ = ui.UpdateWindow(hwnd);
        _ = ui.SetFocus(self.edit);
        _ = ui.SetTimer(hwnd, tick_id, tick_ms, null);
    }

    /// Whether this run's position is worth keeping. A made up drive or a
    /// stand-in service is a test, and a test window is moved out of the way,
    /// which is not where the next real one should open.
    fn remembersPlacement(self: *const Window) bool {
        return self.opts.startup.synthetic == 0 and self.opts.service_pipe == null;
    }

    /// Moves the still hidden window to where it last closed, and says
    /// whether it should come up maximized.
    fn restorePlacement(self: *Window) bool {
        if (!self.remembersPlacement()) return false;
        const saved = placement.load(self.gpa) orelse return false;
        // Hidden for now: showing it is left to the caller, once the font
        // matches whichever screen it landed on.
        const place: ui.WindowPlacement = .{ .show = ui.SW_HIDE, .normal = saved.normal };
        self.placing = true;
        _ = ui.SetWindowPlacement(self.hwnd, &place);
        self.placing = false;

        const dpi = ui.GetDpiForWindow(self.hwnd);
        if (dpi != 0 and dpi != self.dpi) {
            self.dpi = dpi;
            self.setFont();
            self.layout();
        }
        return saved.maximized;
    }

    /// Writes down where the window is, for the next one to open there.
    fn savePlacement(self: *Window) void {
        if (!self.remembersPlacement()) return;
        var place: ui.WindowPlacement = .{};
        if (ui.GetWindowPlacement(self.hwnd, &place) == 0) return;
        // Closed from the taskbar while minimized, it still had a size to go
        // back to, and that is the one worth keeping.
        const maximized = place.show == ui.SW_SHOWMAXIMIZED or
            (place.show == ui.SW_SHOWMINIMIZED and place.flags & ui.WPF_RESTORETOMAXIMIZED != 0);
        var normal = place.normal;
        if (!maximized) {
            if (self.shown_at) |at| normal = toWorkspace(at);
        }
        placement.save(self.gpa, .{ .normal = normal, .maximized = maximized });
    }

    fn noteRect(self: *Window) void {
        if (ui.IsZoomed(self.hwnd) != 0 or ui.IsIconic(self.hwnd) != 0) return;
        var at: ui.Rect = undefined;
        if (ui.GetWindowRect(self.hwnd, &at) != 0) self.shown_at = at;
    }

    /// Builds the interface font at the current scaling and hands it to both
    /// controls. Called again whenever the window lands on a screen with a
    /// different one, because a font is a fixed number of pixels tall.
    fn setFont(self: *Window) void {
        const old = self.font;
        const old_bold = self.bold;
        self.font = self.makeFont(ui.FW_NORMAL);
        // The same face at the same size, so a cell holding both still sits on
        // one baseline and only the weight of it changes.
        self.bold = self.makeFont(ui.FW_BOLD);
        if (self.font) |f| {
            for ([_]ui.HANDLE{ self.edit, self.list }) |child| {
                _ = ui.SendMessageW(child, ui.WM_SETFONT, @intFromPtr(f), 1);
            }
            // Only once nothing is drawing with them any more.
            if (old) |f2| _ = ui.DeleteObject(f2);
            if (old_bold) |f2| _ = ui.DeleteObject(f2);
        } else {
            self.font = old;
            if (self.bold) |f| _ = ui.DeleteObject(f);
            self.bold = old_bold;
        }
        self.line_height = self.measureLine();
    }

    fn makeFont(self: *const Window, weight: i32) ?ui.HANDLE {
        return ui.CreateFontW(
            // Negative asks for a character height rather than a cell height,
            // which is what a point size means.
            -@divTrunc(@as(i32, 9) * @as(i32, @intCast(self.dpi)), 72),
            0,
            0,
            0,
            weight,
            0,
            0,
            0,
            ui.DEFAULT_CHARSET,
            ui.OUT_DEFAULT_PRECIS,
            ui.CLIP_DEFAULT_PRECIS,
            ui.CLEARTYPE_QUALITY,
            ui.DEFAULT_PITCH,
            std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
        );
    }

    /// How tall one line of the interface font actually is. The search box is
    /// built out from this rather than from a number of pixels picked by hand,
    /// which is the only way it stays right at another scaling.
    fn measureLine(self: *Window) i32 {
        const fallback = self.scale(16);
        const dc = ui.GetDC(self.hwnd) orelse return fallback;
        defer _ = ui.ReleaseDC(self.hwnd, dc);

        const old = if (self.font) |f| ui.SelectObject(dc, f) else null;
        defer if (old) |f| {
            _ = ui.SelectObject(dc, f);
        };

        var tm: ui.TextMetric = undefined;
        if (ui.GetTextMetricsW(dc, &tm) == 0) return fallback;
        return @max(tm.height + tm.external_leading, 1);
    }

    fn addColumns(self: *Window) !void {
        var title: [64]u16 = undefined;
        for (columns, 0..) |c, i| {
            const n = try std.unicode.wtf8ToWtf16Le(title[0 .. title.len - 1], c.title);
            title[n] = 0;
            var col: ui.LvColumn = .{
                .mask = ui.LVCF_TEXT | ui.LVCF_WIDTH | ui.LVCF_SUBITEM | ui.LVCF_FMT,
                .fmt = if (c.right) ui.LVCFMT_RIGHT else ui.LVCFMT_LEFT,
                .cx = 120,
                .text = @ptrCast(title[0..n :0].ptr),
                .sub_item = @intCast(i),
            };
            _ = ui.SendMessageW(self.list, ui.LVM_INSERTCOLUMNW, i, @bitCast(@intFromPtr(&col)));
        }
    }

    fn deinit(self: *Window) void {
        self.query.deinit(self.gpa);
        if (self.parsed) |q| search.freeQuery(self.gpa, q);
        self.palette.free();
        if (self.font) |f| _ = ui.DeleteObject(f);
        if (self.bold) |f| _ = ui.DeleteObject(f);
        if (self.ready.cache_path) |p| self.gpa.free(p);
    }

    // ---- reading the drives ----

    fn startLoading(self: *Window) !void {
        self.setProgress("reading the master file table", .{});
        self.loader = try std.Thread.spawn(.{}, load, .{self});
    }

    fn load(self: *Window) void {
        const watcher: startup.Watcher = .{ .ctx = self, .on = onProgress };
        if (startup.bringUp(self.gpa, self.index, self.opts.startup, watcher)) |ready| {
            self.ready = ready;
            self.loaded = true;
        } else |e| switch (e) {
            // Every drive that was tried has already said why on its own, and
            // the reason it gave beats anything that could be said here.
            error.NothingIndexed => self.addProgress(", so nothing is indexed"),
            error.NoVolume => self.setProgress("no NTFS volume found", .{}),
            error.OutOfMemory => self.setProgress("out of memory", .{}),
        }
        _ = ui.PostMessageW(self.hwnd, wm_indexed, 0, 0);
    }

    fn joinLoader(self: *Window) void {
        if (self.loader) |t| t.join();
        self.loader = null;
    }

    fn onProgress(ctx: *anyopaque, ev: startup.Event) void {
        const self: *Window = @ptrCast(@alignCast(ctx));
        switch (ev) {
            .synthetic => |s| self.setProgress("{d} synthetic entries in {d} ms", .{ s.entries, s.millis }),
            .restored => |r| self.setProgress(
                "{d} files from the cache in {d} ms, catching up",
                .{ r.entries, r.millis },
            ),
            .frozen => |f| {
                if (self.can_elevate) self.wants_admin.store(true, .release);
                var day_buf: [16]u8 = undefined;
                self.setProgress("{d} files from the cache saved {s}", .{
                    f.entries,
                    startup.day(&day_buf, f.saved),
                });
            },
            .reading => |r| self.setProgress("reading {c}:{s}", .{
                r.letter,
                if (self.service == .used) " through the service" else "",
            }),
            .scanned => |s| self.setProgress("{c}: {d} entries in {d} ms", .{
                s.letter,
                s.entries,
                s.millis,
            }),
            .failed => |f| {
                if (f.reason == error.AccessDenied and self.can_elevate) {
                    self.wants_admin.store(true, .release);
                }
                self.setProgress("{c}: {s}", .{ f.letter, switch (f.reason) {
                    error.AccessDenied => "access denied, reading the MFT needs administrator rights",
                    error.OpenFailed => "could not open the volume",
                    error.EnumFailed => "MFT enumeration failed",
                    error.ServiceFailed => "the service stopped answering",
                } });
            },
            // The status line switches to the match count from here on, so
            // there is nothing left for this to say.
            .ready => {},
        }
    }

    /// Written by the loader thread and read by the message loop, so the lock
    /// covers the text and its length together.
    fn setProgress(self: *Window, comptime fmt: []const u8, args: anytype) void {
        self.progress_lock.acquire();
        defer self.progress_lock.release();
        const written = std.fmt.bufPrint(&self.progress, fmt, args) catch self.progress[0..0];
        self.progress_len = written.len;
    }

    /// Adds to what is already there, for the case where the last line is
    /// still the right one and only needs finishing.
    fn addProgress(self: *Window, tail: []const u8) void {
        self.progress_lock.acquire();
        defer self.progress_lock.release();
        const room = self.progress.len - self.progress_len;
        const n = @min(tail.len, room);
        @memcpy(self.progress[self.progress_len..][0..n], tail[0..n]);
        self.progress_len += n;
    }

    fn takeProgress(self: *Window, buf: []u8) []const u8 {
        self.progress_lock.acquire();
        defer self.progress_lock.release();
        const n = @min(self.progress_len, buf.len);
        @memcpy(buf[0..n], self.progress[0..n]);
        return buf[0..n];
    }

    /// Called once the loader has posted. Everything that outlives the scan
    /// starts here rather than on the worker, so it belongs to the thread that
    /// will be stopping it.
    fn indexed(self: *Window) void {
        self.joinLoader();
        if (!self.loaded) {
            // The progress line already says which drive refused and why.
            self.repaint();
            return;
        }

        // A restored index already carries whatever the last run read, and a
        // made-up one has nothing to read.
        if (self.opts.startup.synthetic == 0 and !self.ready.restored) {
            self.sizer.start();
            self.sizes_unseen = true;
        }
        // A frozen index is the cache as it was saved, and the drives that
        // would keep it current are the ones that refused to open.
        if (self.opts.startup.synthetic == 0 and !self.ready.frozen) _ = self.monitor.start() catch {};

        // Explorer's menu hands over whatever folder was right clicked, and an
        // index saved before that folder existed has never heard of it.
        // Searching the whole machine without a word would look like the scope
        // took.
        if (self.opts.under) |dir| {
            if (self.index.findPath(dir)) |at| {
                if (self.index.isDir(at)) {
                    self.searcher.setScope(self.index.subtree(at));
                    self.setCue(dir);
                } else {
                    self.say("{s} is a file, searching everything", .{dir});
                }
            } else {
                self.say("nothing indexed at {s}, searching everything", .{dir});
            }
        }

        self.ready_to_search = true;
        self.setCaption();
        self.runSearch(.first);
    }

    /// The empty box says what a query will cover, and once Explorer has handed
    /// over a folder to search under, that is no longer every drive.
    fn setCue(self: *Window, dir: []const u8) void {
        var text: [1024]u8 = undefined;
        var wide: [1100]u16 = undefined;
        var out = std.Io.Writer.fixed(&text);
        out.print("Search {s}", .{dir}) catch {};
        const banner = toWide(&wide, out.buffered());
        _ = ui.SendMessageW(self.edit, ui.EM_SETCUEBANNER, 1, @bitCast(@intFromPtr(banner.ptr)));
    }

    fn setCaption(self: *Window) void {
        var buf: [128]u8 = undefined;
        var wide: [128]u16 = undefined;
        const text = std.fmt.bufPrint(&buf, "ElephantSearch - {d} files", .{self.index.count()}) catch
            return;
        _ = ui.SetWindowTextW(self.hwnd, toWide(&wide, text).ptr);
    }

    // ---- layout and theming ----

    fn scale(self: *const Window, v: i32) i32 {
        return @divTrunc(v * @as(i32, @intCast(self.dpi)), 96);
    }

    fn statusHeight(self: *const Window) i32 {
        return self.scale(24);
    }

    /// How far the control insets a column's text from the edge of its
    /// cell. Matching it is what keeps a column drawn here lined up under
    /// the same heading as one left to the control.
    fn textInset(self: *const Window) i32 {
        return self.scale(6);
    }

    /// The box drawn around the search field: its border and its background.
    /// A little taller than the text it holds, and no more.
    fn fieldRect(self: *const Window, client: ui.Rect) ui.Rect {
        const pad = self.scale(8);
        return .{
            .left = pad,
            .top = pad,
            .right = @max(client.right - pad, pad),
            .bottom = pad + self.line_height + self.scale(8),
        };
    }

    fn layout(self: *Window) void {
        var client: ui.Rect = undefined;
        if (ui.GetClientRect(self.hwnd, &client) == 0) return;

        const pad = self.scale(8);
        const status = self.statusHeight();

        // A single line edit control puts its text at the top and offers no
        // way to move it, so the control is made exactly one line tall and
        // centred in the box instead. The box paints its own background, so
        // the room left over above and below is the same colour.
        const box = self.fieldRect(client);
        const inset = self.scale(6);
        _ = ui.MoveWindow(
            self.edit,
            box.left + inset,
            box.top + @divTrunc(box.height() - self.line_height, 2),
            @max(box.width() - inset * 2, 0),
            self.line_height,
            1,
        );

        const list_top = box.bottom + pad;
        const list_height = client.height() - list_top - status;
        _ = ui.MoveWindow(self.list, 0, list_top, client.width(), @max(list_height, 0), 1);
        self.sizeColumns(client.width());
    }

    /// Columns share the width by weight, which keeps the path column wide
    /// enough to be worth reading at any window size.
    fn sizeColumns(self: *Window, width: i32) void {
        // Leave room for the vertical scrollbar, which is inside the client
        // area and would otherwise push the last column into a horizontal one.
        const room = @max(width - self.scale(20), self.scale(200));
        var total: u32 = 0;
        for (columns) |c| total += c.weight;
        for (columns, 0..) |c, i| {
            const cx = @divTrunc(room * @as(i32, @intCast(c.weight)), @as(i32, @intCast(total)));
            _ = ui.SendMessageW(self.list, ui.LVM_SETCOLUMNWIDTH, i, cx);
        }
    }

    fn wantDark(self: *const Window) bool {
        return switch (self.opts.appearance) {
            .system => theme.prefersDark(),
            .light => false,
            .dark => true,
        };
    }

    fn applyTheme(self: *Window) void {
        if (!self.palette.set(self.wantDark())) return;
        const c = self.palette.c;
        const is_dark = self.palette.dark;

        theme.allowDark(self.hwnd, is_dark);
        theme.titleBar(self.hwnd, is_dark);

        // The list view paints its own background, so it is told the colour
        // rather than asked to leave it alone. CLR_NONE behind the text keeps
        // the row background showing through the selection highlight.
        _ = ui.SendMessageW(self.list, ui.LVM_SETBKCOLOR, 0, c.list);
        _ = ui.SendMessageW(self.list, ui.LVM_SETTEXTBKCOLOR, 0, @bitCast(@as(isize, -1)));
        _ = ui.SendMessageW(self.list, ui.LVM_SETTEXTCOLOR, 0, c.text);

        theme.style(self.list, .explorer, is_dark);
        if (self.header) |h| theme.style(h, .items_view, is_dark);
        theme.style(self.edit, .field, is_dark);

        theme.refresh();
        _ = ui.InvalidateRect(self.hwnd, null, 1);
        _ = ui.InvalidateRect(self.list, null, 1);
    }

    // ---- searching ----

    fn readQuery(self: *Window) void {
        const len = ui.GetWindowTextLengthW(self.edit);
        self.query.clearRetainingCapacity();
        if (len <= 0) return;

        var wide = self.gpa.alloc(u16, @as(usize, @intCast(len)) + 1) catch return;
        defer self.gpa.free(wide);
        const got = ui.GetWindowTextW(self.edit, wide.ptr, len + 1);
        if (got <= 0) return;

        const text = std.unicode.wtf16LeToWtf8Alloc(self.gpa, wide[0..@intCast(got)]) catch return;
        defer self.gpa.free(text);
        self.query.appendSlice(self.gpa, text) catch {};
    }

    /// Whether a re-run picks the top result or holds on to the row someone is
    /// already pointing at. Typing means the old selection is meaningless, while
    /// the change journal firing under a list being read means the opposite.
    const Selecting = enum { first, keep };

    fn runSearch(self: *Window, hold: Selecting) void {
        if (!self.ready_to_search) return;

        const was = if (hold == .keep) self.selection() else null;

        // Folding journal changes in here means no lock has to guard the index
        // while a search runs: both happen on this thread.
        if ((self.monitor.drain() catch 0) > 0) self.searcher.invalidate();

        // An empty query lists everything, the way Everything opens on the
        // whole drive and narrows from there. It costs one pass over the index,
        // the same order as searching for a single letter.
        self.results = self.searcher.search(self.query.items, pool) catch &.{};
        self.reparse();

        const found = self.searcher.total();
        // Nothing here decides where the list should be looking, so the count
        // goes in without letting the control decide either. Whatever scrolls
        // does it below, on purpose.
        _ = ui.SendMessageW(self.list, ui.LVM_SETITEMCOUNT, found, ui.LVSICF_NOSCROLL);
        if (was) |prev| {
            self.reselect(prev);
        } else if (found > 0) {
            self.selectRow(0, .scroll_to);
        }
        _ = ui.InvalidateRect(self.list, null, 0);
        self.repaint();
    }

    /// Keeps a parsed copy of the query for the bolding to match against. The
    /// searcher parses one of its own and throws it away, and doing that again
    /// inside a paint would mean a handful of small allocations a frame.
    fn reparse(self: *Window) void {
        if (self.parsed) |q| search.freeQuery(self.gpa, q);
        self.parsed = search.parseQuery(self.gpa, self.query.items, .{
            .default_kind = self.searcher.default_kind,
        }) catch null;
        self.stamp +%= 1;
    }

    /// Ranks deep enough to fill the rows about to be drawn. Doubling rather
    /// than growing by a screen means dragging the scrollbar the length of a
    /// million matches costs a handful of ranking passes, not one per screen.
    fn rankFarEnough(self: *Window, want: usize) void {
        if (want <= self.results.len) return;
        var target = @max(pool, self.results.len);
        while (target < want) target *= 2;
        self.results = self.searcher.extend(target) catch self.results;
    }

    // ---- sorting ----

    /// A heading was clicked. The first click sorts the list on it, the second
    /// turns it around, and the third drops the column and goes back to
    /// ranking by how well the query matched, which is where it started.
    /// Everything else in the window keeps a sort once it is set, the way a
    /// clicked column in Explorer stays clicked, so there has to be a way back.
    fn clickColumn(self: *Window, column: usize) void {
        if (column >= columns.len) return;
        const c = columns[column];
        const now = self.searcher.order;
        const next: search.Order = if (now.by != c.sort)
            .{ .by = c.sort, .descending = c.descending_first }
        else if (now.descending == c.descending_first)
            .{ .by = c.sort, .descending = !c.descending_first }
        else
            .{};
        self.sortBy(next);
    }

    fn sortBy(self: *Window, order: search.Order) void {
        self.markSortedColumn(order);
        // Which files matched has not changed, so this re-ranks what is
        // already in hand rather than searching the drive again. With nothing
        // searched yet there is nothing to re-rank and the order waits for the
        // first one, which is what a click during the scan does.
        self.results = self.searcher.setOrder(order, pool) catch self.results;
        if (self.searcher.total() > 0) self.selectRow(0, .scroll_to);
        _ = ui.InvalidateRect(self.list, null, 0);
        self.repaint();
    }

    /// Puts the arrow on the heading the list is sorted by and takes it off
    /// the rest. The header control draws it, so all this does is say which one
    /// and which way up. Ranking by relevance belongs to no column, so it
    /// leaves every heading bare.
    fn markSortedColumn(self: *Window, order: search.Order) void {
        const header = self.header orelse return;
        for (columns, 0..) |c, i| {
            var item: ui.HdItem = .{ .mask = ui.HDI_FORMAT };
            if (ui.SendMessageW(header, ui.HDM_GETITEMW, i, @bitCast(@intFromPtr(&item))) == 0) continue;
            item.fmt &= ~(ui.HDF_SORTUP | ui.HDF_SORTDOWN);
            if (order.by == c.sort) {
                item.fmt |= if (order.descending) ui.HDF_SORTDOWN else ui.HDF_SORTUP;
            }
            _ = ui.SendMessageW(header, ui.HDM_SETITEMW, i, @bitCast(@intFromPtr(&item)));
        }
    }

    // ---- the selected row ----

    /// Which row is selected and which file is on it. The file, because the
    /// row it sits on is only good until the results are rebuilt.
    const Selected = struct { row: usize, entry: u32 };

    fn selection(self: *Window) ?Selected {
        const row = self.selectedRow() orelse return null;
        return .{ .row = row, .entry = self.entryAt(row) orelse return null };
    }

    fn selectedRow(self: *Window) ?usize {
        const at = ui.SendMessageW(
            self.list,
            ui.LVM_GETNEXTITEM,
            @bitCast(@as(isize, -1)),
            ui.LVNI_SELECTED,
        );
        if (at < 0) return null;
        return @intCast(at);
    }

    /// Whether the list should scroll to bring the row into view. It should
    /// when something was asked for that row, and should not when the row was
    /// only being put back where it already was.
    const Reveal = enum { scroll_to, leave_scroll };

    fn selectRow(self: *Window, row: usize, reveal: Reveal) void {
        var item: ui.LvItem = .{
            .state = ui.LVIS_SELECTED | ui.LVIS_FOCUSED,
            .state_mask = ui.LVIS_SELECTED | ui.LVIS_FOCUSED,
        };
        _ = ui.SendMessageW(self.list, ui.LVM_SETITEMSTATE, row, @bitCast(@intFromPtr(&item)));
        if (reveal == .scroll_to) _ = ui.SendMessageW(self.list, ui.LVM_ENSUREVISIBLE, row, 0);
    }

    /// Finds the file that was selected before the results were rebuilt and
    /// selects it again. Windows writes files continuously, so the journal
    /// re-runs the query every second or so on an idle machine, and without
    /// this every one of those drags the selection back to the top of the list
    /// while someone is reading it.
    fn reselect(self: *Window, was: Selected) void {
        // Ranking as far as the row someone was on costs nothing extra: the
        // repaint that follows asks for those rows anyway.
        self.rankFarEnough(was.row + 1);

        // Almost always: the same row still holds the same file, and neither
        // the selection nor the scroll position has any reason to move.
        if (self.entryAt(was.row) == was.entry) {
            self.selectRow(was.row, .leave_scroll);
            return;
        }
        for (self.results, 0..) |m, row| {
            if (m.entry != was.entry) continue;
            self.selectRow(row, .scroll_to);
            return;
        }
        // The file is gone, or has fallen past what has been ranked so far.
        // The row it was on is a closer answer than the top of the list.
        const total = self.searcher.total();
        if (total > 0) self.selectRow(@min(was.row, total - 1), .leave_scroll);
    }

    fn pageRows(self: *Window) isize {
        const n = ui.SendMessageW(self.list, ui.LVM_GETCOUNTPERPAGE, 0, 0);
        return @max(n, 1);
    }

    fn moveSelection(self: *Window, delta: isize) void {
        const total = self.searcher.total();
        if (total == 0) return;
        const at: isize = if (self.selectedRow()) |r| @intCast(r) else -1;
        const last: isize = @intCast(total - 1);
        self.selectRow(@intCast(std.math.clamp(at + delta, 0, last)), .scroll_to);
    }

    /// The entry a row stands for, or null for a row past the results that
    /// have been ranked so far.
    fn entryAt(self: *const Window, row: usize) ?u32 {
        if (row >= self.results.len) return null;
        return self.results[row].entry;
    }

    fn selectedPath(self: *Window, buf: []u8) ?[]const u8 {
        const row = self.selectedRow() orelse return null;
        const entry = self.entryAt(row) orelse return null;
        return self.index.path(entry, buf);
    }

    fn openSelected(self: *Window, in_explorer: bool) void {
        var path_buf: [32 * 1024]u8 = undefined;
        const path = self.selectedPath(&path_buf) orelse return;
        const ok = if (in_explorer)
            shell.reveal(self.gpa, path)
        else
            shell.open(self.gpa, path);
        if (ok) {
            self.say("{s} {s}", .{ if (in_explorer) "showing" else "opened", baseName(path) });
        } else {
            self.say("could not open {s}", .{baseName(path)});
        }
    }

    /// `at` is where the click was, in screen coordinates, or (-1, -1) when the
    /// menu key asked for it instead of the mouse.
    fn contextMenu(self: *Window, at: ui.Point) void {
        var where = at;
        if (at.x == -1 and at.y == -1) {
            // No pointer to go by, so it opens on the row it applies to.
            const row = self.selectedRow() orelse return;
            var bounds: ui.Rect = .{ .left = ui.LVIR_BOUNDS, .top = 0, .right = 0, .bottom = 0 };
            if (ui.SendMessageW(
                self.list,
                ui.LVM_GETITEMRECT,
                row,
                @bitCast(@intFromPtr(&bounds)),
            ) == 0) return;
            where = .{ .x = bounds.left + self.scale(24), .y = bounds.bottom };
            _ = ui.ClientToScreen(self.list, &where);
        } else {
            // Right clicking a row acts on that row, whichever one was selected
            // before. Clicking past the last one leaves the selection alone.
            var hit: ui.LvHitTest = .{ .pt = where };
            _ = ui.ScreenToClient(self.list, &hit.pt);
            const row = ui.SendMessageW(self.list, ui.LVM_HITTEST, 0, @bitCast(@intFromPtr(&hit)));
            if (row >= 0) self.selectRow(@intCast(row), .scroll_to);
        }

        // Taken before the menu opens: it runs its own message loop, and the
        // results underneath can be rebuilt by the journal while it is up.
        var path_buf: [32 * 1024]u8 = undefined;
        const path = self.selectedPath(&path_buf) orelse return;
        switch (self.menu.show(self.gpa, self.hwnd, path, where, shiftDown())) {
            .open => self.openSelected(false),
            .reveal => self.openSelected(true),
            .copy => self.copySelected(),
            .rename => self.beginRename(),
            .handled => {},
            .unavailable => self.say("Windows has no menu for {s}", .{baseName(path)}),
        }
    }

    fn beginRename(self: *Window) void {
        const row = self.selectedRow() orelse return;
        _ = ui.SetFocus(self.list);
        // However the editor was opened, it says so through
        // `LVN_BEGINLABELEDITW`, so all there is to do here is undo a refusal.
        if (ui.SendMessageW(self.list, ui.LVM_EDITLABELW, row, 0) == 0) self.renaming = null;
    }

    /// Carries out the rename the label editor collected, on the file the
    /// editor was opened over rather than on whatever is under that row now.
    /// The name comes back as the last component only, so the directory is
    /// taken from the path the entry already had.
    fn endRename(self: *Window, info: *const ui.NmLvDispInfo) void {
        const open = self.renaming;
        self.renaming = null;
        // Null text is a cancelled edit, and nothing open is one this window
        // never agreed to.
        const text = info.item.text orelse return;
        const entry = open orelse return;

        var path_buf: [32 * 1024]u8 = undefined;
        const from = self.index.path(entry, &path_buf);

        var seen: usize = 0;
        while (text[seen] != 0) seen += 1;
        if (seen == 0) return;
        const name = std.unicode.wtf16LeToWtf8Alloc(self.gpa, text[0..seen]) catch return;
        defer self.gpa.free(name);

        var to_buf: [32 * 1024]u8 = undefined;
        const to = renamedPath(&to_buf, from, name) orelse {
            self.say("{s} is not a name a file can have", .{name});
            return;
        };

        const old_wide = std.unicode.wtf8ToWtf16LeAllocZ(self.gpa, from) catch return;
        defer self.gpa.free(old_wide);
        const new_wide = std.unicode.wtf8ToWtf16LeAllocZ(self.gpa, to) catch return;
        defer self.gpa.free(new_wide);

        if (w.MoveFileExW(old_wide, new_wide, 0) == 0) {
            self.say("could not rename {s}", .{baseName(from)});
            return;
        }

        // The journal reports this too, but only where it is running at all,
        // and the row on screen should not wait for that either way.
        self.index.rename(entry, name, self.index.entries.items(.parent)[entry]) catch {};
        self.searcher.invalidate();
        // The row it sits on is about to be redrawn against a name that is no
        // longer the one its marks were worked out from.
        self.stamp +%= 1;
        self.say("renamed to {s}", .{name});
        _ = ui.InvalidateRect(self.list, null, 0);
    }

    fn copySelected(self: *Window) void {
        var path_buf: [32 * 1024]u8 = undefined;
        const path = self.selectedPath(&path_buf) orelse return;
        if (shell.copyText(self.gpa, path)) {
            self.say("copied {s}", .{path});
        } else {
            self.say("could not reach the clipboard", .{});
        }
    }

    fn say(self: *Window, comptime fmt: []const u8, args: anytype) void {
        // A path longer than the note is ordinary, so what fits is kept rather
        // than the whole message dropped. The status line ellipsises anyway.
        var out = std.Io.Writer.fixed(&self.note);
        out.print(fmt, args) catch {};
        self.note_len = out.buffered().len;
        self.repaint();
    }

    // ---- filling in a row ----

    fn fillRow(self: *Window, info: *ui.NmLvDispInfo) void {
        const row: usize = @intCast(info.item.item);
        self.rankFarEnough(row + 1);
        const entry = self.entryAt(row);

        if (info.item.mask & ui.LVIF_IMAGE != 0) {
            info.item.image = if (entry) |e| self.imageFor(e) else 0;
        }
        if (info.item.mask & ui.LVIF_TEXT == 0) return;
        info.item.text = @ptrCast(&self.cell);
        self.cell[0] = 0;

        const at = entry orelse return;
        var buf: [32 * 1024]u8 = undefined;
        _ = toWide(&self.cell, self.cellText(at, info.item.sub_item, &buf));
    }

    /// The icon a row draws with. Only the few kinds of file whose icon is
    /// their own rather than their type's need a path built for them, so
    /// almost every row here costs a hash lookup and nothing else.
    fn imageFor(self: *Window, entry: u32) i32 {
        const name = self.index.nameOf(entry);
        const is_dir = self.index.isDir(entry);
        // A volume root is a directory and is not a folder. Explorer draws it
        // as the drive it is, and it is the first row of an empty query, so it
        // is the one icon somebody sees before they have typed anything.
        if (self.index.entries.items(.parent)[entry] == entry and
            name.len >= 2 and name[1] == ':')
        {
            return self.icons.forDrive(name[0]);
        }
        if (is_dir or !icons_mod.needsFile(name)) {
            return self.icons.indexFor(entry, is_dir, name, "");
        }
        var buf: [1024]u8 = undefined;
        return self.icons.indexFor(entry, is_dir, name, self.index.path(entry, &buf));
    }

    fn cellText(self: *Window, entry: u32, column: i32, buf: []u8) []const u8 {
        const slice = self.index.entries.slice();
        // Zero is what the master file table pass leaves behind on a record it
        // has not reached yet, and every real file carries a write time, so it
        // means unknown rather than 1601.
        const modified = slice.items(.modified)[entry];

        return switch (column) {
            0 => self.index.nameOf(entry),
            1 => self.index.path(slice.items(.parent)[entry], buf),
            2 => if (self.index.isDir(entry) or modified == 0)
                ""
            else
                formatSize(buf, slice.items(.size)[entry]),
            3 => if (modified == 0) "" else formatDate(buf, modified),
            else => "",
        };
    }

    // ---- painting the chrome ----

    fn repaint(self: *Window) void {
        var client: ui.Rect = undefined;
        if (ui.GetClientRect(self.hwnd, &client) == 0) return;
        var strip = client;
        strip.top = client.bottom - self.statusHeight();
        _ = ui.InvalidateRect(self.hwnd, &strip, 0);
    }

    fn paint(self: *Window) void {
        var ps: ui.PaintStruct = undefined;
        const dc = ui.BeginPaint(self.hwnd, &ps) orelse return;
        defer _ = ui.EndPaint(self.hwnd, &ps);

        var client: ui.Rect = undefined;
        if (ui.GetClientRect(self.hwnd, &client) == 0) return;

        if (self.palette.window_brush) |brush| _ = ui.FillRect(dc, &client, brush);

        const old_font = if (self.font) |f| ui.SelectObject(dc, f) else null;
        defer if (old_font) |f| {
            _ = ui.SelectObject(dc, f);
        };
        _ = ui.SetBkMode(dc, ui.TRANSPARENT);

        // A hairline above the status line and a box round the search field:
        // the two edges in the window the list view does not draw for itself.
        var rule = client;
        rule.top = client.bottom - self.statusHeight();
        rule.bottom = rule.top + 1;
        var box = self.fieldRect(client);
        // The edit control only covers one line in the middle of this, so the
        // rest of it is filled here to match.
        if (self.palette.field_brush) |brush| _ = ui.FillRect(dc, &box, brush);
        if (self.palette.line_brush) |brush| {
            _ = ui.FillRect(dc, &rule, brush);
            box.left -= 1;
            box.top -= 1;
            box.right += 1;
            box.bottom += 1;
            frame(dc, box, brush);
        }

        var status_buf: [256]u8 = undefined;
        var timing_buf: [64]u8 = undefined;
        const pad = self.scale(10);

        var left = client;
        left.left += pad;
        left.right -= pad;
        left.top = rule.bottom;
        _ = ui.SetTextColor(dc, self.palette.c.text);
        self.drawText(dc, &left, self.statusText(&status_buf), ui.DT_LEFT);

        var right = left;
        const nowhere: ui.Rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        self.install_rect = nowhere;
        if (self.wants_admin.load(.acquire)) {
            // Takes the corner from the timing. Until the drives can be read
            // there is nothing in it as worth saying as how to read them.
            self.elevate_rect = self.drawLink(dc, right, elevate_label);
            if (self.can_install and self.installer == null) {
                var room = right;
                room.right = self.elevate_rect.left - self.scale(16);
                self.install_rect = self.drawLink(dc, room, install_label);
            }
        } else {
            self.elevate_rect = nowhere;
            _ = ui.SetTextColor(dc, self.palette.c.dim);
            self.drawText(dc, &right, self.timingText(&timing_buf), ui.DT_RIGHT);
        }
    }

    /// The shield and the words, right aligned in `room`. Returns the space
    /// they cover, which is what a click has to land in.
    fn drawLink(self: *Window, dc: ui.HANDLE, room: ui.Rect, comptime words: []const u8) ui.Rect {
        const label = std.unicode.utf8ToUtf16LeStringLiteral(words);
        var size: ui.Size = .{};
        _ = ui.GetTextExtentPoint32W(dc, label, label.len, &size);

        var icon_cx: i32 = 0;
        var icon_cy: i32 = 0;
        const list = self.icons.list;
        if (self.shield != null and list != null) _ = ui.ImageList_GetIconSize(list.?, &icon_cx, &icon_cy);
        const gap = if (icon_cx > 0) self.scale(4) else 0;

        var text = room;
        text.left = @max(room.right - size.cx, room.left);
        _ = ui.SetTextColor(dc, self.palette.c.link);
        _ = ui.DrawTextW(dc, label, label.len, &text, ui.DT_RIGHT | text_flags);

        const icon_left = text.left - gap - icon_cx;
        if (icon_cx > 0) {
            const top = room.top + @divTrunc(room.height() - icon_cy, 2);
            _ = ui.ImageList_Draw(list.?, self.shield.?, dc, icon_left, top, ui.ILD_TRANSPARENT);
        }
        return .{ .left = icon_left, .top = room.top, .right = room.right, .bottom = room.bottom };
    }

    fn overElevate(self: *const Window, x: i32, y: i32) bool {
        return inside(self.elevate_rect, x, y);
    }

    fn overInstall(self: *const Window, x: i32, y: i32) bool {
        return inside(self.install_rect, x, y);
    }

    fn inside(r: ui.Rect, x: i32, y: i32) bool {
        return x >= r.left and x < r.right and y >= r.top and y < r.bottom;
    }

    /// Installs the service on a thread of its own, since the prompt for
    /// administrator rights and the install behind it take seconds. Once it is
    /// in, a fresh start of this window reads the drives through it.
    fn installService(self: *Window) void {
        if (self.installer != null or !self.can_install) return;
        self.installer = std.Thread.spawn(.{}, runInstaller, .{self}) catch {
            self.say("could not start the install", .{});
            return;
        };
        self.say("installing the service", .{});
    }

    fn runInstaller(self: *Window) void {
        const outcome: install.Outcome = blk: {
            const exe = explorer.besideThis(self.gpa, "elephant.exe") catch break :blk .service_missing;
            defer self.gpa.free(exe);
            break :blk install.applyElevated(self.gpa, self.hwnd, exe, .install);
        };
        _ = ui.PostMessageW(self.hwnd, wm_installed, @intFromEnum(outcome), 0);
    }

    fn joinInstaller(self: *Window) void {
        if (self.installer) |t| t.join();
        self.installer = null;
    }

    fn installed(self: *Window, outcome: install.Outcome) void {
        self.joinInstaller();
        if (outcome == .installed) {
            // Before the new window is started, since it reads this as it opens.
            self.savePlacement();
            if (shell.relaunchPlain(self.gpa, self.hwnd)) {
                _ = ui.DestroyWindow(self.hwnd);
                return;
            }
            self.say("the service is installed, open the window again to use it", .{});
            return;
        }
        self.say("{s}", .{outcome.describe()});
    }

    /// Starts over with administrator rights, handing the new window the same
    /// arguments, and closes this one once it is up. This one never saves a
    /// cache it could not keep current, so the two never write the same file.
    fn elevate(self: *Window) void {
        // Before the new window is started, since it reads this as it opens.
        self.savePlacement();
        if (shell.relaunchElevated(self.gpa, self.hwnd)) {
            _ = ui.DestroyWindow(self.hwnd);
        } else {
            self.say("administrator rights were not granted", .{});
        }
    }

    fn drawText(self: *Window, dc: ui.HANDLE, at: *ui.Rect, text: []const u8, align_flag: u32) void {
        _ = self;
        if (text.len == 0) return;
        var buf: [512]u16 = undefined;
        const wide = toWide(&buf, text);
        _ = ui.DrawTextW(
            dc,
            wide.ptr,
            @intCast(wide.len),
            at,
            align_flag | ui.DT_SINGLELINE | ui.DT_VCENTER | ui.DT_NOPREFIX | ui.DT_END_ELLIPSIS,
        );
    }

    fn statusText(self: *Window, buf: []u8) []const u8 {
        var out = std.Io.Writer.fixed(buf);
        self.writeStatus(&out) catch {};
        return out.buffered();
    }

    fn writeStatus(self: *Window, out: *std.Io.Writer) !void {
        if (!self.ready_to_search) {
            var buf: [192]u8 = undefined;
            return out.writeAll(self.takeProgress(&buf));
        }
        if (self.note_len > 0) {
            try out.writeAll(self.note[0..self.note_len]);
        } else {
            const found = self.searcher.total();
            if (self.query.items.len == 0) {
                try out.print("{d} files", .{found});
            } else if (found == 0) {
                try out.writeAll("no matches");
            } else {
                try out.print("{d} match{s}, {t} mode", .{
                    found,
                    if (found == 1) "" else "es",
                    self.searcher.mode,
                });
            }
            if (self.selectedRow()) |row| try out.print(", on {d}", .{row + 1});
        }

        if (self.searcher.scope) |scope| {
            var path_buf: [32 * 1024]u8 = undefined;
            try out.print(", under {s}", .{self.index.path(scope.from, &path_buf)});
        }
        // A wrapped journal leaves the index quietly wrong, so it has to be on
        // screen for as long as it is true, not just for the frame it happened.
        if (self.monitor.lost.load(.acquire)) {
            try out.writeAll(", stale since a change journal wrapped");
        }
        if (self.ready.frozen) {
            var day_buf: [16]u8 = undefined;
            try out.print(", index saved {s} and not updating", .{startup.day(&day_buf, self.ready.saved)});
        }
        if (self.service == .outdated) {
            try out.writeAll(", the service is another version and is not used");
        }
    }

    fn timingText(self: *Window, buf: []u8) []const u8 {
        if (!self.ready_to_search) return "";
        // While the background pass is running, the corner is worth more as a
        // progress report than as a stopwatch.
        const sizing = self.sizer.progress();
        if (!sizing.finished and sizing.wanted > 0) {
            const percent = @min(sizing.filled * 100 / sizing.wanted, 99);
            return std.fmt.bufPrint(buf, "reading sizes {d}%", .{percent}) catch "";
        }
        const micros = self.searcher.last_nanos / 1000;
        return std.fmt.bufPrint(buf, "{d}.{d:0>3} ms{s}", .{
            micros / 1000,
            micros % 1000,
            if (self.searcher.narrowed) " narrowed" else "",
        }) catch "";
    }

    // ---- messages ----

    /// Answers a control asking what colours to draw its text on. The reply is
    /// the background brush, which is why one has to be kept around.
    fn fieldColors(self: *Window, dc_handle: ui.Wparam) ?ui.Lresult {
        const dc: ui.HANDLE = @ptrFromInt(dc_handle);
        _ = ui.SetTextColor(dc, self.palette.c.text);
        _ = ui.SetBkColor(dc, self.palette.c.field);
        const brush = self.palette.field_brush orelse return null;
        return @bitCast(@intFromPtr(brush));
    }

    fn onMessage(self: *Window, hwnd: ui.HANDLE, msg: u32, wparam: ui.Wparam, lparam: ui.Lparam) ui.Lresult {
        // The shell owner-draws its own menu, so while one is up these belong
        // to it rather than to the window.
        if (self.menu.forward(msg, wparam, lparam)) |handled| return handled;

        switch (msg) {
            ui.WM_SIZE => {
                self.noteRect();
                self.layout();
                return 0;
            },
            ui.WM_MOVE => {
                self.noteRect();
                return 0;
            },
            ui.WM_PAINT => {
                self.paint();
                return 0;
            },
            // The whole client area is covered by the two controls and one
            // FillRect in WM_PAINT, so erasing first would only flicker.
            ui.WM_ERASEBKGND => return 1,
            ui.WM_SETFOCUS => {
                _ = ui.SetFocus(self.edit);
                return 0;
            },
            // The edit control is only as tall as its text, so the rest of the
            // box it sits in would otherwise be a dead strip to click on.
            ui.WM_LBUTTONDOWN => {
                const x: i32 = @as(i16, @truncate(lparam));
                const y: i32 = @as(i16, @truncate(lparam >> 16));
                if (self.overElevate(x, y)) {
                    self.elevate();
                    return 0;
                }
                if (self.overInstall(x, y)) {
                    self.installService();
                    return 0;
                }
                _ = ui.SetFocus(self.edit);
                return 0;
            },
            ui.WM_SETCURSOR => {
                const hit: u16 = @truncate(@as(usize, @bitCast(lparam)));
                if (wparam == @intFromPtr(hwnd) and hit == ui.HTCLIENT) {
                    var at: ui.Point = undefined;
                    if (ui.GetCursorPos(&at) != 0 and ui.ScreenToClient(hwnd, &at) != 0 and
                        (self.overElevate(at.x, at.y) or self.overInstall(at.x, at.y)))
                    {
                        _ = ui.SetCursor(ui.LoadCursorW(null, ui.IDC_HAND));
                        return 1;
                    }
                }
                return ui.DefWindowProcW(hwnd, msg, wparam, lparam);
            },
            ui.WM_SYSCOMMAND => {
                if (wparam & 0xFFF0 == id_elevate) {
                    self.elevate();
                    return 0;
                }
                if (wparam & 0xFFF0 == id_install) {
                    self.installService();
                    return 0;
                }
                return ui.DefWindowProcW(hwnd, msg, wparam, lparam);
            },
            ui.WM_CTLCOLOREDIT, ui.WM_CTLCOLORSTATIC => return self.fieldColors(wparam) orelse
                ui.DefWindowProcW(hwnd, msg, wparam, lparam),
            ui.WM_COMMAND => {
                const code: u16 = @truncate(wparam >> 16);
                const id: u16 = @truncate(wparam);
                if (id == id_edit and code == ui.EN_CHANGE) {
                    self.note_len = 0;
                    self.readQuery();
                    self.runSearch(.first);
                }
                return 0;
            },
            ui.WM_NOTIFY => {
                const hdr: *ui.NmHdr = @ptrFromInt(@as(usize, @bitCast(lparam)));
                return self.onNotify(hdr);
            },
            ui.WM_TIMER => {
                if (wparam == tick_id) self.tick();
                return 0;
            },
            // Sent for a great many things besides the theme, so the colours
            // are re-read rather than assumed to have flipped.
            ui.WM_SETTINGCHANGE => {
                theme.refresh();
                self.applyTheme();
                return 0;
            },
            // Sent on the way to a screen that scales differently. The rect
            // that comes with it is where Windows wants the window to land, and
            // ignoring it leaves the window the wrong size on the new screen.
            ui.WM_DPICHANGED => {
                self.dpi = @truncate(wparam & 0xFFFF);
                const want: *const ui.Rect = @ptrFromInt(@as(usize, @bitCast(lparam)));
                if (!self.placing) _ = ui.SetWindowPos(
                    hwnd,
                    null,
                    want.left,
                    want.top,
                    want.width(),
                    want.height(),
                    ui.SWP_NOZORDER | ui.SWP_NOACTIVATE,
                );
                self.setFont();
                self.layout();
                return 0;
            },
            wm_indexed => {
                self.indexed();
                return 0;
            },
            wm_installed => {
                self.installed(@enumFromInt(@as(u8, @truncate(wparam))));
                return 0;
            },
            // An icon the worker had to open a file for has landed. Which rows
            // were waiting on one is not worth tracking: a repaint of the list
            // costs a few dozen rows of text, and one arrives per batch rather
            // than per icon.
            wm_icon => {
                self.icons.seen();
                _ = ui.InvalidateRect(self.list, null, 0);
                return 0;
            },
            ui.WM_DESTROY => {
                self.savePlacement();
                _ = ui.KillTimer(hwnd, tick_id);
                ui.PostQuitMessage(0);
                return 0;
            },
            else => return ui.DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }

    fn onNotify(self: *Window, hdr: *ui.NmHdr) ui.Lresult {
        if (hdr.from != self.list) return 0;
        switch (hdr.code) {
            ui.LVN_GETDISPINFOW => {
                const info: *ui.NmLvDispInfo = @ptrCast(hdr);
                self.fillRow(info);
            },
            // Which row is selected is part of the status line, and clicking
            // one is the other way it changes.
            ui.LVN_ITEMCHANGED => self.repaint(),
            ui.LVN_COLUMNCLICK => {
                const info: *ui.NmListView = @ptrCast(hdr);
                if (info.sub_item >= 0) self.clickColumn(@intCast(info.sub_item));
            },
            ui.NM_DBLCLK => self.openSelected(shiftDown()),
            ui.NM_RETURN => self.openSelected(shiftDown()),
            ui.NM_CUSTOMDRAW => return self.drawRow(@ptrCast(hdr)),
            // Answering yes is what lets the editor open at all. It is also
            // the only word this window gets about the editor Explorer's own
            // gesture opens -- a click on a row that is already selected, and
            // every search selects the first one, so the top result is one
            // stray click away from a rename box at any time.
            ui.LVN_BEGINLABELEDITW => {
                const info: *ui.NmLvDispInfo = @ptrCast(hdr);
                const row = info.item.item;
                self.renaming = if (row < 0) null else self.entryAt(@intCast(row));
                // Anything else refuses: with no entry behind the row there is
                // nothing an editor over it could rename.
                return if (self.renaming == null) 1 else 0;
            },
            ui.LVN_ENDLABELEDITW => {
                self.endRename(@ptrCast(hdr));
                // The rows come from the index, so there is no label for the
                // control to keep either way.
                return 0;
            },
            else => {},
        }
        return 0;
    }

    /// Colours the column headings. The dark theme gives the headings a dark
    /// background and leaves the text black on top of it, which is a Windows
    /// bug rather than a setting, so the colour is set on the device context
    /// and the control draws with it.
    fn drawHeader(self: *Window, cd: *ui.NmCustomDraw) ui.Lresult {
        switch (cd.stage) {
            ui.CDDS_PREPAINT => return ui.CDRF_NOTIFYITEMDRAW,
            ui.CDDS_ITEMPREPAINT => {
                _ = ui.SetTextColor(cd.dc, self.palette.c.dim);
                return ui.CDRF_DODEFAULT;
            },
            else => return ui.CDRF_DODEFAULT,
        }
    }

    /// Paints the selected row and hands each of its columns on. Everything
    /// else is left to the theme, which is why the rows, the header and the
    /// scrollbar all still look like the ones in Explorer.
    fn drawRow(self: *Window, cd: *ui.NmLvCustomDraw) ui.Lresult {
        switch (cd.nmcd.stage) {
            ui.CDDS_PREPAINT => return ui.CDRF_NOTIFYITEMDRAW,
            ui.CDDS_SUBITEMPREPAINT => return self.drawCell(cd),
            ui.CDDS_ITEMPREPAINT => {
                self.row_selected = false;
                // The focused row is offered once more at the end of every
                // pass, so that its focus rectangle ends up over its
                // neighbours rather than under them. That offer comes even
                // when the pass drew no rows at all, and the control says
                // which kind it is by leaving the rectangle empty. Filling one
                // of those paints a highlight the control then writes nothing
                // into, and the row is left blank until something else
                // happens to invalidate it.
                const row = cd.nmcd.rc;
                if (row.width() <= 0 or row.height() <= 0) return ui.CDRF_DODEFAULT;

                // Not the state on the notification: an owner data list view
                // reports every row as selected there. The control still knows
                // which one it is, so it gets asked.
                const state = ui.SendMessageW(
                    self.list,
                    ui.LVM_GETITEMSTATE,
                    cd.nmcd.item,
                    ui.LVIS_SELECTED,
                );
                self.row_selected = state & ui.LVIS_SELECTED != 0;

                if (self.row_selected) {
                    if (self.palette.select_brush) |brush| {
                        _ = ui.FillRect(cd.nmcd.dc, &row, brush);
                    }
                    cd.text_color = self.palette.c.select_text;
                    cd.text_bk_color = ui.CLR_NONE;
                    // The control reads these back, so dropping the two states
                    // stops it painting its own highlight over the one just
                    // drawn.
                    cd.nmcd.item_state &= ~(ui.CDIS_SELECTED | ui.CDIS_FOCUS);
                }
                // Each column is offered separately from here, because the two
                // that can hold what the query matched draw their own text.
                return ui.CDRF_NOTIFYSUBITEMDRAW | ui.CDRF_NEWFONT;
            },
            else => return ui.CDRF_DODEFAULT,
        }
    }

    /// Draws one column of a row, with whatever the query matched in bold.
    ///
    /// Only the name and the path come through here. The size and the date
    /// can never hold a match, and leaving them to the control keeps the right
    /// alignment and the ellipsis exactly as the theme would have had them.
    fn drawCell(self: *Window, cd: *ui.NmLvCustomDraw) ui.Lresult {
        if (cd.sub_item != 0 and cd.sub_item != 1) return ui.CDRF_DODEFAULT;
        const dc = cd.nmcd.dc;
        const row: usize = cd.nmcd.item;
        const entry = self.entryAt(row) orelse return ui.CDRF_DODEFAULT;

        const bounds = self.itemRect(row, ui.LVIR_BOUNDS) orelse return ui.CDRF_DODEFAULT;

        // The first column also carries the icon, which the control would have
        // drawn itself had it been drawing this column at all. It goes down
        // before the text, so a column squeezed too narrow for a name still
        // says what kind of thing the row is.
        if (cd.sub_item == 0) self.drawIcon(dc, row, entry, bounds);

        var box = if (cd.sub_item == 0)
            self.nameRect(row, bounds) orelse return ui.CDRF_DODEFAULT
        else
            self.columnRect(row, @intCast(cd.sub_item)) orelse return ui.CDRF_DODEFAULT;
        if (box.width() <= 0) return ui.CDRF_SKIPDEFAULT;

        // As much of a path as the cell could hold if the whole column were
        // one. Anything past it is behind the ellipsis either way, and this
        // runs twice a row, which is no place for a thirty kilobyte frame.
        var path_buf: [2048]u8 = undefined;
        const text = self.cellText(entry, cd.sub_item, &path_buf);

        _ = ui.SetBkMode(dc, ui.TRANSPARENT);
        _ = ui.SetTextColor(dc, if (self.row_selected)
            self.palette.c.select_text
        else
            self.palette.c.text);

        const found = self.markRow(row, entry);
        const at: usize = if (cd.sub_item == 0) found.name_at else 0;
        const marked = (cd.sub_item == 0 or found.covers_path) and
            highlight.anyIn(text, &found.marks, at);

        if (marked) {
            self.drawRuns(dc, box, text, &found.marks, at);
        } else {
            // Nothing to bold, so this is the control's own drawing done by
            // hand: one call, ellipsis and all.
            const wide = toWide(&self.drawn, text);
            _ = ui.DrawTextW(
                dc,
                wide.ptr,
                @intCast(wide.len),
                &box,
                text_flags | ui.DT_END_ELLIPSIS,
            );
        }
        return ui.CDRF_SKIPDEFAULT;
    }

    /// Lays the runs of a cell out left to right. Each is measured in its own
    /// weight, because bold text is wider than plain and a cell holding both
    /// is the width of neither.
    fn drawRuns(
        self: *Window,
        dc: ui.HANDLE,
        rect: ui.Rect,
        text: []const u8,
        marks: *const highlight.Marks,
        at: usize,
    ) void {
        const plain = self.font orelse return;
        var split: [max_runs]highlight.Run = undefined;
        const n = highlight.runs(text, marks, at, &split);

        var x = rect.left;
        for (split[0..n]) |piece| {
            if (x >= rect.right) break;
            _ = ui.SelectObject(dc, if (piece.matched) self.bold orelse plain else plain);

            const wide = toWide(&self.drawn, text[piece.from..piece.to]);
            if (wide.len == 0) continue;

            var size: ui.Size = .{};
            const measured = ui.GetTextExtentPoint32W(dc, wide.ptr, @intCast(wide.len), &size) != 0;

            var box = rect;
            box.left = x;
            if (measured and x + size.cx <= rect.right) {
                box.right = x + size.cx;
                _ = ui.DrawTextW(dc, wide.ptr, @intCast(wide.len), &box, text_flags | ui.DT_NOCLIP);
                x += size.cx;
            } else {
                // What is left will not fit, so this run ends the cell the way
                // the control would have: cut short, with three dots after it.
                _ = ui.DrawTextW(
                    dc,
                    wide.ptr,
                    @intCast(wide.len),
                    &box,
                    text_flags | ui.DT_END_ELLIPSIS,
                );
                break;
            }
        }
        _ = ui.SelectObject(dc, plain);
    }

    fn drawIcon(self: *Window, dc: ui.HANDLE, row: usize, entry: u32, bounds: ui.Rect) void {
        const list = self.icons.list orelse return;
        const where = self.itemRect(row, ui.LVIR_ICON) orelse bounds;
        // The row is taller than the icon by however much the font asked for,
        // so the icon sits in the middle of it rather than at the top.
        const y = where.top + @divTrunc(where.height() - self.icons.icon_cy, 2);
        _ = ui.ImageList_Draw(list, self.imageFor(entry), dc, where.left, y, ui.ILD_TRANSPARENT);
    }

    fn itemRect(self: *Window, row: usize, which: i32) ?ui.Rect {
        var r: ui.Rect = .{ .left = which, .top = 0, .right = 0, .bottom = 0 };
        const got = ui.SendMessageW(self.list, ui.LVM_GETITEMRECT, row, @bitCast(@intFromPtr(&r)));
        return if (got == 0) null else r;
    }

    /// Where the name goes: after the icon, and never past the first column.
    /// `LVIR_LABEL` measures the text rather than the cell, so a name longer
    /// than its column comes back wider than the column is.
    fn nameRect(self: *Window, row: usize, bounds: ui.Rect) ?ui.Rect {
        var label = self.itemRect(row, ui.LVIR_LABEL) orelse return null;
        const width = ui.SendMessageW(self.list, ui.LVM_GETCOLUMNWIDTH, 0, 0);
        if (width > 0) {
            label.right = @min(label.right, bounds.left + @as(i32, @intCast(width)) - self.textInset());
        }
        return label;
    }

    /// Where a column past the first one draws its text. The control insets it
    /// from the cell edge and this matches, so a column that draws itself and
    /// one that does not line up under the same heading.
    fn columnRect(self: *Window, row: usize, column: usize) ?ui.Rect {
        var r: ui.Rect = .{ .left = ui.LVIR_BOUNDS, .top = @intCast(column), .right = 0, .bottom = 0 };
        const got = ui.SendMessageW(
            self.list,
            ui.LVM_GETSUBITEMRECT,
            row,
            @bitCast(@intFromPtr(&r)),
        );
        if (got == 0) return null;
        r.left += self.textInset();
        r.right -= self.textInset();
        return r;
    }

    /// Which characters of a row the query matched. Rebuilt when the list asks
    /// about another row, or when a new search has made the last answer stale.
    fn markRow(self: *Window, row: usize, entry: u32) *const RowMarks {
        const found = &self.marks;
        if (found.stamp == self.stamp and found.row == row and found.entry == entry) return found;
        found.* = .{ .stamp = self.stamp, .row = row, .entry = entry };

        const q = self.parsed orelse return found;
        if (q.isEmpty()) return found;

        const name = self.index.nameOf(entry);
        // Whichever string the search compared against is the one to mark. A
        // name-mode search never looked at the directory, so the directory
        // keeps out of it; a path-mode one matched the whole path at once,
        // which is how a match straddling the last separator comes out bold on
        // both sides of it.
        if (self.searcher.mode == .name) {
            found.marks = highlight.mark(name, 0, q, .name);
            return found;
        }

        var buf: [highlight.limit]u8 = undefined;
        const full = self.index.path(entry, &buf);
        const name_at = full.len -| name.len;
        // A path too long for the buffer comes back cut short, which would put
        // the name somewhere it is not and bold the wrong letters of it. The
        // name on its own is still worth marking, and is what name mode would
        // have given this row anyway.
        if (!std.mem.eql(u8, full[name_at..], name)) {
            found.marks = highlight.mark(name, 0, q, .name);
            return found;
        }

        found.name_at = name_at;
        found.marks = highlight.mark(full, name_at, q, .path);
        found.covers_path = true;
        return found;
    }

    /// Everything that has to happen without anyone typing: files appearing on
    /// their own, and sizes arriving behind the interface.
    fn tick(self: *Window) void {
        if (!self.ready_to_search) {
            self.repaint();
            return;
        }
        // Rebuilding the results under an open menu would move the row it is
        // pointing at. Whatever the journal has can wait for it to close.
        if (self.menu.isOpen() or self.renaming != null) return;

        // Windows writes files all the time on its own, so folding the journal
        // in on every tick would re-search several times a second for changes
        // nobody was waiting on.
        if (self.monitor.hasPending() and self.since_change.readMillis() >= change_settle_ms) {
            self.since_change = w.Timer.start();
            self.searcher.invalidate();
            self.runSearch(.keep);
            return;
        }

        // Sizes are still arriving, so the rows on screen keep changing even
        // though nothing was typed and no file moved. One more pass once it
        // has finished, for whatever landed after the last one.
        const sizing = !self.sizer.progress().finished;
        if (sizing or self.sizes_unseen) {
            _ = ui.InvalidateRect(self.list, null, 0);
            self.repaint();
        }
        self.sizes_unseen = sizing;
    }

    // ---- keys ----

    /// Handled before the search box sees them, so the arrows can drive the
    /// results while the caret stays where the typing goes.
    fn editKey(self: *Window, vk: u16) bool {
        const ctrl = ctrlDown();
        switch (vk) {
            w.VK_UP => self.moveSelection(-1),
            w.VK_DOWN => self.moveSelection(1),
            w.VK_PRIOR => self.moveSelection(-self.pageRows()),
            w.VK_NEXT => self.moveSelection(self.pageRows()),
            w.VK_RETURN => self.openSelected(shiftDown()),
            w.VK_ESCAPE => self.escape(),
            w.VK_HOME => {
                if (!ctrl) return false;
                self.moveSelection(std.math.minInt(isize));
            },
            w.VK_END => {
                if (!ctrl) return false;
                self.moveSelection(std.math.maxInt(isize));
            },
            w.VK_BACK => {
                // The edit control has no word delete of its own, and letting
                // it through puts a box character in the box instead.
                if (!ctrl) return false;
                self.deleteWordBack();
            },
            'C' => {
                // Copying the path is what a file search is for, but not at the
                // cost of copying text the user deliberately selected first.
                if (!ctrl or self.editHasSelection()) return false;
                self.copySelected();
            },
            'Q' => {
                if (!ctrl) return false;
                _ = ui.DestroyWindow(self.hwnd);
            },
            else => return false,
        }
        return true;
    }

    fn escape(self: *Window) void {
        if (self.query.items.len > 0) {
            const empty = std.unicode.utf8ToUtf16LeStringLiteral("");
            _ = ui.SetWindowTextW(self.edit, empty);
            return;
        }
        // Leaving throws away an index that took seconds to build, so escape
        // only does it once there is nothing left to clear.
        _ = ui.DestroyWindow(self.hwnd);
    }

    fn editSelection(self: *Window) struct { from: u32, to: u32 } {
        var from: u32 = 0;
        var to: u32 = 0;
        _ = ui.SendMessageW(
            self.edit,
            ui.EM_GETSEL,
            @intFromPtr(&from),
            @bitCast(@intFromPtr(&to)),
        );
        return .{ .from = from, .to = to };
    }

    fn editHasSelection(self: *Window) bool {
        const sel = self.editSelection();
        return sel.to > sel.from;
    }

    fn deleteWordBack(self: *Window) void {
        const sel = self.editSelection();
        if (sel.to > sel.from or sel.from == 0) return;

        // The caret counts UTF-16 units and so does the query once it is back
        // in that form, which is the only place the two have to agree.
        var wide: [4096]u16 = undefined;
        const len = ui.GetWindowTextW(self.edit, &wide, wide.len);
        if (len <= 0) return;
        const at = @min(sel.from, @as(u32, @intCast(len)));

        var start = at;
        while (start > 0 and wide[start - 1] == ' ') start -= 1;
        while (start > 0 and wide[start - 1] != ' ') start -= 1;

        _ = ui.SendMessageW(self.edit, ui.EM_SETSEL, start, @intCast(at));
        const empty = std.unicode.utf8ToUtf16LeStringLiteral("");
        _ = ui.SendMessageW(self.edit, ui.EM_REPLACESEL, 1, @bitCast(@intFromPtr(empty)));
    }
};

// ---- window procedures ----

/// Placements are measured from the top left of the work area of the screen
/// the window is on rather than of the screen itself, which only differs when
/// the taskbar sits along the top or the left.
fn toWorkspace(at: ui.Rect) ui.Rect {
    const monitor = ui.MonitorFromRect(&at, ui.MONITOR_DEFAULTTONEAREST) orelse return at;
    var info: ui.MonitorInfo = .{};
    if (ui.GetMonitorInfoW(monitor, &info) == 0) return at;
    const dx = info.work.left - info.monitor.left;
    const dy = info.work.top - info.monitor.top;
    return .{ .left = at.left - dx, .top = at.top - dy, .right = at.right - dx, .bottom = at.bottom - dy };
}

fn wndProc(hwnd: ui.HANDLE, msg: u32, wparam: ui.Wparam, lparam: ui.Lparam) callconv(.winapi) ui.Lresult {
    const raw = ui.GetWindowLongPtrW(hwnd, ui.GWLP_USERDATA);
    // Messages sent from inside CreateWindowExW arrive before the pointer does.
    if (raw == 0) return ui.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *Window = @ptrFromInt(@as(usize, @bitCast(raw)));
    return self.onMessage(hwnd, msg, wparam, lparam);
}

fn editProc(
    hwnd: ui.HANDLE,
    msg: u32,
    wparam: ui.Wparam,
    lparam: ui.Lparam,
    id: usize,
    ref: usize,
) callconv(.winapi) ui.Lresult {
    _ = id;
    const self: *Window = @ptrFromInt(ref);
    switch (msg) {
        ui.WM_KEYDOWN => {
            if (self.editKey(@truncate(wparam))) return 0;
        },
        // The menu key and shift+F10 both land here, and neither arrives as a
        // key this subclass would see: F10 is a system key. A right click with
        // the mouse comes with real coordinates and means the text box, which
        // keeps its own cut and paste menu. Asking for it from the keyboard
        // means the results, because that is the only thing the caret being in
        // this box could be about.
        ui.WM_CONTEXTMENU => {
            if (lparam == -1) {
                self.contextMenu(.{ .x = -1, .y = -1 });
                return 0;
            }
        },
        ui.WM_CHAR => {
            // A control character is the tail of a key already dealt with in
            // WM_KEYDOWN, Enter included. Letting it through types a box or
            // beeps. Plain backspace is the one the box handles itself.
            const unit: u16 = @truncate(wparam);
            if ((unit < 0x20 or unit == 0x7F) and unit != 0x08) return 0;
        },
        else => {},
    }
    return ui.DefSubclassProc(hwnd, msg, wparam, lparam);
}

fn listProc(
    hwnd: ui.HANDLE,
    msg: u32,
    wparam: ui.Wparam,
    lparam: ui.Lparam,
    id: usize,
    ref: usize,
) callconv(.winapi) ui.Lresult {
    _ = id;
    const self: *Window = @ptrFromInt(ref);
    switch (msg) {
        // The box that opens over a row to rename it is a child of the list
        // view, so it asks the list view for its colours rather than the
        // window. Left alone it is a white rectangle in a dark list.
        ui.WM_CTLCOLOREDIT => return self.fieldColors(wparam) orelse
            ui.DefSubclassProc(hwnd, msg, wparam, lparam),
        // The headings are a child of the list view, so their notifications
        // stop here rather than reaching the window.
        ui.WM_NOTIFY => {
            const hdr: *ui.NmHdr = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (hdr.code == ui.NM_CUSTOMDRAW and self.header != null and hdr.from == self.header.?) {
                return self.drawHeader(@ptrCast(hdr));
            }
        },
        // Typing anywhere in the window means typing a query, so the character
        // goes to the search box along with the caret.
        ui.WM_CHAR => {
            const unit: u16 = @truncate(wparam);
            if (unit >= 0x20 and unit != 0x7F) {
                _ = ui.SetFocus(self.edit);
                _ = ui.SendMessageW(self.edit, ui.WM_CHAR, wparam, lparam);
            }
            // Control characters are the tail of keys already handled, and the
            // list view's type-to-find has no use for them.
            return 0;
        },
        ui.WM_CONTEXTMENU => {
            const packed_pos: usize = @bitCast(lparam);
            self.contextMenu(.{
                .x = @as(i16, @bitCast(@as(u16, @truncate(packed_pos)))),
                .y = @as(i16, @bitCast(@as(u16, @truncate(packed_pos >> 16)))),
            });
            return 0;
        },
        ui.WM_KEYDOWN => {
            const vk: u16 = @truncate(wparam);
            if (vk == w.VK_ESCAPE) {
                self.escape();
                return 0;
            }
            if (vk == w.VK_BACK) {
                _ = ui.SetFocus(self.edit);
                return 0;
            }
            if (ctrlDown() and (vk == 'C' or vk == 'Q')) {
                if (vk == 'C') self.copySelected() else _ = ui.DestroyWindow(self.hwnd);
                return 0;
            }
        },
        else => {},
    }
    return ui.DefSubclassProc(hwnd, msg, wparam, lparam);
}

// ---- odds and ends ----

/// Converts into a fixed buffer, taking as much as fits. The conversion in std
/// assumes room for the whole string and walks off the end otherwise, and paths
/// off the master file table run to tens of thousands of characters. Anything
/// that long is far wider than the column it is going into.
fn toWide(dest: []u16, text: []const u8) [:0]const u16 {
    // One UTF-16 unit per byte is the worst case: only a four byte sequence
    // produces two units, and it spends four bytes doing it.
    var take = text.len;
    if (take > dest.len - 1) {
        take = dest.len - 1;
        // Never cut a character in half.
        while (take > 0 and text[take] & 0xC0 == 0x80) take -= 1;
    }
    const n = std.unicode.wtf8ToWtf16Le(dest[0 .. dest.len - 1], text[0..take]) catch 0;
    dest[n] = 0;
    return dest[0..n :0];
}

/// The same directory with a different last component. Null for a name that
/// would move the file rather than rename it, or one Windows will not accept:
/// the label editor takes whatever was typed, and a slash in it would quietly
/// put the file somewhere else.
fn renamedPath(buf: []u8, from: []const u8, name: []const u8) ?[]const u8 {
    if (name.len == 0) return null;
    if (std.mem.indexOfAny(u8, name, "\\/:*?\"<>|") != null) return null;
    // Trailing dots and spaces are silently dropped by the file system, so a
    // name made only of them renames to nothing at all.
    if (std.mem.trim(u8, name, ". ").len == 0) return null;

    const cut = std.mem.lastIndexOfAny(u8, from, "\\/") orelse return null;
    const dir = from[0 .. cut + 1];
    if (dir.len + name.len > buf.len) return null;

    @memcpy(buf[0..dir.len], dir);
    @memcpy(buf[dir.len..][0..name.len], name);
    return buf[0 .. dir.len + name.len];
}

/// A one pixel outline, drawn as four thin fills. There is no themed border to
/// borrow for a control that is not drawing one.
fn frame(dc: ui.HANDLE, r: ui.Rect, brush: ui.HANDLE) void {
    const sides = [_]ui.Rect{
        .{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.top + 1 },
        .{ .left = r.left, .top = r.bottom - 1, .right = r.right, .bottom = r.bottom },
        .{ .left = r.left, .top = r.top, .right = r.left + 1, .bottom = r.bottom },
        .{ .left = r.right - 1, .top = r.top, .right = r.right, .bottom = r.bottom },
    };
    for (sides) |side| _ = ui.FillRect(dc, &side, brush);
}

/// The compiled-in icon at whichever size the system asks windows for. Null
/// leaves the default, which is the blank one.
fn loadIcon(instance: ui.HANDLE, cx: i32, cy: i32) ?ui.HANDLE {
    return ui.LoadImageW(
        instance,
        ui.app_icon,
        ui.IMAGE_ICON,
        ui.GetSystemMetrics(cx),
        ui.GetSystemMetrics(cy),
        0,
    );
}

fn ctrlDown() bool {
    return ui.GetKeyState(ui.VK_CONTROL) < 0;
}

fn shiftDown() bool {
    return ui.GetKeyState(ui.VK_SHIFT) < 0;
}

fn baseName(path: []const u8) []const u8 {
    const cut = std.mem.lastIndexOfAny(u8, path, "\\/") orelse return path;
    return path[cut + 1 ..];
}

/// A size a column can hold, which means a unit rather than ten digits of
/// bytes. One decimal is enough to tell two files apart at a glance.
fn formatSize(buf: []u8, bytes: u64) []const u8 {
    const units = [_][]const u8{ "KB", "MB", "GB", "TB", "PB" };
    if (bytes < 1024) return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "";

    var scaled = bytes;
    var unit: usize = 0;
    // Stops one short of the last unit, so the loop cannot run off the table.
    while (scaled >= 1024 * 1024 and unit + 1 < units.len) : (unit += 1) scaled /= 1024;

    const whole = scaled / 1024;
    const tenths = (scaled % 1024) * 10 / 1024;
    return std.fmt.bufPrint(buf, "{d}.{d} {s}", .{ whole, tenths, units[unit] }) catch "";
}

/// A file time in the machine's own zone, to the minute.
fn formatDate(buf: []u8, ft: i64) []const u8 {
    var local: i64 = 0;
    const shifted = if (w.FileTimeToLocalFileTime(&ft, &local) != 0) local else ft;
    const d = mft.breakDown(shifted) orelse return "";
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        d.year,
        d.month,
        d.day,
        d.hour,
        d.minute,
    }) catch "";
}

// ---- tests ----

const testing = std.testing;

test "a size reads as a unit rather than a row of digits" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0 B", formatSize(&buf, 0));
    try testing.expectEqualStrings("1023 B", formatSize(&buf, 1023));
    try testing.expectEqualStrings("1.0 KB", formatSize(&buf, 1024));
    try testing.expectEqualStrings("1.5 KB", formatSize(&buf, 1536));
    try testing.expectEqualStrings("1.0 MB", formatSize(&buf, 1024 * 1024));
    try testing.expectEqualStrings("2.5 GB", formatSize(&buf, 2560 * 1024 * 1024));
}

test "the largest unit holds rather than running off the table" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("1.0 PB", formatSize(&buf, 1 << 50));
    // Ten petabytes is past anything real, and still has to print something.
    try testing.expectEqualStrings("16.0 PB", formatSize(&buf, 16 << 50));
}

test "a rename keeps the directory and replaces the name" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "C:\\src\\other.zig",
        renamedPath(&buf, "C:\\src\\main.zig", "other.zig").?,
    );
    try testing.expectEqualStrings("C:\\a.txt", renamedPath(&buf, "C:\\b.txt", "a.txt").?);
}

test "a rename that would move or break the file is refused" {
    var buf: [64]u8 = undefined;
    // Any of these would put the file somewhere other than where it was.
    try testing.expect(renamedPath(&buf, "C:\\src\\main.zig", "sub\\main.zig") == null);
    try testing.expect(renamedPath(&buf, "C:\\src\\main.zig", "sub/main.zig") == null);
    try testing.expect(renamedPath(&buf, "C:\\src\\main.zig", "D:main.zig") == null);
    // The file system drops trailing dots and spaces, so these name nothing.
    try testing.expect(renamedPath(&buf, "C:\\src\\main.zig", "") == null);
    try testing.expect(renamedPath(&buf, "C:\\src\\main.zig", "...") == null);
    try testing.expect(renamedPath(&buf, "C:\\src\\main.zig", "  ") == null);
    // A path with no separator at all has no directory to keep.
    try testing.expect(renamedPath(&buf, "main.zig", "other.zig") == null);
}

test "a name comes off the end of a path either separator" {
    try testing.expectEqualStrings("main.zig", baseName("C:\\src\\main.zig"));
    try testing.expectEqualStrings("main.zig", baseName("C:/src/main.zig"));
    try testing.expectEqualStrings("C:", baseName("C:"));
}
