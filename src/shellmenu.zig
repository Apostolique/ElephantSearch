//! The right click menu Explorer would show for a file.
//!
//! Not a menu built here that resembles one. The shell is asked for the file's
//! own `IContextMenu` and it fills the menu itself, so open with, rename, send
//! to and whatever Git or an editor installed all arrive without this program
//! knowing any of them exist.
//!
//! Zig has no COM, so the three interfaces this needs are declared as their
//! vtables and called through them. That is all COM is at this level: a struct
//! whose first field points at an array of function pointers, in a fixed order
//! nobody is allowed to change.
//!
//! The awkward part is that the shell draws its own submenus. While its menu is
//! up, four window messages have to be handed back to it, which is what
//! `forward` is for and why the interface pointer outlives the call that made
//! it.

const std = @import("std");
const w = @import("win32.zig");
const ui = @import("win32_ui.zig");

pub const Guid = extern struct {
    a: u32,
    b: u16,
    c: u16,
    d: [8]u8,
};

/// The tail every interface id defined alongside OLE shares.
const ole_tail = [8]u8{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 };

const IID_IShellFolder: Guid = .{ .a = 0x000214E6, .b = 0, .c = 0, .d = ole_tail };
const IID_IContextMenu: Guid = .{ .a = 0x000214E4, .b = 0, .c = 0, .d = ole_tail };
const IID_IContextMenu2: Guid = .{ .a = 0x000214F4, .b = 0, .c = 0, .d = ole_tail };
const IID_IContextMenu3: Guid = .{
    .a = 0xBCFCE0A0,
    .b = 0xEC17,
    .c = 0x11D0,
    .d = .{ 0x8D, 0x10, 0x00, 0xA0, 0xC9, 0x0F, 0x27, 0x19 },
};

/// Methods this file never calls still have to be here, because a vtable is
/// found by position and leaving one out shifts everything after it.
const unused = *const anyopaque;

const ShellFolder = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        query_interface: unused,
        add_ref: unused,
        release: *const fn (*ShellFolder) callconv(.winapi) u32,
        parse_display_name: unused,
        enum_objects: unused,
        bind_to_object: unused,
        bind_to_storage: unused,
        compare_ids: unused,
        create_view_object: unused,
        get_attributes_of: unused,
        get_ui_object_of: *const fn (
            *ShellFolder,
            ?ui.HANDLE,
            u32,
            [*]const *const w.ItemIdList,
            *const Guid,
            ?*u32,
            *?*ContextMenu,
        ) callconv(.winapi) w.HRESULT,
    };
};

const ContextMenu = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        query_interface: *const fn (
            *ContextMenu,
            *const Guid,
            *?*ContextMenu,
        ) callconv(.winapi) w.HRESULT,
        add_ref: unused,
        release: *const fn (*ContextMenu) callconv(.winapi) u32,
        query_context_menu: *const fn (
            *ContextMenu,
            ui.HANDLE,
            u32,
            u32,
            u32,
            u32,
        ) callconv(.winapi) w.HRESULT,
        invoke_command: *const fn (*ContextMenu, *const InvokeInfo) callconv(.winapi) w.HRESULT,
        /// `name` is a wide buffer when the flags ask for a wide verb, and
        /// `max` counts characters rather than bytes either way.
        get_command_string: *const fn (
            *ContextMenu,
            usize,
            u32,
            ?*u32,
            [*]u8,
            u32,
        ) callconv(.winapi) w.HRESULT,
        /// Only present on an IContextMenu2, so only reachable through a
        /// pointer that came back from asking for one.
        handle_menu_msg: *const fn (
            *ContextMenu,
            u32,
            ui.Wparam,
            ui.Lparam,
        ) callconv(.winapi) w.HRESULT,
        /// Likewise IContextMenu3.
        handle_menu_msg2: *const fn (
            *ContextMenu,
            u32,
            ui.Wparam,
            ui.Lparam,
            ?*ui.Lresult,
        ) callconv(.winapi) w.HRESULT,
    };
};

/// CMINVOKECOMMANDINFOEX. The A and W halves both have to be filled in: which
/// one a shell extension reads is up to the extension.
const InvokeInfo = extern struct {
    size: u32 = @sizeOf(InvokeInfo),
    mask: u32 = 0,
    hwnd: ?ui.HANDLE = null,
    verb: ?[*:0]const u8 = null,
    parameters: ?[*:0]const u8 = null,
    directory: ?[*:0]const u8 = null,
    show: i32 = w.SW_SHOWNORMAL,
    hot_key: u32 = 0,
    icon: ?ui.HANDLE = null,
    title: ?[*:0]const u8 = null,
    /// Unaligned because this field carries a menu offset as often as it
    /// carries a string, and an odd offset is not an address a `u16` could
    /// ever sit at. Asking for the natural alignment makes every second entry
    /// in the menu a panic.
    verb_w: ?[*:0]align(1) const u16 = null,
    parameters_w: ?[*:0]const u16 = null,
    directory_w: ?[*:0]const u16 = null,
    title_w: ?[*:0]const u16 = null,
    invoke_at: ui.Point = .{ .x = 0, .y = 0 },
};

