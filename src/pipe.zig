//! The service and its clients, talking over a named pipe.
//!
//! A client asks for one of the four things in `volume.zig` and gets back the
//! same batches a reader in its own process would have produced. Every message
//! is eight bytes of header, holding the length of what follows and what kind
//! of message it is, then the payload. Requests are a few bytes and fixed in
//! size, so the service never reads more than 32 bytes from anyone.
//!
//! The service runs as LocalSystem and answers whoever is signed in at the
//! machine, which makes the pipe a real boundary. Remote clients are refused,
//! signed in users may read and write but not open instances of their own, and
//! a client only believes a pipe whose server is the installed service.

const std = @import("std");
const w = @import("win32.zig");
const volume = @import("volume.zig");

const L = std.unicode.utf8ToUtf16LeStringLiteral;

/// Bumped whenever a message changes shape. A client and service that
/// disagree never get past hello.
pub const version: u32 = 1;
const magic: u32 = 0x4850_4C45; // "ELPH"

pub const service_name = L("ElephantSearch");
pub const pipe_name = L("\\\\.\\pipe\\ElephantSearch");

/// SYSTEM, administrators and whoever created the pipe get everything, and
/// the server needs that to open its next instance. Anyone signed in at the
/// machine gets read plus write data, which is enough to talk while it leaves
/// out creating an instance, the right that would let them answer in the
/// service's place.
pub const sddl = L("D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GA;;;OW)(A;;0x0012008B;;;IU)");

pub const Address = struct {
    name: [:0]const u16,
    /// Whether the process on the other end has to be the installed service.
    /// Only a pipe somebody named by hand skips it.
    verify: bool,
};

pub const installed: Address = .{ .name = pipe_name, .verify = true };

const Kind = enum(u8) {
    hello = 1,
    journal = 2,
    enumerate = 3,
    changes = 4,
    sizes = 5,

    welcome = 0x81,
    journal_is = 0x82,
    names = 0x83,
    done = 0x84,
    failed = 0x85,
    changes_end = 0x86,
    table = 0x87,
    size_batch = 0x88,
    _,
};

const header_len = 8;
const max_request = 32;
const max_reply = volume.batch_bytes + 64;

const Frame = struct {
    kind: Kind,
    payload: []const u8,
};

const ERROR_FILE_NOT_FOUND: w.DWORD = 2;

/// One end of a connected pipe. Byte mode, so a message can arrive in pieces
/// and every read loops until it has what it asked for.
const Conn = struct {
    h: w.HANDLE,

    fn writeAll(self: Conn, bytes: []const u8) bool {
        var at: usize = 0;
        while (at < bytes.len) {
            var wrote: w.DWORD = 0;
            const want: w.DWORD = @intCast(@min(bytes.len - at, 1 << 30));
            if (w.WriteFile(self.h, bytes[at..].ptr, want, &wrote, null) == 0) return false;
            if (wrote == 0) return false;
            at += wrote;
        }
        return true;
    }

    fn readAll(self: Conn, buf: []u8) bool {
        var at: usize = 0;
        while (at < buf.len) {
            var got: w.DWORD = 0;
            const want: w.DWORD = @intCast(@min(buf.len - at, 1 << 30));
            if (w.ReadFile(self.h, buf[at..].ptr, want, &got, null) == 0) return false;
            if (got == 0) return false;
            at += got;
        }
        return true;
    }

    fn send(self: Conn, kind: Kind, parts: []const []const u8) bool {
        var len: usize = 0;
        for (parts) |p| len += p.len;
        var header: [header_len]u8 = @splat(0);
        std.mem.writeInt(u32, header[0..4], @intCast(len), .little);
        header[4] = @intFromEnum(kind);
        if (!self.writeAll(&header)) return false;
        for (parts) |p| if (!self.writeAll(p)) return false;
        return true;
    }

    /// Reads one message into `buf`. Null when the pipe closed or the other
    /// end sent more than `buf` holds, which from a client means it is not
    /// one of ours and from the service means something is badly wrong.
    fn receive(self: Conn, buf: []u8) ?Frame {
        var header: [header_len]u8 = undefined;
        if (!self.readAll(&header)) return null;
        const len = std.mem.readInt(u32, header[0..4], .little);
        if (len > buf.len) return null;
        if (!self.readAll(buf[0..len])) return null;
        return .{ .kind = @enumFromInt(header[4]), .payload = buf[0..len] };
    }

    fn nameSink(self: *Conn) volume.NameSink {
        return .{ .ctx = self, .batch = sendNames };
    }

    fn sizeSink(self: *Conn) volume.SizeSink {
        return .{ .ctx = self, .table = sendTable, .batch = sendSizes };
    }

    fn sendNames(ctx: *anyopaque, bytes: []const u8) volume.Error!void {
        const self: *Conn = @ptrCast(@alignCast(ctx));
        if (!self.send(.names, &.{bytes})) return error.Stopped;
    }

    fn sendTable(ctx: *anyopaque, records: u64) volume.Error!void {
        const self: *Conn = @ptrCast(@alignCast(ctx));
        var out: [8]u8 = undefined;
        std.mem.writeInt(u64, &out, records, .little);
        if (!self.send(.table, &.{&out})) return error.Stopped;
    }

    fn sendSizes(ctx: *anyopaque, bytes: []const u8, scanned: u64) volume.Error!void {
        const self: *Conn = @ptrCast(@alignCast(ctx));
        var out: [8]u8 = undefined;
        std.mem.writeInt(u64, &out, scanned, .little);
        if (!self.send(.size_batch, &.{ &out, bytes })) return error.Stopped;
    }
};

