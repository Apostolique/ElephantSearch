//! The ElephantSearch entry in Explorer's own right click menu.
//!
//! Three keys under `HKCU\Software\Classes`, one for each thing worth
//! searching from: a folder, the empty space inside a folder, and a drive. The
//! current user rather than the machine, so adding the entry needs no
//! elevation and removing it can never leave somebody else's behind.
//!
//! Not to be confused with `shellmenu.zig`, which is the opposite direction:
//! the menu Explorer would show for a result, put up inside this program.

const std = @import("std");
const w = @import("win32.zig");

pub const Error = error{
    /// `elephant-gui.exe` is not beside this program, so the entry would have
    /// nothing to open.
    WindowMissing,
    RegistryFailed,
} || std.mem.Allocator.Error;

/// What the entry reads as in the menu.
const label = std.unicode.utf8ToUtf16LeStringLiteral("Search with ElephantSearch");

/// Both keys a verb needs. The command lives one level down, and the shell
/// creates neither.
const Spot = struct {
    verb: [:0]const u16,
    command: [:0]const u16,
};

fn spot(comptime base: []const u8) Spot {
    @setEvalBranchQuota(10_000);
    return .{
        .verb = std.unicode.utf8ToUtf16LeStringLiteral(base),
        .command = std.unicode.utf8ToUtf16LeStringLiteral(base ++ "\\command"),
    };
}

const spots = [_]Spot{
    spot("Software\\Classes\\Directory\\shell\\ElephantSearch"),
    spot("Software\\Classes\\Directory\\Background\\shell\\ElephantSearch"),
    spot("Software\\Classes\\Drive\\shell\\ElephantSearch"),
};

/// Writes the three keys. Running it again rewrites them, which is what a
/// program that has moved since needs.
pub fn add(gpa: std.mem.Allocator) Error!void {
    const exe = try windowPath(gpa);
    defer gpa.free(exe);

    const line = try commandLine(gpa, exe);
    defer gpa.free(line);

    for (spots) |s| {
        const verb = try create(s.verb);
        defer _ = w.RegCloseKey(verb);
        try setString(verb, null, label);
        // The shell pulls the picture out of the binary itself, first icon in
        // it, the same one the window uses.
        try setString(verb, std.unicode.utf8ToUtf16LeStringLiteral("Icon"), exe);

        const command = try create(s.command);
        defer _ = w.RegCloseKey(command);
        try setString(command, null, line);
    }
    announce();
}

/// Takes the entry back out. An entry that was never there is not a failure,
/// so this is safe to run twice or after a manual cleanup.
pub fn remove() Error!void {
    var trouble = false;
    for (spots) |s| {
        // The command key first. A key with something still under it cannot be
        // deleted, and leaning on that is what keeps this to the two keys
        // `add` wrote.
        if (!del(s.command)) trouble = true;
        if (!del(s.verb)) trouble = true;
    }
    announce();
    if (trouble) return error.RegistryFailed;
}

/// `"C:\...\elephant-gui.exe" --under "%V"`. The quotes matter: `Program
/// Files` is two words and the shell splits on spaces. `%V` is the folder that
/// was right clicked, and the one substitution that means the same thing for
/// all three keys, since the background of a folder has no clicked item to put
/// in `%1`.
fn commandLine(gpa: std.mem.Allocator, exe: []const u16) Error![:0]u16 {
    var line: std.ArrayList(u16) = .empty;
    defer line.deinit(gpa);
    try line.append(gpa, '"');
    try line.appendSlice(gpa, exe);
    try line.appendSlice(gpa, std.unicode.utf8ToUtf16LeStringLiteral("\" --under \"%V\""));
    return line.toOwnedSliceSentinel(gpa, 0);
}

/// Undoes what the command line does to a quoted path ending in a backslash.
/// `%V` on a drive is `C:\`, and in `"C:\"` the backslash escapes the closing
/// quote, so the argument arrives as `C:"`. No path can hold a quote, so one
/// on the end only ever means this.
pub fn folderArgument(arg: []const u8) []const u8 {
    return std.mem.trimEnd(u8, arg, "\"");
}

