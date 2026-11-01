//! Handing a path back to Windows: opening it, showing it in Explorer, and
//! putting it on the clipboard. Also asking for administrator rights, which
//! means starting this program over through the shell.
//!
//! Shared because both front ends offer the same three actions on a result and
//! a difference between them would only ever be a bug.

const std = @import("std");
const w = @import("win32.zig");

/// Opens a path with whatever is registered for it. False when the shell
/// refused, which is what an unknown extension or a file gone missing looks
/// like from here.
pub fn open(gpa: std.mem.Allocator, path: []const u8) bool {
    const wide = std.unicode.wtf8ToWtf16LeAllocZ(gpa, path) catch return false;
    defer gpa.free(wide);
    const verb = std.unicode.utf8ToUtf16LeStringLiteral("open");
    return w.ShellExecuteW(null, verb, wide, null, null, w.SW_SHOWNORMAL) > 32;
}

/// Explorer only highlights a file when it is handed the item itself, which an
/// `/select,` command line cannot express once the shell re-parses it. An id
/// list with a count of zero means "open the parent, pick this out".
pub fn reveal(gpa: std.mem.Allocator, path: []const u8) bool {
    const wide = std.unicode.wtf8ToWtf16LeAllocZ(gpa, path) catch return false;
    defer gpa.free(wide);

    const item = w.ILCreateFromPathW(wide) orelse return false;
    defer w.ILFree(item);

    // The shell wants COM up on this thread. S_FALSE says it already was, and
    // both of those still owe an uninitialise.
    const com = w.CoInitializeEx(null, w.COINIT_APARTMENTTHREADED);
    defer if (com >= 0) w.CoUninitialize();

    return w.SHOpenFolderAndSelectItems(item, 0, null, 0) >= 0;
}

pub fn copyText(gpa: std.mem.Allocator, text: []const u8) bool {
    const wide = std.unicode.wtf8ToWtf16LeAllocZ(gpa, text) catch return false;
    defer gpa.free(wide);

    const with_terminator = wide.ptr[0 .. wide.len + 1];
    const block = w.GlobalAlloc(w.GMEM_MOVEABLE, with_terminator.len * 2) orelse return false;

    var placed = false;
    // A moveable block has to be locked to get an address, and freeing it is
    // only ours to do until the clipboard accepts it.
    defer if (!placed) {
        _ = w.GlobalFree(block);
    };

    {
        const dest = w.GlobalLock(block) orelse return false;
        const chars: [*]u16 = @ptrCast(@alignCast(dest));
        @memcpy(chars[0..with_terminator.len], with_terminator);
        _ = w.GlobalUnlock(block);
    }

    if (w.OpenClipboard(null) == 0) return false;
    defer _ = w.CloseClipboard();
    _ = w.EmptyClipboard();
    if (w.SetClipboardData(w.CF_UNICODETEXT, block) == null) return false;

    placed = true;
    return true;
}

/// Whether this process already holds administrator rights. A token that
/// cannot be read counts as not, which only costs an offer that was not needed.
pub fn isElevated() bool {
    var token: w.HANDLE = undefined;
    if (w.OpenProcessToken(w.GetCurrentProcess(), w.TOKEN_QUERY, &token) == 0) return false;
    defer _ = w.CloseHandle(token);

    var elevated: w.DWORD = 0;
    var got: w.DWORD = 0;
    if (w.GetTokenInformation(token, w.TokenElevation, &elevated, @sizeOf(w.DWORD), &got) == 0) {
        return false;
    }
    return elevated != 0;
}

/// Starts this program again with administrator rights and the arguments it
/// was given. Returns once the new process is running, or false when the
/// prompt was turned down or the shell refused. The caller is the one to quit.
pub fn relaunchElevated(gpa: std.mem.Allocator, owner: ?w.HANDLE) bool {
    return relaunch(gpa, owner, std.unicode.utf8ToUtf16LeStringLiteral("runas"));
}

/// The same with whatever rights this process has, for once the service is
/// there and a fresh start is all it takes to use it.
pub fn relaunchPlain(gpa: std.mem.Allocator, owner: ?w.HANDLE) bool {
    return relaunch(gpa, owner, std.unicode.utf8ToUtf16LeStringLiteral("open"));
}

fn relaunch(gpa: std.mem.Allocator, owner: ?w.HANDLE, verb: [*:0]const u16) bool {
    var exe_buf: [32768]u16 = undefined;
    const n = w.GetModuleFileNameW(null, &exe_buf, exe_buf.len - 1);
    if (n == 0 or n >= exe_buf.len - 1) return false;
    exe_buf[n] = 0;

    const params = gpa.dupeZ(u16, argumentsOf(std.mem.span(w.GetCommandLineW()))) catch return false;
    defer gpa.free(params);

    return w.ShellExecuteW(owner, verb, exe_buf[0..n :0], params, null, w.SW_SHOWNORMAL) > 32;
}

pub const Ran = union(enum) {
    exited: u32,
    /// The prompt for administrator rights was turned down.
    declined,
    failed,
};

/// Runs `exe` with administrator rights and no window, and waits for it.
pub fn runElevated(owner: ?w.HANDLE, exe: [:0]const u16, params: [:0]const u16) Ran {
    var info: w.ShellExecuteInfo = .{
        .fMask = w.SEE_MASK_NOCLOSEPROCESS | w.SEE_MASK_NOASYNC,
        .hwnd = owner,
        .lpVerb = std.unicode.utf8ToUtf16LeStringLiteral("runas"),
        .lpFile = exe,
        .lpParameters = params,
        .nShow = w.SW_HIDE,
    };
    if (w.ShellExecuteExW(&info) == 0) {
        return if (w.GetLastError() == w.ERROR_CANCELLED) .declined else .failed;
    }
    const process = info.hProcess orelse return .failed;
    defer _ = w.CloseHandle(process);
    _ = w.WaitForSingleObject(process, w.INFINITE);
    var code: w.DWORD = 0;
    if (w.GetExitCodeProcess(process, &code) == 0) return .failed;
    return .{ .exited = code };
}

/// Everything on a command line after the program name, untouched, so the
/// arguments reach the new process exactly as this one got them. The program
/// name follows simpler rules than the arguments: no escapes, and a quote only
/// ever opens or closes it.
fn argumentsOf(line: []const u16) []const u16 {
    var i: usize = 0;
    if (line.len > 0 and line[0] == '"') {
        i = 1;
        while (i < line.len and line[i] != '"') i += 1;
        if (i < line.len) i += 1;
    } else {
        while (i < line.len and line[i] != ' ' and line[i] != '\t') i += 1;
    }
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    return line[i..];
}

test "the program name comes off a command line and the arguments stay as given" {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    try std.testing.expectEqualSlices(
        u16,
        L("--under \"C:\\Program Files\\\" -e"),
        argumentsOf(L("\"C:\\Program Files\\elephant-gui.exe\"  --under \"C:\\Program Files\\\" -e")),
    );
    try std.testing.expectEqualSlices(u16, L("--rebuild"), argumentsOf(L("elephant-gui.exe --rebuild")));
    try std.testing.expectEqualSlices(u16, L(""), argumentsOf(L("elephant-gui.exe")));
    try std.testing.expectEqualSlices(u16, L(""), argumentsOf(L("\"C:\\a b\\elephant-gui.exe\"")));
}