fn codeOf(e: volume.Error) u8 {
    return switch (e) {
        error.AccessDenied => 1,
        error.OpenFailed => 2,
        error.EnumFailed => 3,
        error.JournalLost => 4,
        error.TableFailed => 5,
        error.ServiceFailed, error.Stopped, error.OutOfMemory => 6,
    };
}

fn errorOf(code: u8) volume.Error {
    return switch (code) {
        1 => error.AccessDenied,
        2 => error.OpenFailed,
        3 => error.EnumFailed,
        4 => error.JournalLost,
        5 => error.TableFailed,
        else => error.ServiceFailed,
    };
}

pub const ConnectError = error{
    /// Nothing is listening, which mostly means the service is not installed.
    NotRunning,
    /// Something is listening that is not the installed service.
    Untrusted,
    /// The service speaks another version of this conversation.
    Outdated,
    ServiceFailed,
    OutOfMemory,
};

fn connect(name: [:0]const u16) ConnectError!w.HANDLE {
    var tries: u32 = 0;
    while (true) {
        // Identification only, so whoever is on the other end can find out who
        // called but never act as them.
        const h = w.CreateFileW(
            name,
            w.GENERIC_READ | w.FILE_WRITE_DATA,
            0,
            null,
            w.OPEN_EXISTING,
            w.SECURITY_SQOS_PRESENT | w.SECURITY_IDENTIFICATION,
            null,
        );
        if (h != w.INVALID_HANDLE_VALUE) return h;
        switch (w.GetLastError()) {
            ERROR_FILE_NOT_FOUND => return error.NotRunning,
            w.ERROR_PIPE_BUSY => {
                if (tries == 3) return error.ServiceFailed;
                tries += 1;
                _ = w.WaitNamedPipeW(name, 2000);
            },
            else => return error.ServiceFailed,
        }
    }
}

/// The process id the installed service is running as, or null when it is not
/// installed or not running.
pub fn servicePid() ?w.DWORD {
    const scm = w.OpenSCManagerW(null, null, w.SC_MANAGER_CONNECT) orelse return null;
    defer _ = w.CloseServiceHandle(scm);
    const svc = w.OpenServiceW(scm, service_name, w.SERVICE_QUERY_STATUS) orelse return null;
    defer _ = w.CloseServiceHandle(svc);
    var status: w.ServiceStatusProcess = .{};
    var needed: w.DWORD = 0;
    if (w.QueryServiceStatusEx(svc, w.SC_STATUS_PROCESS_INFO, &status, @sizeOf(w.ServiceStatusProcess), &needed) == 0) {
        return null;
    }
    if (status.dwCurrentState != w.SERVICE_RUNNING or status.dwProcessId == 0) return null;
    return status.dwProcessId;
}

/// Whether the server end of `h` is the service the service manager started.
/// Anybody can create a pipe by a name nobody holds, so the name alone proves
/// nothing.
fn isInstalledService(h: w.HANDLE) bool {
    var pid: w.ULONG = 0;
    if (w.GetNamedPipeServerProcessId(h, &pid) == 0) return false;
    const expected = servicePid() orelse return false;
    return pid == expected;
}

