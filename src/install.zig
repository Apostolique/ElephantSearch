//! Putting the service on the machine and taking it off again.
//!
//! The service binary is copied into Program Files before it is registered,
//! rather than run from wherever the zip was unpacked. It runs as LocalSystem,
//! so if it ran from a folder the user can write to, like Downloads, anything
//! running as that user could swap the file and be started as SYSTEM on the
//! next boot.
//!
//! Both need administrator rights. Asked for without them, this program starts
//! itself again elevated and hidden, and the exit code of that second run says
//! what happened.

const std = @import("std");
const w = @import("win32.zig");
const explorer = @import("explorer.zig");
const pipe = @import("pipe.zig");
const shell = @import("shell.zig");

const L = std.unicode.utf8ToUtf16LeStringLiteral;

pub const Change = enum { install, uninstall };

/// Doubles as the exit code of the elevated run, so the values are fixed.
pub const Outcome = enum(u8) {
    installed = 0,
    removed = 1,
    not_installed = 2,
    service_missing = 10,
    no_program_files = 11,
    copy_failed = 12,
    manager_failed = 13,
    start_failed = 14,
    stop_timeout = 15,
    declined = 16,
    not_elevated = 17,
    unknown = 18,
    _,

    pub fn succeeded(self: Outcome) bool {
        return self == .installed or self == .removed or self == .not_installed;
    }

    pub fn describe(self: Outcome) []const u8 {
        return switch (self) {
            .installed => "the service is installed and running, so reading the drives no longer needs administrator rights",
            .removed => "the service is uninstalled",
            .not_installed => "the service was not installed",
            .service_missing => "elephant-service.exe has to sit next to elephant.exe",
            .no_program_files => "could not find the Program Files folder",
            .copy_failed => "could not copy elephant-service.exe into Program Files",
            .manager_failed => "the service manager refused the change",
            .start_failed => "the service is installed but would not start",
            .stop_timeout => "the service already installed would not stop",
            .declined => "administrator rights were not granted",
            .not_elevated => "changing the service needs administrator rights",
            else => "the service could not be changed",
        };
    }
};

pub fn flag(change: Change) []const u8 {
    return switch (change) {
        .install => "--install-service",
        .uninstall => "--uninstall-service",
    };
}

/// Makes the change, asking for administrator rights first when this process
/// does not have them. `exe` is the `elephant.exe` to run elevated.
pub fn applyElevated(gpa: std.mem.Allocator, owner: ?w.HANDLE, exe: [:0]const u16, change: Change) Outcome {
    if (shell.isElevated()) return apply(gpa, change);
    const params = switch (change) {
        .install => L("--install-service"),
        .uninstall => L("--uninstall-service"),
    };
    return switch (shell.runElevated(owner, exe, params)) {
        .exited => |code| if (code > 255) .unknown else @enumFromInt(@as(u8, @intCast(code))),
        .declined => .declined,
        .failed => .unknown,
    };
}

/// Makes the change in this process, which has to be elevated already.
pub fn apply(gpa: std.mem.Allocator, change: Change) Outcome {
    return switch (change) {
        .install => install(gpa),
        .uninstall => uninstall(gpa),
    };
}

fn install(gpa: std.mem.Allocator) Outcome {
    const from = explorer.besideThis(gpa, "elephant-service.exe") catch return .service_missing;
    defer gpa.free(from);
    const dir = programFolder(gpa) orelse return .no_program_files;
    defer gpa.free(dir);
    const to = join(gpa, dir, "\\elephant-service.exe") orelse return .unknown;
    defer gpa.free(to);

    const scm = w.OpenSCManagerW(null, null, w.SC_MANAGER_ALL_ACCESS) orelse return refused();
    defer _ = w.CloseServiceHandle(scm);

    const existing = w.OpenServiceW(scm, pipe.service_name, w.SERVICE_ALL_ACCESS);
    defer if (existing) |old| {
        _ = w.CloseServiceHandle(old);
    };
    // The old binary stays locked for as long as it runs.
    if (existing) |old| {
        if (!stop(old)) return .stop_timeout;
    }

    _ = w.CreateDirectoryW(dir, null);
    if (!samePath(from, to) and !copy(from, to)) return .copy_failed;

    // Quoted, or `C:\Program` is what the service manager tries to start.
    const command = quoted(gpa, to) orelse return .unknown;
    defer gpa.free(command);
    const display = L("ElephantSearch");

    const svc = if (existing) |old| blk: {
        if (w.ChangeServiceConfigW(
            old,
            w.SERVICE_WIN32_OWN_PROCESS,
            w.SERVICE_AUTO_START,
            w.SERVICE_ERROR_NORMAL,
            command,
            null,
            null,
            null,
            null,
            null,
            display,
        ) == 0) return .manager_failed;
        break :blk old;
    } else w.CreateServiceW(
        scm,
        pipe.service_name,
        display,
        w.SERVICE_ALL_ACCESS,
        w.SERVICE_WIN32_OWN_PROCESS,
        w.SERVICE_AUTO_START,
        w.SERVICE_ERROR_NORMAL,
        command,
        null,
        null,
        null,
        // LocalSystem, the one account that can open the volumes.
        null,
        null,
    ) orelse return .manager_failed;
    defer if (existing == null) {
        _ = w.CloseServiceHandle(svc);
    };

    configure(svc);
    return if (start(svc)) .installed else .start_failed;
}

