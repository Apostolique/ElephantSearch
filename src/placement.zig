//! Where the window was when it last closed, so the next one opens there.
//!
//! One line of text next to the index cache: the normal rect's four edges and
//! whether it was maximized. Text because it is five numbers, and a file that
//! fails to parse costs nothing worse than the default position.

const std = @import("std");
const w = @import("win32.zig");
const ui = @import("win32_ui.zig");
const cache = @import("cache.zig");

pub const Saved = struct {
    /// The window's rect when it is neither maximized nor minimized, in the
    /// workspace coordinates `GetWindowPlacement` hands out.
    normal: ui.Rect,
    maximized: bool,
};

const file_name = std.unicode.utf8ToUtf16LeStringLiteral("\\window.txt");

/// Bigger than any desktop, so a number past it means the file is not ours.
const limit: i32 = 1 << 20;

/// The longest line `format` writes, with room to spare.
const max_len = 64;

pub fn load(gpa: std.mem.Allocator) ?Saved {
    return loadNamed(gpa, file_name);
}

/// Best effort: a window that cannot remember where it was still works.
pub fn save(gpa: std.mem.Allocator, saved: Saved) void {
    saveNamed(gpa, file_name, saved);
}

fn loadNamed(gpa: std.mem.Allocator, file: [:0]const u16) ?Saved {
    const path = cache.pathNamed(gpa, file) orelse return null;
    defer gpa.free(path);

    const handle = w.CreateFileW(path.ptr, w.GENERIC_READ, w.FILE_SHARE_READ, null, w.OPEN_EXISTING, w.FILE_ATTRIBUTE_NORMAL, null);
    if (handle == w.INVALID_HANDLE_VALUE) return null;
    defer _ = w.CloseHandle(handle);

    var buf: [max_len]u8 = undefined;
    var got: w.DWORD = 0;
    if (w.ReadFile(handle, &buf, buf.len, &got, null) == 0) return null;
    return parse(buf[0..got]);
}

fn saveNamed(gpa: std.mem.Allocator, file: [:0]const u16, saved: Saved) void {
    const path = cache.pathNamed(gpa, file) orelse return;
    defer gpa.free(path);

    var buf: [max_len]u8 = undefined;
    const text = format(&buf, saved);

    const handle = w.CreateFileW(path.ptr, w.GENERIC_WRITE, 0, null, w.CREATE_ALWAYS, w.FILE_ATTRIBUTE_NORMAL, null);
    if (handle == w.INVALID_HANDLE_VALUE) return;
    defer _ = w.CloseHandle(handle);
    _ = w.WriteFile(handle, text.ptr, @intCast(text.len), null, null);
}

fn format(buf: *[max_len]u8, saved: Saved) []const u8 {
    const r = saved.normal;
    return std.fmt.bufPrint(buf, "{d} {d} {d} {d} {d}\n", .{
        r.left, r.top, r.right, r.bottom, @intFromBool(saved.maximized),
    }) catch unreachable;
}

fn parse(text: []const u8) ?Saved {
    var numbers: [5]i32 = undefined;
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
    for (&numbers) |*n| {
        const word = words.next() orelse return null;
        n.* = std.fmt.parseInt(i32, word, 10) catch return null;
        if (n.* <= -limit or n.* >= limit) return null;
    }
    if (words.next() != null) return null;

    const normal: ui.Rect = .{ .left = numbers[0], .top = numbers[1], .right = numbers[2], .bottom = numbers[3] };
    if (normal.width() <= 0 or normal.height() <= 0) return null;
    if (numbers[4] != 0 and numbers[4] != 1) return null;
    return .{ .normal = normal, .maximized = numbers[4] == 1 };
}

test "a saved position reads back the same" {
    var buf: [max_len]u8 = undefined;
    const saved: Saved = .{
        .normal = .{ .left = -1913, .top = 42, .right = -933, .bottom = 662 },
        .maximized = true,
    };
    try std.testing.expectEqual(saved, parse(format(&buf, saved)).?);
}

test "anything else is no position at all" {
    try std.testing.expect(parse("") == null);
    try std.testing.expect(parse("10 10 500 400") == null);
    try std.testing.expect(parse("10 10 500 400 0 7") == null);
    try std.testing.expect(parse("10 10 500 400 2") == null);
    try std.testing.expect(parse("500 10 10 400 0") == null);
    try std.testing.expect(parse("10 10 10 400 0") == null);
    try std.testing.expect(parse("10 10 99999999 400 0") == null);
    try std.testing.expect(parse("left 10 500 400 0") == null);
}

test "a position survives the file" {
    const gpa = std.testing.allocator;
    const scratch = std.unicode.utf8ToUtf16LeStringLiteral("\\window.txt.test");
    const saved: Saved = .{
        .normal = .{ .left = 100, .top = 200, .right = 1080, .bottom = 820 },
        .maximized = false,
    };
    saveNamed(gpa, scratch, saved);
    defer if (cache.pathNamed(gpa, scratch)) |path| {
        _ = w.DeleteFileW(path.ptr);
        gpa.free(path);
    };
    try std.testing.expectEqual(saved, loadNamed(gpa, scratch).?);
}