/// Asks the service instead of the volumes.
pub const Remote = struct {
    gpa: std.mem.Allocator,
    conn: Conn,
    buf: []u8,
    /// Set once the conversation lost its place, for instance because a sink
    /// stopped a stream part way. Nothing more can be asked on it.
    broken: bool = false,

    const vtable: volume.Reader.VTable = .{
        .journal = journal,
        .enumerate = enumerate,
        .changes = changes,
        .sizes = sizes,
        .close = close,
    };

    pub fn open(gpa: std.mem.Allocator, at: Address) ConnectError!volume.Reader {
        return openAs(gpa, at, version);
    }

    fn openAs(gpa: std.mem.Allocator, at: Address, speaks: u32) ConnectError!volume.Reader {
        const h = try connect(at.name);
        errdefer _ = w.CloseHandle(h);
        if (at.verify and !isInstalledService(h)) return error.Untrusted;

        const buf = try gpa.alloc(u8, max_reply);
        errdefer gpa.free(buf);
        const conn: Conn = .{ .h = h };

        var hello: [8]u8 = undefined;
        std.mem.writeInt(u32, hello[0..4], magic, .little);
        std.mem.writeInt(u32, hello[4..8], speaks, .little);
        if (!conn.send(.hello, &.{&hello})) return error.ServiceFailed;
        const reply = conn.receive(buf) orelse return error.ServiceFailed;
        if (reply.kind != .welcome or reply.payload.len != 4) return error.ServiceFailed;
        if (std.mem.readInt(u32, reply.payload[0..4], .little) != speaks) return error.Outdated;

        const self = try gpa.create(Remote);
        self.* = .{ .gpa = gpa, .conn = conn, .buf = buf };
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn close(ptr: *anyopaque) void {
        const self: *Remote = @ptrCast(@alignCast(ptr));
        _ = w.CloseHandle(self.conn.h);
        self.gpa.free(self.buf);
        self.gpa.destroy(self);
    }

    fn lost(self: *Remote) volume.Error {
        self.broken = true;
        return error.ServiceFailed;
    }

    fn ask(self: *Remote, kind: Kind, payload: []const u8) volume.Error!void {
        if (self.broken) return error.ServiceFailed;
        if (!self.conn.send(kind, &.{payload})) return self.lost();
    }

    fn next(self: *Remote) volume.Error!Frame {
        return self.conn.receive(self.buf) orelse self.lost();
    }

    fn failure(self: *Remote, f: Frame) volume.Error {
        if (f.payload.len != 1) return self.lost();
        return errorOf(f.payload[0]);
    }

    /// Hands a batch on. A sink that stops leaves the rest of the stream
    /// unread, so the conversation cannot carry on after it.
    fn pass(self: *Remote, result: volume.Error!void) volume.Error!void {
        result catch |e| {
            self.broken = true;
            return e;
        };
    }

    fn journal(ptr: *anyopaque, letter: u8) volume.Error!?volume.Journal {
        const self: *Remote = @ptrCast(@alignCast(ptr));
        try self.ask(.journal, &[_]u8{letter});
        const f = try self.next();
        switch (f.kind) {
            .journal_is => {
                if (f.payload.len != 40) return self.lost();
                const p = f.payload;
                if (p[0] == 0) return null;
                return .{
                    .id = std.mem.readInt(u64, p[8..16], .little),
                    .first = std.mem.readInt(i64, p[16..24], .little),
                    .next = std.mem.readInt(i64, p[24..32], .little),
                    .lowest_valid = std.mem.readInt(i64, p[32..40], .little),
                };
            },
            .failed => return self.failure(f),
            else => return self.lost(),
        }
    }

    fn enumerate(ptr: *anyopaque, letter: u8, sink: volume.NameSink) volume.Error!void {
        const self: *Remote = @ptrCast(@alignCast(ptr));
        try self.ask(.enumerate, &[_]u8{letter});
        while (true) {
            const f = try self.next();
            switch (f.kind) {
                .names => try self.pass(sink.batch(sink.ctx, f.payload)),
                .done => return if (f.payload.len == 0) {} else self.lost(),
                .failed => return self.failure(f),
                else => return self.lost(),
            }
        }
    }

    fn changes(ptr: *anyopaque, letter: u8, journal_id: u64, from: i64, sink: volume.NameSink) volume.Error!i64 {
        const self: *Remote = @ptrCast(@alignCast(ptr));
        var req: [24]u8 = @splat(0);
        req[0] = letter;
        std.mem.writeInt(u64, req[8..16], journal_id, .little);
        std.mem.writeInt(i64, req[16..24], from, .little);
        try self.ask(.changes, &req);
        while (true) {
            const f = try self.next();
            switch (f.kind) {
                .names => try self.pass(sink.batch(sink.ctx, f.payload)),
                .changes_end => {
                    if (f.payload.len != 8) return self.lost();
                    return std.mem.readInt(i64, f.payload[0..8], .little);
                },
                .failed => return self.failure(f),
                else => return self.lost(),
            }
        }
    }

    fn sizes(ptr: *anyopaque, letter: u8, limit: u64, sink: volume.SizeSink) volume.Error!void {
        const self: *Remote = @ptrCast(@alignCast(ptr));
        var req: [16]u8 = @splat(0);
        req[0] = letter;
        std.mem.writeInt(u64, req[8..16], limit, .little);
        try self.ask(.sizes, &req);
        while (true) {
            const f = try self.next();
            switch (f.kind) {
                .table => {
                    if (f.payload.len != 8) return self.lost();
                    try self.pass(sink.table(sink.ctx, std.mem.readInt(u64, f.payload[0..8], .little)));
                },
                .size_batch => {
                    if (f.payload.len < 8) return self.lost();
                    const scanned = std.mem.readInt(u64, f.payload[0..8], .little);
                    try self.pass(sink.batch(sink.ctx, f.payload[8..], scanned));
                },
                .done => return if (f.payload.len == 0) {} else self.lost(),
                .failed => return self.failure(f),
                else => return self.lost(),
            }
        }
    }
};

/// Where a front end should read the volumes from, and what to tell the user
/// about it.
pub const Choice = struct {
    source: volume.Source,
    service: State,

    pub const State = enum {
        /// Reading through the service.
        used,
        /// Not installed, or installed and not running.
        missing,
        /// Running, while speaking another version than this program.
        outdated,
        /// Something holds the pipe that is not the installed service.
        untrusted,
        /// This process can open the volumes itself, so it does.
        elevated,
    };
};

/// Picks the service when it answers and this process could not open the
/// volumes on its own. `at` replaces the installed service's pipe.
pub fn choose(gpa: std.mem.Allocator, elevated: bool, at: ?Address) Choice {
    if (elevated and at == null) return .{ .source = .direct, .service = .elevated };
    const address = at orelse installed;
    const probe = Remote.open(gpa, address) catch |e| return .{
        .source = .direct,
        .service = switch (e) {
            error.Outdated => .outdated,
            error.Untrusted => .untrusted,
            else => .missing,
        },
    };
    probe.close();
    return .{ .source = .{ .service = address }, .service = .used };
}

/// The service's half. Listens on the pipe and gives every client its own
/// thread and its own reader.
pub const Server = struct {
    gpa: std.mem.Allocator,
    name: [:0]const u16,
    sddl: [:0]const u16 = sddl,
    source: volume.Source = .direct,
    max_instances: u32 = 16,

    descriptor: ?*anyopaque = null,
    /// The instance waiting for its client, made ahead of the loop for the
    /// first one so `listen` can say whether the name was free.
    waiting: ?w.HANDLE = null,
    stopping: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),
    active: std.atomic.Value(u32) = .init(0),

    pub const ListenError = error{ BadDescriptor, PipeTaken, BadName };

    /// Claims the pipe name. Fails when somebody else already holds it, which
    /// is the one moment a squatter could otherwise slip in.
    pub fn listen(self: *Server) ListenError!void {
        var sd: ?*anyopaque = null;
        if (w.ConvertStringSecurityDescriptorToSecurityDescriptorW(self.sddl, 1, &sd, null) == 0) {
            return error.BadDescriptor;
        }
        self.descriptor = sd;
        self.waiting = self.instance(true) orelse return switch (w.GetLastError()) {
            w.ERROR_ACCESS_DENIED, w.ERROR_PIPE_BUSY => error.PipeTaken,
            else => error.BadName,
        };
    }

    pub fn deinit(self: *Server) void {
        if (self.waiting) |h| _ = w.CloseHandle(h);
        self.waiting = null;
        if (self.descriptor) |sd| _ = w.LocalFree(sd);
        self.descriptor = null;
    }

    fn instance(self: *Server, first: bool) ?w.HANDLE {
        const sa: w.SecurityAttributes = .{ .lpSecurityDescriptor = self.descriptor };
        const h = w.CreateNamedPipeW(
            self.name,
            w.PIPE_ACCESS_DUPLEX | (if (first) w.FILE_FLAG_FIRST_PIPE_INSTANCE else 0),
            w.PIPE_TYPE_BYTE | w.PIPE_READMODE_BYTE | w.PIPE_WAIT | w.PIPE_REJECT_REMOTE_CLIENTS,
            self.max_instances,
            64 * 1024,
            4 * 1024,
            0,
            &sa,
        );
        return if (h == w.INVALID_HANDLE_VALUE) null else h;
    }

    /// Serves until `stop`. Returns once the clients still connected have had
    /// a moment to finish.
    pub fn run(self: *Server) void {
        defer self.finished.store(true, .release);
        while (!self.stopping.load(.acquire)) {
            const h = self.waiting orelse self.instance(false) orelse {
                // Every instance is taken. One frees up when a client leaves.
                w.Sleep(100);
                continue;
            };
            self.waiting = null;

            const ok = w.ConnectNamedPipe(h, null) != 0 or w.GetLastError() == w.ERROR_PIPE_CONNECTED;
            if (self.stopping.load(.acquire)) {
                _ = w.CloseHandle(h);
                break;
            }
            // Made before this one is handed off or closed, so there is never
            // a moment without an instance. Without one the name goes away,
            // and a client reads that as no service at all.
            if (self.waiting == null) self.waiting = self.instance(false);
            if (!ok) {
                _ = w.CloseHandle(h);
                continue;
            }

            _ = self.active.fetchAdd(1, .acq_rel);
            const t = std.Thread.spawn(.{}, serve, .{ self, h }) catch {
                _ = self.active.fetchSub(1, .acq_rel);
                _ = w.CloseHandle(h);
                continue;
            };
            t.detach();
        }

        var waited: u32 = 0;
        while (self.active.load(.acquire) > 0 and waited < 2000) : (waited += 10) w.Sleep(10);
    }

    /// `ConnectNamedPipe` has no timeout, so the loop is woken by connecting
    /// to it. Keeps knocking until it notices, since a knock that lands while
    /// no instance is listening goes nowhere.
    pub fn stop(self: *Server) void {
        self.stopping.store(true, .release);
        var tries: u32 = 0;
        while (!self.finished.load(.acquire) and tries < 100) : (tries += 1) {
            const h = w.CreateFileW(self.name, w.GENERIC_READ | w.FILE_WRITE_DATA, 0, null, w.OPEN_EXISTING, 0, null);
            if (h != w.INVALID_HANDLE_VALUE) _ = w.CloseHandle(h);
            w.Sleep(20);
        }
    }

    fn serve(self: *Server, h: w.HANDLE) void {
        defer _ = self.active.fetchSub(1, .acq_rel);
        defer _ = w.CloseHandle(h);
        var conn: Conn = .{ .h = h };
        var req: [max_request]u8 = undefined;

        const hello = conn.receive(&req) orelse return;
        if (hello.kind != .hello or hello.payload.len != 8) return;
        if (std.mem.readInt(u32, hello.payload[0..4], .little) != magic) return;
        var welcome: [4]u8 = undefined;
        std.mem.writeInt(u32, &welcome, version, .little);
        if (!conn.send(.welcome, &.{&welcome})) return;
        if (std.mem.readInt(u32, hello.payload[4..8], .little) != version) return;

        const reader = self.source.open(self.gpa) catch return;
        defer reader.close();

        while (true) {
            const f = conn.receive(&req) orelse return;
            if (!answer(reader, &conn, f)) return;
        }
    }

    /// Returns false once the conversation is over, either because the client
    /// asked something no client of ours would or because it went away.
    fn answer(reader: volume.Reader, conn: *Conn, f: Frame) bool {
        const p = f.payload;
        switch (f.kind) {
            .journal => {
                if (p.len != 1) return false;
                const j = reader.journal(p[0]) catch |e| return refuse(conn, e);
                var out: [40]u8 = @splat(0);
                if (j) |found| {
                    out[0] = 1;
                    std.mem.writeInt(u64, out[8..16], found.id, .little);
                    std.mem.writeInt(i64, out[16..24], found.first, .little);
                    std.mem.writeInt(i64, out[24..32], found.next, .little);
                    std.mem.writeInt(i64, out[32..40], found.lowest_valid, .little);
                }
                return conn.send(.journal_is, &.{&out});
            },
            .enumerate => {
                if (p.len != 1) return false;
                reader.enumerate(p[0], conn.nameSink()) catch |e| return refuse(conn, e);
                return conn.send(.done, &.{});
            },
            .changes => {
                if (p.len != 24) return false;
                const id = std.mem.readInt(u64, p[8..16], .little);
                const from = std.mem.readInt(i64, p[16..24], .little);
                const after = reader.changes(p[0], id, from, conn.nameSink()) catch |e| return refuse(conn, e);
                var out: [8]u8 = undefined;
                std.mem.writeInt(i64, &out, after, .little);
                return conn.send(.changes_end, &.{&out});
            },
            .sizes => {
                if (p.len != 16) return false;
                const limit = std.mem.readInt(u64, p[8..16], .little);
                reader.sizes(p[0], limit, conn.sizeSink()) catch |e| return refuse(conn, e);
                return conn.send(.done, &.{});
            },
            else => return false,
        }
    }

    fn refuse(conn: *Conn, e: volume.Error) bool {
        // The client is gone, so there is nobody to tell.
        if (e == error.Stopped) return false;
        return conn.send(.failed, &.{&[_]u8{codeOf(e)}});
    }
};

