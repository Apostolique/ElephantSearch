//! Dragging a result out of the window and dropping it on another program, the
//! way a file is dragged out of Explorer.
//!
//! The data that travels is the shell's own for the file, asked of the folder
//! holding it, so a drop target sees exactly what an Explorer drag would give
//! it. The shell also runs the drag: it draws the image under the pointer,
//! follows the buttons, and talks to whatever the pointer is over.

const std = @import("std");
const w = @import("win32.zig");
const ui = @import("win32_ui.zig");
const shellmenu = @import("shellmenu.zig");

const IID_IDataObject: shellmenu.Guid = .{
    .a = 0x0000010E,
    .b = 0,
    .c = 0,
    .d = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 },
};

/// Only release is ever called, but it is found by position, so the two before
/// it have to be here.
const DataObject = extern struct {
    vtable: *const extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const fn (*DataObject) callconv(.winapi) u32,
    },
};

/// The same three Explorer offers. Which one a drop does is the target's call,
/// and holding ctrl, shift or alt picks one the same as it does in Explorer.
const DROPEFFECT_COPY: u32 = 1;
const DROPEFFECT_MOVE: u32 = 2;
const DROPEFFECT_LINK: u32 = 4;

const DRAGDROP_S_DROP: w.HRESULT = 0x0004_0100;

/// Passing no drop source has the shell make one that follows whichever button
/// started the drag, so a right drag ends in Explorer's copy, move or shortcut
/// menu.
extern "shell32" fn SHDoDragDrop(
    hwnd: ?ui.HANDLE,
    pdata: *DataObject,
    pdsrc: ?*anyopaque,
    dwEffect: u32,
    pdwEffect: *u32,
) callconv(.winapi) w.HRESULT;

pub const Outcome = enum {
    dropped,
    cancelled,
    /// The shell would not describe this path, which is what a file that has
    /// been deleted looks like from here.
    unavailable,
};

/// Runs a drag of `path` until the button comes up. Has to be called while
/// the button that started it is still down, and on a thread where OLE is up.
pub fn run(gpa: std.mem.Allocator, hwnd: ui.HANDLE, path: []const u8) Outcome {
    const object = shellmenu.uiObject(gpa, hwnd, path, &IID_IDataObject) orelse return .unavailable;
    const data: *DataObject = @ptrCast(@alignCast(object));
    defer _ = data.vtable.release(data);

    var effect: u32 = 0;
    const result = SHDoDragDrop(hwnd, data, null, DROPEFFECT_COPY | DROPEFFECT_MOVE | DROPEFFECT_LINK, &effect);
    return if (result == DRAGDROP_S_DROP) .dropped else .cancelled;
}