comptime {
    std.debug.assert(@offsetOf(InvokeInfo, "verb") == 16);
    std.debug.assert(@offsetOf(InvokeInfo, "show") == 40);
    std.debug.assert(@offsetOf(InvokeInfo, "verb_w") == 64);
    std.debug.assert(@sizeOf(InvokeInfo) == 104);
}

extern "shell32" fn SHBindToParent(
    pidl: *const w.ItemIdList,
    riid: *const Guid,
    ppv: *?*ShellFolder,
    ppidlLast: *?*const w.ItemIdList,
) callconv(.winapi) w.HRESULT;

const CMF_NORMAL: u32 = 0x0000_0000;
const CMF_EXPLORE: u32 = 0x0000_0004;
/// Says the menu is for an item inside a view rather than for the view itself,
/// which is what several shell extensions check before offering anything.
const CMF_ITEMMENU: u32 = 0x0000_0080;
/// Says the caller can rename an item itself, which is the only way the shell
/// will offer Rename at all. It is a claim, not a request: picking it asks this
/// program to start editing the name rather than doing anything on its own.
const CMF_CANRENAME: u32 = 0x0000_0010;
const CMF_EXTENDEDVERBS: u32 = 0x0000_0100;
const CMIC_MASK_UNICODE: u32 = 0x0000_4000;
/// Ask for the verb, as wide characters.
const GCS_VERBW: u32 = 0x0000_0004;

/// Menu ids for the entries this program adds itself. They sit below the range
/// the shell is given, so which side a chosen id came from is just a compare.
const id_open: usize = 1;
const id_reveal: usize = 2;
const id_copy: usize = 3;

/// Menu ids the shell is allowed to hand out.
const first_id: u32 = 0x100;
const last_id: u32 = 0x7FFF;

/// What the user picked, for the entries this program owns. Anything from the
/// shell's half has already been run by the time `show` returns.
pub const Choice = enum {
    /// Nothing was picked, or the shell ran its own command.
    handled,
    open,
    reveal,
    copy,
    /// The shell's own Rename, which it hands back rather than performing.
    rename,
    /// The shell would not describe this path, which is what a file that has
    /// been deleted, or an NTFS metadata file that was never really a file,
    /// looks like from here.
    unavailable,
};

const own = [_]struct { id: usize, label: []const u8 }{
    .{ .id = id_open, .label = "Open" },
    .{ .id = id_reveal, .label = "Open path" },
    .{ .id = id_copy, .label = "Copy full path" },
};