const testing = std.testing;
const fake = @import("fake.zig");

var test_pipes: std.atomic.Value(u32) = .init(0);

fn testName(buf: []u16) [:0]const u16 {
    var utf8: [96]u8 = undefined;
    const text = std.fmt.bufPrint(&utf8, "\\\\.\\pipe\\ElephantSearch-test-{d}-{d}", .{
        w.GetCurrentProcessId(),
        test_pipes.fetchAdd(1, .monotonic),
    }) catch unreachable;
    const n = std.unicode.utf8ToUtf16Le(buf, text) catch unreachable;
    buf[n] = 0;
    return buf[0..n :0];
}

const TestServer = struct {
    server: Server,
    thread: std.Thread,
    name_buf: [96]u16,

    fn start(self: *TestServer, opts: fake.Options) !void {
        const name = testName(&self.name_buf);
        self.server = .{ .gpa = testing.allocator, .name = name, .source = .{ .fake = opts } };
        try self.server.listen();
        self.thread = try std.Thread.spawn(.{}, Server.run, .{&self.server});
    }

    fn address(self: *const TestServer) Address {
        return .{ .name = self.server.name, .verify = false };
    }

    fn finish(self: *TestServer) void {
        self.server.stop();
        self.thread.join();
        self.server.deinit();
    }
};