/// Where the window is, worked out from where this program is. Explorer runs
/// the line from whatever folder it feels like, so a relative name or one left
/// to the search path would find the wrong binary or none.
fn windowPath(gpa: std.mem.Allocator) Error![:0]u16 {
    return besideThis(gpa, "elephant-gui.exe") catch |e| switch (e) {
        error.Missing => error.WindowMissing,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// The full path of `name` in the folder this program runs from, provided
/// something is there.
pub fn besideThis(gpa: std.mem.Allocator, comptime name: []const u8) error{ Missing, OutOfMemory }![:0]u16 {
    var buf: std.ArrayList(u16) = .empty;
    defer buf.deinit(gpa);
    try buf.resize(gpa, 512);

    // Truncation comes back as a full buffer rather than as a length, so the
    // only way to know the whole path fit is that it didn't fill the space.
    while (true) {
        const n = w.GetModuleFileNameW(null, buf.items.ptr, @intCast(buf.items.len));
        if (n == 0) return error.Missing;
        if (n < buf.items.len) {
            buf.shrinkRetainingCapacity(n);
            break;
        }
        // Past what a path can hold something else is wrong.
        if (buf.items.len >= 32768) return error.Missing;
        try buf.resize(gpa, buf.items.len * 2);
    }

    const cut = std.mem.lastIndexOfScalar(u16, buf.items, '\\') orelse return error.Missing;
    buf.shrinkRetainingCapacity(cut + 1);
    try buf.appendSlice(gpa, std.unicode.utf8ToUtf16LeStringLiteral(name));

    const path = try buf.toOwnedSliceSentinel(gpa, 0);
    errdefer gpa.free(path);
    if (w.GetFileAttributesW(path.ptr) == w.INVALID_FILE_ATTRIBUTES) return error.Missing;
    return path;
}

fn create(path: [:0]const u16) Error!w.HANDLE {
    var key: w.HANDLE = undefined;
    const rc = w.RegCreateKeyExW(
        w.HKEY_CURRENT_USER,
        path,
        0,
        null,
        0,
        w.KEY_WRITE,
        null,
        &key,
        null,
    );
    if (rc != w.ERROR_SUCCESS) return error.RegistryFailed;
    return key;
}

fn setString(key: w.HANDLE, name: ?[*:0]const u16, value: [:0]const u16) Error!void {
    // The terminator is part of what a REG_SZ holds, and a value written
    // without it reads back with whatever followed it in the hive.
    const bytes: w.DWORD = @intCast((value.len + 1) * @sizeOf(u16));
    const rc = w.RegSetValueExW(key, name, 0, w.REG_SZ, @ptrCast(value.ptr), bytes);
    if (rc != w.ERROR_SUCCESS) return error.RegistryFailed;
}

fn del(path: [:0]const u16) bool {
    const rc = w.RegDeleteKeyW(w.HKEY_CURRENT_USER, path);
    return rc == w.ERROR_SUCCESS or rc == w.ERROR_FILE_NOT_FOUND;
}

/// Explorer holds on to what it has read, so a menu opened right after this
/// would otherwise still be the old one.
fn announce() void {
    w.SHChangeNotify(w.SHCNE_ASSOCCHANGED, w.SHCNF_IDLIST, null, null);
}

test "the command line quotes the program and hands the folder over" {
    const gpa = std.testing.allocator;
    const exe = std.unicode.utf8ToUtf16LeStringLiteral("C:\\Program Files\\Elephant\\elephant-gui.exe");
    const line = try commandLine(gpa, exe);
    defer gpa.free(line);

    var utf8: [256]u8 = undefined;
    const n = try std.unicode.utf16LeToUtf8(&utf8, line);
    try std.testing.expectEqualStrings(
        "\"C:\\Program Files\\Elephant\\elephant-gui.exe\" --under \"%V\"",
        utf8[0..n],
    );
}

test "a drive handed over by the menu loses the quote its backslash swallowed" {
    try std.testing.expectEqualStrings("C:", folderArgument("C:\""));
    try std.testing.expectEqualStrings("C:\\Users", folderArgument("C:\\Users"));
    try std.testing.expectEqualStrings("C:\\", folderArgument("C:\\"));
}

test "every key sits under the current user and carries a command" {
    for (spots) |s| {
        var utf8: [256]u8 = undefined;
        const n = try std.unicode.utf16LeToUtf8(&utf8, s.verb);
        try std.testing.expect(std.mem.startsWith(u8, utf8[0..n], "Software\\Classes\\"));

        const m = try std.unicode.utf16LeToUtf8(&utf8, s.command);
        try std.testing.expect(std.mem.endsWith(u8, utf8[0..m], "\\command"));
    }
}