pub const Menu = struct {
    /// The interface drawing the menu currently on screen, and null the rest of
    /// the time. Held across `show` because the menu's own modal loop is what
    /// sends the messages it needs.
    drawing: ?*ContextMenu = null,
    /// IContextMenu3 supersedes 2 and takes an extra result pointer.
    third: bool = false,

    pub fn isOpen(self: *const Menu) bool {
        return self.drawing != null;
    }

    /// Puts a menu for `path` on screen at a point in screen coordinates: this
    /// program's own three entries, then everything the shell would show for
    /// the file. A shell entry is invoked before this returns, while one of
    /// ours comes back for the caller to run.
    pub fn show(
        self: *Menu,
        gpa: std.mem.Allocator,
        hwnd: ui.HANDLE,
        path: []const u8,
        at: ui.Point,
        extended: bool,
    ) Choice {
        const wide = std.unicode.wtf8ToWtf16LeAllocZ(gpa, path) catch return .unavailable;
        defer gpa.free(wide);

        const pidl = w.ILCreateFromPathW(wide) orelse return .unavailable;
        defer w.ILFree(pidl);

        // The menu belongs to the containing folder, which is the only thing
        // that knows what the item in it is.
        var folder: ?*ShellFolder = null;
        var child: ?*const w.ItemIdList = null;
        if (SHBindToParent(pidl, &IID_IShellFolder, &folder, &child) < 0) return .unavailable;
        const parent = folder orelse return .unavailable;
        defer _ = parent.vtable.release(parent);
        // Points into `pidl`, so it is not freed separately.
        const item = child orelse return .unavailable;

        var found: ?*ContextMenu = null;
        const items = [_]*const w.ItemIdList{item};
        if (parent.vtable.get_ui_object_of(
            parent,
            hwnd,
            1,
            &items,
            &IID_IContextMenu,
            null,
            &found,
        ) < 0) return .unavailable;
        const menu = found orelse return .unavailable;
        defer _ = menu.vtable.release(menu);

        const popup = ui.CreatePopupMenu() orelse return .unavailable;
        defer _ = ui.DestroyMenu(popup);

        // The three this program has keys for go first, the way Everything puts
        // its own at the top. A file with no registered handler has no "Open"
        // in the shell's own list, only "Open with", so without these the menu
        // has no plain way to open anything.
        var label: [64]u16 = undefined;
        for (own, 0..) |entry, i| {
            const n = std.unicode.wtf8ToWtf16Le(label[0 .. label.len - 1], entry.label) catch continue;
            label[n] = 0;
            _ = ui.InsertMenuW(popup, @intCast(i), ui.MF_BYPOSITION | ui.MF_STRING, entry.id, @ptrCast(&label));
        }
        _ = ui.InsertMenuW(popup, own.len, ui.MF_BYPOSITION | ui.MF_SEPARATOR, 0, null);

        // Holding shift is how Explorer asks for the longer list, so it means
        // the same thing here.
        const flags = CMF_NORMAL | CMF_EXPLORE | CMF_ITEMMENU | CMF_CANRENAME |
            @as(u32, if (extended) CMF_EXTENDEDVERBS else 0);
        if (menu.vtable.query_context_menu(menu, popup, own.len + 1, first_id, last_id, flags) < 0) {
            return .unavailable;
        }
        _ = ui.SetMenuDefaultItem(popup, id_open, 0);

        self.begin(menu);
        defer self.end();

        const chosen = ui.TrackPopupMenuEx(
            popup,
            ui.TPM_RETURNCMD | ui.TPM_RIGHTBUTTON | ui.TPM_LEFTALIGN,
            at.x,
            at.y,
            hwnd,
            null,
        );
        if (chosen <= 0) return .handled;
        switch (@as(usize, @intCast(chosen))) {
            id_open => return .open,
            id_reveal => return .reveal,
            id_copy => return .copy,
            else => {},
        }
        if (chosen < @as(i32, @intCast(first_id))) return .handled;

        // A shell command is named by its offset from the first id, passed
        // where a string pointer goes. The shell tells the two apart by
        // magnitude, and offset zero really is a null pointer.
        const offset: usize = @intCast(chosen - @as(i32, @intCast(first_id)));

        // Rename is the one entry the shell adds on the promise that the
        // caller will carry it out. Invoking it would do nothing at all.
        if (verbIs(menu, offset, "rename")) return .rename;

        var info: InvokeInfo = .{
            .mask = CMIC_MASK_UNICODE,
            .hwnd = hwnd,
            .invoke_at = at,
        };
        if (offset != 0) {
            info.verb = @ptrFromInt(offset);
            info.verb_w = @ptrFromInt(offset);
        }
        _ = menu.vtable.invoke_command(menu, &info);
        return .handled;
    }

    /// Whether a command's verb is the one named. Verbs are the stable names
    /// behind the labels, so this keeps working on a machine that shows the
    /// menu in another language.
    fn verbIs(menu: *ContextMenu, offset: usize, want: []const u8) bool {
        var buf: [64]u16 = @splat(0);
        if (menu.vtable.get_command_string(
            menu,
            offset,
            GCS_VERBW,
            null,
            @ptrCast(&buf),
            buf.len,
        ) < 0) return false;

        var seen: usize = 0;
        while (seen < buf.len and buf[seen] != 0) seen += 1;
        if (seen != want.len) return false;
        for (buf[0..seen], want) |unit, expected| {
            if (unit > 127) return false;
            if (std.ascii.toLower(@intCast(unit)) != std.ascii.toLower(expected)) return false;
        }
        return true;
    }

    /// Asks for the newest interface the menu supports, since only those two
    /// can draw their own submenus.
    fn begin(self: *Menu, menu: *ContextMenu) void {
        var got: ?*ContextMenu = null;
        if (menu.vtable.query_interface(menu, &IID_IContextMenu3, &got) >= 0) {
            if (got) |handler| {
                self.drawing = handler;
                self.third = true;
                return;
            }
        }
        if (menu.vtable.query_interface(menu, &IID_IContextMenu2, &got) >= 0) {
            if (got) |handler| {
                self.drawing = handler;
                self.third = false;
            }
        }
    }

    fn end(self: *Menu) void {
        if (self.drawing) |handler| _ = handler.vtable.release(handler);
        self.drawing = null;
        self.third = false;
    }

    /// Hands a message to the shell if its menu wants it. Returns null when the
    /// window should carry on handling the message itself.
    pub fn forward(self: *Menu, msg: u32, wparam: ui.Wparam, lparam: ui.Lparam) ?ui.Lresult {
        const handler = self.drawing orelse return null;
        switch (msg) {
            ui.WM_INITMENUPOPUP, ui.WM_DRAWITEM, ui.WM_MEASUREITEM, ui.WM_MENUCHAR => {},
            else => return null,
        }

        if (self.third) {
            var result: ui.Lresult = 0;
            if (handler.vtable.handle_menu_msg2(handler, msg, wparam, lparam, &result) < 0) {
                return null;
            }
            return result;
        }

        if (handler.vtable.handle_menu_msg(handler, msg, wparam, lparam) < 0) return null;
        // The two that ask a question want a yes; the one that only announces
        // something wants a zero.
        return if (msg == ui.WM_INITMENUPOPUP) 0 else 1;
    }
};