const Counter = struct {
    names: usize = 0,
    last: [volume.max_name]u8 = undefined,
    last_len: usize = 0,
    stop_after: ?usize = null,
    sizes: usize = 0,
    table: u64 = 0,
    size_sum: u64 = 0,

    fn sink(self: *Counter) volume.NameSink {
        return .{ .ctx = self, .batch = onNames };
    }

    fn sizeSink(self: *Counter) volume.SizeSink {
        return .{ .ctx = self, .table = onTable, .batch = onSizes };
    }

    fn onNames(ctx: *anyopaque, bytes: []const u8) volume.Error!void {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        var it: volume.NameIter = .{ .bytes = bytes };
        while (try it.next()) |n| {
            self.names += 1;
            @memcpy(self.last[0..n.name.len], n.name);
            self.last_len = n.name.len;
        }
        if (self.stop_after) |limit| if (self.names >= limit) return error.Stopped;
    }

    fn onTable(ctx: *anyopaque, records: u64) volume.Error!void {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        self.table = records;
    }

    fn onSizes(ctx: *anyopaque, bytes: []const u8, scanned: u64) volume.Error!void {
        _ = scanned;
        const self: *Counter = @ptrCast(@alignCast(ctx));
        var it = try volume.SizeIter.init(bytes);
        while (it.next()) |s| {
            self.sizes += 1;
            self.size_sum += s.size;
        }
    }
};