fn uninstall(gpa: std.mem.Allocator) Outcome {
    const scm = w.OpenSCManagerW(null, null, w.SC_MANAGER_ALL_ACCESS) orelse return refused();
    defer _ = w.CloseServiceHandle(scm);

    var outcome: Outcome = .removed;
    if (w.OpenServiceW(scm, pipe.service_name, w.SERVICE_ALL_ACCESS)) |svc| {
        defer _ = w.CloseServiceHandle(svc);
        if (!stop(svc)) return .stop_timeout;
        if (w.DeleteService(svc) == 0 and w.GetLastError() != w.ERROR_SERVICE_MARKED_FOR_DELETE) {
            return .manager_failed;
        }
    } else {
        if (w.GetLastError() != w.ERROR_SERVICE_DOES_NOT_EXIST) return .manager_failed;
        outcome = .not_installed;
    }

    // Whatever an earlier install left behind goes too, registered or not.
    const dir = programFolder(gpa) orelse return outcome;
    defer gpa.free(dir);
    if (join(gpa, dir, "\\elephant-service.exe")) |to| {
        defer gpa.free(to);
        var tries: u32 = 0;
        // The process can take a moment to go once it reports stopped.
        while (w.DeleteFileW(to) == 0 and w.GetFileAttributesW(to) != w.INVALID_FILE_ATTRIBUTES and tries < 50) : (tries += 1) {
            w.Sleep(100);
        }
    }
    _ = w.RemoveDirectoryW(dir);
    return outcome;
}

fn refused() Outcome {
    return if (w.GetLastError() == w.ERROR_ACCESS_DENIED) .not_elevated else .manager_failed;
}

/// Description, the privileges it keeps, and starting again after a crash.
/// None of these is worth failing the install over.
fn configure(svc: w.SC_HANDLE) void {
    const description: w.ServiceDescription = .{
        .lpDescription = L("Reads the NTFS master file table and change journal for ElephantSearch, so searching needs no administrator rights."),
    };
    _ = w.ChangeServiceConfig2W(svc, w.SERVICE_CONFIG_DESCRIPTION, &description);

    // Everything else LocalSystem holds is dropped, impersonation and debugging
    // included, which leaves much less for anyone who got the service to run
    // code of theirs.
    const privileges: w.ServiceRequiredPrivileges = .{
        .pmszRequiredPrivileges = L("SeChangeNotifyPrivilege\x00SeManageVolumePrivilege\x00SeBackupPrivilege\x00"),
    };
    _ = w.ChangeServiceConfig2W(svc, w.SERVICE_CONFIG_REQUIRED_PRIVILEGES_INFO, &privileges);

    const actions = [_]w.ScAction{
        .{ .Type = w.SC_ACTION_RESTART, .Delay = 5000 },
        .{ .Type = w.SC_ACTION_RESTART, .Delay = 30_000 },
    };
    const failure: w.ServiceFailureActions = .{
        .dwResetPeriod = 24 * 60 * 60,
        .cActions = actions.len,
        .lpsaActions = &actions,
    };
    _ = w.ChangeServiceConfig2W(svc, w.SERVICE_CONFIG_FAILURE_ACTIONS, &failure);
}

