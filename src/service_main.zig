//! Entry point for `elephant-service.exe`, the background service.
//!
//! It holds no index and remembers nothing between requests. All it does is
//! answer the four questions in `volume.zig` for whoever connects to the pipe,
//! which is the part of indexing that needs administrator rights. Everything
//! else, the index and the cache and the searching, stays in the program the
//! user started.
//!
//! A binary of its own rather than a flag on `elephant.exe`, so the code
//! running as LocalSystem is only this and the volume reader under it, with no
//! shell, window or search code along for the ride.

const std = @import("std");
const build_options = @import("build_options");
const w = @import("win32.zig");
const pipe = @import("pipe.zig");

const L = std.unicode.utf8ToUtf16LeStringLiteral;

const usage =
    \\elephant-service - reads the NTFS master file table for ElephantSearch.
    \\
    \\The service manager starts this. elephant --install-service puts it on the
    \\machine and elephant --uninstall-service takes it off again.
    \\
    \\  --console            serve in this terminal instead, on a pipe of its own,
    \\                       until ctrl+c
    \\      --pipe NAME      the pipe to serve on (default \\.\pipe\ElephantSearch-console)
    \\      --fake N         answer with a made up volume of N files on every
    \\                       letter, which needs no administrator rights
    \\  --version            show which version this is
    \\
    \\elephant --service-pipe NAME reads through a console run.
    \\
;

var gpa: std.mem.Allocator = undefined;
var server: pipe.Server = undefined;
var status_handle: ?w.SERVICE_STATUS_HANDLE = null;
var check_point: w.DWORD = 0;

pub fn main(init: std.process.Init) !void {
    gpa = init.gpa;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);

    var out_buf: [4096]u8 = undefined;
    var out_file = std.Io.File.stdout().writer(init.io, &out_buf);
    const out = &out_file.interface;
    defer out.flush() catch {};

    var console = false;
    var name: [:0]const u16 = L("\\\\.\\pipe\\ElephantSearch-console");
    var fake_files: ?u32 = null;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try out.writeAll(usage);
            return;
        } else if (std.mem.eql(u8, a, "--version")) {
            try out.writeAll("ElephantSearch service " ++ build_options.version ++ "\n");
            return;
        } else if (std.mem.eql(u8, a, "--console")) {
            console = true;
        } else if (std.mem.eql(u8, a, "--pipe")) {
            i += 1;
            if (i >= argv.len) return fail(out, "--pipe needs a name\n");
            name = std.unicode.wtf8ToWtf16LeAllocZ(arena, argv[i]) catch return fail(out, "--pipe needs a name\n");
        } else if (std.mem.eql(u8, a, "--fake")) {
            i += 1;
            if (i >= argv.len) return fail(out, "--fake needs a count\n");
            fake_files = std.fmt.parseInt(u32, argv[i], 10) catch return fail(out, "--fake needs a count\n");
        } else {
            return fail(out, "unknown option, try --help\n");
        }
    }

    if (console) {
        // The installed service's own pipe is never served from here, so a
        // console run can never stand in for it.
        if (std.mem.eql(u16, name, pipe.pipe_name)) return fail(out, "that pipe belongs to the installed service\n");
        server = .{
            .gpa = gpa,
            .name = name,
            .source = if (fake_files) |n| .{ .fake = .{ .files = n } } else .direct,
        };
        server.listen() catch |e| return fail(out, switch (e) {
            error.PipeTaken => "something already listens on that pipe\n",
            error.BadName => "that is not a pipe name, which looks like \\\\.\\pipe\\something\n",
            error.BadDescriptor => "the pipe's security descriptor would not build\n",
        });
        defer server.deinit();
        var utf8: [256]u8 = undefined;
        const n = std.unicode.wtf16LeToWtf8(&utf8, name);
        try out.print("serving on {s}, ctrl+c stops\n", .{utf8[0..n]});
        try out.flush();
        server.run();
        return;
    }

    const table = [_]w.ServiceTableEntry{
        .{ .lpServiceName = pipe.service_name, .lpServiceProc = serviceMain },
        .{ .lpServiceName = null, .lpServiceProc = null },
    };
    if (w.StartServiceCtrlDispatcherW(&table) == 0) {
        if (w.GetLastError() == w.ERROR_FAILED_SERVICE_CONTROLLER_CONNECT) {
            try out.writeAll(usage);
            return fail(out, "");
        }
        return fail(out, "the service manager would not take this process\n");
    }
}

fn fail(out: *std.Io.Writer, text: []const u8) !void {
    try out.writeAll(text);
    try out.flush();
    std.process.exit(2);
}

fn report(state: w.DWORD, exit_code: w.DWORD, wait_hint: w.DWORD) void {
    const handle = status_handle orelse return;
    const pending = state == w.SERVICE_START_PENDING or state == w.SERVICE_STOP_PENDING;
    check_point = if (pending) check_point + 1 else 0;
    const status: w.ServiceStatus = .{
        .dwCurrentState = state,
        .dwControlsAccepted = if (state == w.SERVICE_RUNNING) w.SERVICE_ACCEPT_STOP | w.SERVICE_ACCEPT_SHUTDOWN else 0,
        .dwWin32ExitCode = exit_code,
        .dwCheckPoint = check_point,
        .dwWaitHint = wait_hint,
    };
    _ = w.SetServiceStatus(handle, &status);
}

fn serviceMain(argc: w.DWORD, argv: ?[*]?[*:0]u16) callconv(.winapi) void {
    _ = argc;
    _ = argv;
    status_handle = w.RegisterServiceCtrlHandlerExW(pipe.service_name, handler, null) orelse return;
    report(w.SERVICE_START_PENDING, 0, 3000);

    server = .{ .gpa = gpa, .name = pipe.pipe_name };
    server.listen() catch {
        // ERROR_ALREADY_EXISTS for a pipe somebody else got to first, which is
        // the one thing that should stop the service from starting.
        report(w.SERVICE_STOPPED, w.ERROR_ALREADY_EXISTS, 0);
        return;
    };
    report(w.SERVICE_RUNNING, 0, 0);
    server.run();
    server.deinit();
    report(w.SERVICE_STOPPED, 0, 0);
}

fn handler(control: w.DWORD, event_type: w.DWORD, event_data: ?*anyopaque, context: ?*anyopaque) callconv(.winapi) w.DWORD {
    _ = event_type;
    _ = event_data;
    _ = context;
    switch (control) {
        w.SERVICE_CONTROL_STOP, w.SERVICE_CONTROL_SHUTDOWN => {
            report(w.SERVICE_STOP_PENDING, 0, 3000);
            server.stop();
            return w.NO_ERROR;
        },
        w.SERVICE_CONTROL_INTERROGATE => return w.NO_ERROR,
        else => return w.ERROR_CALL_NOT_IMPLEMENTED,
    }
}