test "a client reads a made up volume through the pipe" {
    var ts: TestServer = undefined;
    try ts.start(.{ .files = 30_000, .denied = 'Q' });
    defer ts.finish();

    const reader = try Remote.open(testing.allocator, ts.address());
    defer reader.close();

    const j = (try reader.journal('C')).?;
    try testing.expectEqual(fake.journal_id, j.id);
    try testing.expectEqual(fake.journal_start, j.next);

    // Big enough to take several batches.
    var listed: Counter = .{};
    try reader.enumerate('C', listed.sink());
    try testing.expectEqual(@as(usize, 30_000 + fake.directories), listed.names);
    try testing.expectEqualStrings("file29999.txt", listed.last[0..listed.last_len]);

    var changed: Counter = .{};
    const after = try reader.changes('C', fake.journal_id, fake.journal_start, changed.sink());
    try testing.expectEqual(fake.journal_start + 1, after);
    try testing.expectEqual(@as(usize, 1), changed.names);
    try testing.expectEqualStrings("fresh.txt", changed.last[0..changed.last_len]);

    var quiet: Counter = .{};
    try testing.expectEqual(after, try reader.changes('C', fake.journal_id, after, quiet.sink()));
    try testing.expectEqual(@as(usize, 0), quiet.names);

    try testing.expectError(error.JournalLost, reader.changes('C', 1, after, quiet.sink()));

    var sized: Counter = .{};
    try reader.sizes('C', 1 << 40, sized.sizeSink());
    try testing.expectEqual(@as(u64, 16 + fake.directories + 30_000 + 1), sized.table);
    try testing.expectEqual(@as(usize, fake.directories + 30_000 + 1), sized.sizes);
}