fn state(svc: w.SC_HANDLE) ?w.DWORD {
    var status: w.ServiceStatusProcess = .{};
    var needed: w.DWORD = 0;
    if (w.QueryServiceStatusEx(svc, w.SC_STATUS_PROCESS_INFO, &status, @sizeOf(w.ServiceStatusProcess), &needed) == 0) {
        return null;
    }
    return status.dwCurrentState;
}

fn stop(svc: w.SC_HANDLE) bool {
    if (state(svc) == w.SERVICE_STOPPED) return true;
    var status: w.ServiceStatus = .{};
    _ = w.ControlService(svc, w.SERVICE_CONTROL_STOP, &status);
    var waited: u32 = 0;
    while (waited < 20_000) : (waited += 100) {
        if (state(svc) == w.SERVICE_STOPPED) return true;
        w.Sleep(100);
    }
    return false;
}

fn start(svc: w.SC_HANDLE) bool {
    if (w.StartServiceW(svc, 0, null) == 0 and w.GetLastError() != w.ERROR_SERVICE_ALREADY_RUNNING) return false;
    var waited: u32 = 0;
    while (waited < 10_000) : (waited += 100) {
        const now = state(svc) orelse return false;
        if (now == w.SERVICE_RUNNING) return true;
        if (now == w.SERVICE_STOPPED) return false;
        w.Sleep(100);
    }
    return false;
}

/// Retries for a few seconds, since the old binary stays locked until its
/// process has fully gone.
fn copy(from: [:0]const u16, to: [:0]const u16) bool {
    var tries: u32 = 0;
    while (tries < 50) : (tries += 1) {
        if (w.CopyFileW(from, to, 0) != 0) return true;
        w.Sleep(100);
    }
    return false;
}

/// `Program Files\ElephantSearch`, from the known folder rather than the
/// environment. The elevated run inherits the user's environment, and a
/// `ProgramFiles` variable pointed somewhere writable would undo the point of
/// copying the binary at all.
fn programFolder(gpa: std.mem.Allocator) ?[:0]u16 {
    var found: ?[*:0]u16 = null;
    if (w.SHGetKnownFolderPath(&w.FOLDERID_ProgramFiles, 0, null, &found) < 0) {
        w.CoTaskMemFree(found);
        return null;
    }
    defer w.CoTaskMemFree(found);
    const base = std.mem.span(found orelse return null);
    return join(gpa, base, "\\ElephantSearch");
}

fn join(gpa: std.mem.Allocator, a: []const u16, comptime b: []const u8) ?[:0]u16 {
    const tail = L(b);
    const out = gpa.allocSentinel(u16, a.len + tail.len, 0) catch return null;
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len..], tail);
    return out;
}

fn quoted(gpa: std.mem.Allocator, path: []const u16) ?[:0]u16 {
    const out = gpa.allocSentinel(u16, path.len + 2, 0) catch return null;
    out[0] = '"';
    @memcpy(out[1 .. path.len + 1], path);
    out[path.len + 1] = '"';
    return out;
}

/// Case blind, which is how NTFS compares names. Running from the installed
/// copy itself would otherwise try to copy the file over itself.
fn samePath(a: []const u16, b: []const u16) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const lx = if (x >= 'A' and x <= 'Z') x + 32 else x;
        const ly = if (y >= 'A' and y <= 'Z') y + 32 else y;
        if (lx != ly) return false;
    }
    return true;
}

test "an exit code comes back as the outcome it stands for" {
    try std.testing.expectEqual(Outcome.installed, @as(Outcome, @enumFromInt(0)));
    try std.testing.expect(Outcome.removed.succeeded());
    try std.testing.expect(!Outcome.copy_failed.succeeded());
    const odd: Outcome = @enumFromInt(200);
    try std.testing.expectEqualStrings("the service could not be changed", odd.describe());
}

test "paths compare the way NTFS names do" {
    try std.testing.expect(samePath(L("C:\\Program Files\\A.exe"), L("c:\\program files\\a.EXE")));
    try std.testing.expect(!samePath(L("C:\\a.exe"), L("C:\\b.exe")));
}

test "the binary path is quoted so the space in Program Files survives" {
    const gpa = std.testing.allocator;
    const q = quoted(gpa, L("C:\\Program Files\\x.exe")).?;
    defer gpa.free(q);
    try std.testing.expectEqualSlices(u16, L("\"C:\\Program Files\\x.exe\""), q);
}