test "a refusal comes back as the same error and the connection carries on" {
    var ts: TestServer = undefined;
    try ts.start(.{ .files = 10, .denied = 'Q' });
    defer ts.finish();

    const reader = try Remote.open(testing.allocator, ts.address());
    defer reader.close();

    try testing.expectError(error.AccessDenied, reader.journal('Q'));
    var listed: Counter = .{};
    try testing.expectError(error.AccessDenied, reader.enumerate('Q', listed.sink()));
    try testing.expectError(error.OpenFailed, reader.journal('#'));
    try testing.expect((try reader.journal('C')) != null);
}

test "a client that stops reading part way gets a fresh connection next time" {
    var ts: TestServer = undefined;
    try ts.start(.{ .files = 40_000 });
    defer ts.finish();

    {
        const reader = try Remote.open(testing.allocator, ts.address());
        defer reader.close();
        var listed: Counter = .{ .stop_after = 1 };
        try testing.expectError(error.Stopped, reader.enumerate('C', listed.sink()));
        try testing.expectError(error.ServiceFailed, reader.journal('C'));
    }

    const again = try Remote.open(testing.allocator, ts.address());
    defer again.close();
    var listed: Counter = .{};
    try again.enumerate('C', listed.sink());
    try testing.expectEqual(@as(usize, 40_000 + fake.directories), listed.names);
}

test "a client speaking another version is turned away" {
    var ts: TestServer = undefined;
    try ts.start(.{});
    defer ts.finish();
    try testing.expectError(error.Outdated, Remote.openAs(testing.allocator, ts.address(), version + 1));
}

test "nobody listening reads as not running" {
    var buf: [96]u16 = undefined;
    const name = testName(&buf);
    try testing.expectError(error.NotRunning, Remote.open(testing.allocator, .{ .name = name, .verify = false }));
}

test "a client right after another one still finds the pipe" {
    var ts: TestServer = undefined;
    try ts.start(.{ .files = 10 });
    defer ts.finish();

    for (0..200) |_| {
        const reader = try Remote.open(testing.allocator, ts.address());
        reader.close();
    }
}

test "a pipe somebody else already holds is not taken over" {
    var ts: TestServer = undefined;
    try ts.start(.{});
    defer ts.finish();

    var second: Server = .{ .gpa = testing.allocator, .name = ts.server.name };
    defer second.deinit();
    try testing.expectError(error.PipeTaken, second.listen());
}

test "a pipe that is not the installed service is not believed" {
    var ts: TestServer = undefined;
    try ts.start(.{});
    defer ts.finish();
    try testing.expectError(error.Untrusted, Remote.open(testing.allocator, .{ .name = ts.server.name, .verify = true }));
}

test "the real descriptor parses" {
    var sd: ?*anyopaque = null;
    try testing.expect(w.ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, 1, &sd, null) != 0);
    _ = w.LocalFree(sd);
}
